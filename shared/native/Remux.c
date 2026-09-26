#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

#include "Remux.h"

#define MAX_INPUTS 4

typedef struct {
    AVFormatContext *context;
    int *stream_map;     // input stream index -> output stream index, or -1
    AVPacket *packet;    // next packet to write, if `pending`
    bool pending;
    bool finished;
} Input;

static void set_error(char *error, size_t size, const char *what, int code) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = "";
    if (code < 0) {
        av_strerror(code, reason, sizeof(reason));
    }
    snprintf(error, size, "%s%s%s", what, code < 0 ? ": " : "", reason);
}

/// Reads ahead until the input has a packet for a mapped stream, or ends.
static int fill(Input *input) {
    while (!input->pending && !input->finished) {
        int ret = av_read_frame(input->context, input->packet);
        if (ret == AVERROR_EOF) {
            input->finished = true;
        } else if (ret < 0) {
            return ret;
        } else if (input->stream_map[input->packet->stream_index] < 0) {
            av_packet_unref(input->packet);
        } else {
            input->pending = true;
        }
    }
    return 0;
}

/// Packet position on a common clock, used to interleave inputs.
static int64_t packet_time(const Input *input) {
    const AVPacket *packet = input->packet;
    int64_t ts = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
    if (ts == AV_NOPTS_VALUE) {
        return INT64_MIN;  // write untimed packets as soon as possible
    }
    AVRational time_base = input->context->streams[packet->stream_index]->time_base;
    return av_rescale_q(ts, time_base, AV_TIME_BASE_Q);
}

int ytdl_remux(const char *const *inputs, int input_count, const char *output, const char *format,
               const char *const *metadata, int metadata_count, char *error, size_t error_size) {
    Input in[MAX_INPUTS] = {0};
    AVFormatContext *out = NULL;
    AVDictionary *options = NULL;
    bool have_video = false, have_audio = false, header_written = false;
    int ret = 0;

    av_log_set_level(AV_LOG_ERROR);  // failures are reported through `error`

    if (input_count < 1 || input_count > MAX_INPUTS) {
        set_error(error, error_size, "Unsupported number of inputs", 0);
        return -1;
    }

    ret = avformat_alloc_output_context2(&out, NULL, format, output);
    if (ret < 0 || !out) {
        set_error(error, error_size, "Unknown output format", ret);
        goto end;
    }

    for (int i = 0; i < input_count; i++) {
        ret = avformat_open_input(&in[i].context, inputs[i], NULL, NULL);
        if (ret < 0) {
            set_error(error, error_size, "Could not open download", ret);
            goto end;
        }
        ret = avformat_find_stream_info(in[i].context, NULL);
        if (ret < 0) {
            set_error(error, error_size, "Could not read download", ret);
            goto end;
        }
        in[i].packet = av_packet_alloc();
        in[i].stream_map = av_calloc(in[i].context->nb_streams, sizeof(int));
        if (!in[i].packet || !in[i].stream_map) {
            ret = AVERROR(ENOMEM);
            set_error(error, error_size, "Out of memory", ret);
            goto end;
        }

        for (unsigned s = 0; s < in[i].context->nb_streams; s++) {
            AVStream *stream = in[i].context->streams[s];
            enum AVMediaType type = stream->codecpar->codec_type;
            bool is_cover = stream->disposition & AV_DISPOSITION_ATTACHED_PIC;
            bool wanted = (type == AVMEDIA_TYPE_VIDEO && !is_cover && !have_video)
                       || (type == AVMEDIA_TYPE_AUDIO && !have_audio);
            in[i].stream_map[s] = -1;
            if (!wanted) {
                continue;
            }
            if (avformat_query_codec(out->oformat, stream->codecpar->codec_id, FF_COMPLIANCE_NORMAL) != 1) {
                ret = AVERROR(EINVAL);
                snprintf(error, error_size, "%s can't be stored in %s",
                         avcodec_get_name(stream->codecpar->codec_id), out->oformat->name);
                goto end;
            }
            AVStream *out_stream = avformat_new_stream(out, NULL);
            if (!out_stream || (ret = avcodec_parameters_copy(out_stream->codecpar, stream->codecpar)) < 0) {
                set_error(error, error_size, "Could not add stream", ret < 0 ? ret : AVERROR(ENOMEM));
                ret = ret < 0 ? ret : AVERROR(ENOMEM);
                goto end;
            }
            out_stream->codecpar->codec_tag = 0;  // let the muxer pick its own tag
            out_stream->time_base = stream->time_base;
            av_dict_copy(&out_stream->metadata, stream->metadata, 0);  // e.g. audio language
            in[i].stream_map[s] = out_stream->index;
            if (type == AVMEDIA_TYPE_VIDEO) have_video = true; else have_audio = true;
        }
    }
    if (!have_video && !have_audio) {
        ret = AVERROR_STREAM_NOT_FOUND;
        set_error(error, error_size, "Download has no audio or video", 0);
        goto end;
    }

    for (int i = 0; metadata && i + 1 < metadata_count * 2; i += 2) {
        if (metadata[i + 1] && metadata[i + 1][0]) {
            av_dict_set(&out->metadata, metadata[i], metadata[i + 1], 0);
        }
    }

    ret = avio_open(&out->pb, output, AVIO_FLAG_WRITE);
    if (ret < 0) {
        set_error(error, error_size, "Could not create output file", ret);
        goto end;
    }
    if (strcmp(format, "mp4") == 0 || strcmp(format, "ipod") == 0 || strcmp(format, "mov") == 0) {
        av_dict_set(&options, "movflags", "+faststart", 0);  // index up front: streams and scrubs well
    }
    ret = avformat_write_header(out, &options);
    if (ret < 0) {
        set_error(error, error_size, "Could not write file header", ret);
        goto end;
    }
    header_written = true;

    // Interleave: always write the earliest pending packet across inputs,
    // so memory stays flat even when merging large separate streams.
    for (;;) {
        Input *next = NULL;
        for (int i = 0; i < input_count; i++) {
            if ((ret = fill(&in[i])) < 0) {
                set_error(error, error_size, "Could not read download", ret);
                goto end;
            }
            if (in[i].pending && (!next || packet_time(&in[i]) < packet_time(next))) {
                next = &in[i];
            }
        }
        if (!next) {
            break;
        }
        AVPacket *packet = next->packet;
        AVStream *in_stream = next->context->streams[packet->stream_index];
        packet->stream_index = next->stream_map[packet->stream_index];
        av_packet_rescale_ts(packet, in_stream->time_base, out->streams[packet->stream_index]->time_base);
        packet->pos = -1;
        next->pending = false;
        ret = av_interleaved_write_frame(out, packet);  // takes ownership of the packet's data
        if (ret < 0) {
            set_error(error, error_size, "Could not write file", ret);
            goto end;
        }
    }

    ret = av_write_trailer(out);
    if (ret < 0) {
        set_error(error, error_size, "Could not finish file", ret);
    }

end:
    av_dict_free(&options);
    for (int i = 0; i < input_count; i++) {
        av_packet_free(&in[i].packet);
        av_freep(&in[i].stream_map);
        avformat_close_input(&in[i].context);
    }
    if (out) {
        if (!header_written || ret < 0) {
            // leave no half-written file behind
            if (out->pb) avio_closep(&out->pb);
            remove(output);
        } else {
            avio_closep(&out->pb);
        }
        avformat_free_context(out);
    }
    return ret < 0 ? ret : 0;
}
