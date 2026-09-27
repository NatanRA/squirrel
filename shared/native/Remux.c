#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>

#include "Remux.h"

#define MAX_INPUTS 4
#define MAX_SUBTITLES 8

typedef struct {
    AVFormatContext *context;
    int *stream_map;     // input stream index -> output stream index, or -1
    AVPacket *packet;    // next packet to write, if `pending`
    bool pending;
    bool finished;
    // A subtitle MP4 can't store as it is: decoded, then encoded as mov_text
    AVCodecContext *decoder;
    AVCodecContext *encoder;
} Input;

/** MP4, M4A and MOV: the QuickTime family Apple's players read */
static bool is_quicktime(const char *format) {
    return strcmp(format, "mp4") == 0 || strcmp(format, "ipod") == 0 || strcmp(format, "mov") == 0;
}

/** The usual pixel format of a VP9 profile: 8-bit 4:2:0 (0), 4:4:4 (1), and their 10-bit kinds (2, 3) */
static enum AVPixelFormat vp9_pixel_format(int profile) {
    switch (profile) {
    case AV_PROFILE_VP9_1: return AV_PIX_FMT_YUV444P;
    case AV_PROFILE_VP9_2: return AV_PIX_FMT_YUV420P10;
    case AV_PROFILE_VP9_3: return AV_PIX_FMT_YUV444P10;
    default: return AV_PIX_FMT_YUV420P;
    }
}

static void set_error(char *error, size_t size, const char *what, int code) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = "";
    if (code < 0) {
        av_strerror(code, reason, sizeof(reason));
    }
    snprintf(error, size, "%s%s%s", what, code < 0 ? ": " : "", reason);
}

static void set_metadata(AVDictionary **dict, const char *const *metadata, int metadata_count) {
    for (int i = 0; metadata && i + 1 < metadata_count * 2; i += 2) {
        if (metadata[i + 1] && metadata[i + 1][0]) {
            av_dict_set(dict, metadata[i], metadata[i + 1], 0);
        }
    }
}

static void release(Input *input) {
    av_packet_free(&input->packet);
    av_freep(&input->stream_map);
    avcodec_free_context(&input->decoder);
    avcodec_free_context(&input->encoder);
    avformat_close_input(&input->context);
    *input = (Input){0};  // ready for the next subtitle file
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

/// Opens a subtitle file and adds its track to `out`: copied when the container takes the
/// format as it is (Matroska, WebM), else converted to mov_text (MP4, MOV). False if it can't
/// be used, with `input` released.
static bool add_subtitle(Input *input, const char *path, const char *language, const char *title,
                         AVFormatContext *out) {
    AVStream *stream = NULL;
    if (avformat_open_input(&input->context, path, NULL, NULL) < 0
        || avformat_find_stream_info(input->context, NULL) < 0
        || !(input->packet = av_packet_alloc())
        || !(input->stream_map = av_calloc(input->context->nb_streams, sizeof(int)))) {
        goto fail;
    }
    for (unsigned s = 0; s < input->context->nb_streams; s++) {
        input->stream_map[s] = -1;
        if (!stream && input->context->streams[s]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            stream = input->context->streams[s];
        }
    }
    if (!stream) {
        goto fail;
    }
    // Read the first cue now: a file without any (or not really subtitles) is left out
    while (!input->pending) {
        if (av_read_frame(input->context, input->packet) < 0) {
            goto fail;
        }
        if (input->packet->stream_index == stream->index) {
            input->pending = true;
        } else {
            av_packet_unref(input->packet);
        }
    }

    enum AVCodecID codec = stream->codecpar->codec_id;
    if (avformat_query_codec(out->oformat, codec, FF_COMPLIANCE_NORMAL) != 1) {
        if (avformat_query_codec(out->oformat, AV_CODEC_ID_MOV_TEXT, FF_COMPLIANCE_NORMAL) != 1) {
            goto fail;
        }
        const AVCodec *decoder = avcodec_find_decoder(codec);
        const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_MOV_TEXT);
        if (!decoder || !encoder
            || !(input->decoder = avcodec_alloc_context3(decoder))
            || avcodec_parameters_to_context(input->decoder, stream->codecpar) < 0) {
            goto fail;
        }
        input->decoder->pkt_timebase = stream->time_base;
        if (avcodec_open2(input->decoder, decoder, NULL) < 0
            || !(input->encoder = avcodec_alloc_context3(encoder))) {
            goto fail;
        }
        // Text decoders turn each cue into an ASS event; mov_text needs their style header
        input->encoder->time_base = AV_TIME_BASE_Q;
        if (input->decoder->subtitle_header) {
            input->encoder->subtitle_header = av_memdup(input->decoder->subtitle_header,
                                                        input->decoder->subtitle_header_size);
            input->encoder->subtitle_header_size = input->decoder->subtitle_header_size;
        }
        if (avcodec_open2(input->encoder, encoder, NULL) < 0) {
            goto fail;
        }
    }

    AVStream *out_stream = avformat_new_stream(out, NULL);
    if (!out_stream) {
        goto fail;
    }
    if (input->encoder) {
        avcodec_parameters_from_context(out_stream->codecpar, input->encoder);
        out_stream->time_base = (AVRational){1, 1000};
    } else {
        avcodec_parameters_copy(out_stream->codecpar, stream->codecpar);
        out_stream->codecpar->codec_tag = 0;
        out_stream->time_base = stream->time_base;
    }
    if (language && language[0]) {
        av_dict_set(&out_stream->metadata, "language", language, 0);
    }
    if (title && title[0]) {
        av_dict_set(&out_stream->metadata, "title", title, 0);
        av_dict_set(&out_stream->metadata, "handler_name", title, 0);  // what MP4 players list
    }
    input->stream_map[stream->index] = out_stream->index;
    return true;

fail:
    release(input);
    return false;
}

/// Converts the pending packet of a mov_text-bound subtitle input and writes it.
static int write_converted_subtitle(Input *input, AVFormatContext *out) {
    AVPacket *packet = input->packet;
    int index = input->stream_map[packet->stream_index];
    AVSubtitle subtitle;
    int got = 0;
    int ret = avcodec_decode_subtitle2(input->decoder, &subtitle, &got, packet);
    av_packet_unref(packet);
    if (ret < 0 || !got) {
        return 0;  // a cue it can't read is skipped, not the whole file
    }
    if (subtitle.num_rects > 0 && subtitle.pts != AV_NOPTS_VALUE) {
        // mov_text wants each cue to start at its own timestamp
        subtitle.pts += av_rescale_q(subtitle.start_display_time, (AVRational){1, 1000}, AV_TIME_BASE_Q);
        subtitle.end_display_time -= subtitle.start_display_time;
        subtitle.start_display_time = 0;

        uint8_t buffer[16384];
        int size = avcodec_encode_subtitle(input->encoder, buffer, sizeof(buffer), &subtitle);
        AVPacket *converted = size > 0 ? av_packet_alloc() : NULL;
        if (converted && av_new_packet(converted, size) == 0) {
            AVRational time_base = out->streams[index]->time_base;
            memcpy(converted->data, buffer, size);
            converted->stream_index = index;
            converted->pts = converted->dts = av_rescale_q(subtitle.pts, AV_TIME_BASE_Q, time_base);
            converted->duration = av_rescale_q(subtitle.end_display_time, (AVRational){1, 1000}, time_base);
            ret = av_interleaved_write_frame(out, converted);
        }
        av_packet_free(&converted);
    }
    avsubtitle_free(&subtitle);
    return ret < 0 ? ret : 0;
}

int ytdl_remux(const char *const *inputs, int input_count, const char *output, const char *format,
               const char *const *metadata, int metadata_count, char *error, size_t error_size) {
    return ytdl_remux_subtitled(inputs, input_count, NULL, NULL, NULL, 0, output, format,
                                metadata, metadata_count, error, error_size);
}

int ytdl_remux_subtitled(const char *const *inputs, int input_count, const char *const *subtitles,
                         const char *const *languages, const char *const *titles, int subtitle_count,
                         const char *output, const char *format, const char *const *metadata,
                         int metadata_count, char *error, size_t error_size) {
    Input in[MAX_INPUTS + MAX_SUBTITLES] = {0};
    int opened = 0;
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

    for (int i = 0; i < input_count; i++, opened++) {
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
            if (stream->codecpar->codec_id == AV_CODEC_ID_HEVC && is_quicktime(format)) {
                // FFmpeg's default for HEVC in MP4 is hev1, which Apple's players and Photos
                // refuse ("PHPhotosErrorDomain error 3302"). hvc1 plays everywhere.
                out_stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
            }
            if (stream->codecpar->codec_id == AV_CODEC_ID_VP9 && out_stream->codecpar->format == AV_PIX_FMT_NONE) {
                // Builds without a VP9 decoder can't tell the pixel format, and without it MP4's
                // vpcC box is written empty and nothing can open the file. The parser read the profile.
                out_stream->codecpar->format = vp9_pixel_format(stream->codecpar->profile);
            }
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

    // Subtitles only go with a video, after its own tracks
    for (int i = 0; have_video && subtitles && i < subtitle_count && i < MAX_SUBTITLES; i++) {
        if (add_subtitle(&in[opened], subtitles[i], languages ? languages[i] : NULL,
                         titles ? titles[i] : NULL, out)) {
            opened++;
        }
    }

    set_metadata(&out->metadata, metadata, metadata_count);

    ret = avio_open(&out->pb, output, AVIO_FLAG_WRITE);
    if (ret < 0) {
        set_error(error, error_size, "Could not create output file", ret);
        goto end;
    }
    if (is_quicktime(format)) {
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
        for (int i = 0; i < opened; i++) {
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
        next->pending = false;
        if (next->encoder) {
            ret = write_converted_subtitle(next, out);
        } else {
            AVPacket *packet = next->packet;
            AVStream *in_stream = next->context->streams[packet->stream_index];
            packet->stream_index = next->stream_map[packet->stream_index];
            av_packet_rescale_ts(packet, in_stream->time_base, out->streams[packet->stream_index]->time_base);
            packet->pos = -1;
            ret = av_interleaved_write_frame(out, packet);  // takes ownership of the packet's data
        }
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
    for (int i = 0; i < MAX_INPUTS + MAX_SUBTITLES; i++) {
        release(&in[i]);
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

// MARK: - MP3

typedef struct {
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    SwrContext *resampler;  // made from the first decoded frame, which is when its format is sure
    AVAudioFifo *fifo;      // resampled audio waiting to fill an MP3 frame (1152 samples)
    AVFormatContext *out;
    AVFrame *decoded;
    AVFrame *frame;
    AVPacket *encoded;
    int64_t pts;
} Conversion;

/// Encodes `frame` (NULL flushes the encoder) and writes the packets that come out.
static int encode(Conversion *c, AVFrame *frame) {
    int ret = avcodec_send_frame(c->encoder, frame);
    while (ret >= 0) {
        ret = avcodec_receive_packet(c->encoder, c->encoded);
        if (ret < 0) {
            break;
        }
        av_packet_rescale_ts(c->encoded, c->encoder->time_base, c->out->streams[0]->time_base);
        c->encoded->stream_index = 0;
        ret = av_interleaved_write_frame(c->out, c->encoded);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

/// Sends whole frames from the FIFO to the encoder; with `all`, the shorter last one too.
static int drain(Conversion *c, bool all) {
    int size = c->encoder->frame_size;
    while (av_audio_fifo_size(c->fifo) >= size || (all && av_audio_fifo_size(c->fifo) > 0)) {
        int count = FFMIN(size, av_audio_fifo_size(c->fifo));
        av_frame_unref(c->frame);
        c->frame->nb_samples = count;
        c->frame->format = c->encoder->sample_fmt;
        c->frame->sample_rate = c->encoder->sample_rate;
        int ret = av_channel_layout_copy(&c->frame->ch_layout, &c->encoder->ch_layout);
        if (ret < 0 || (ret = av_frame_get_buffer(c->frame, 0)) < 0) {
            return ret;
        }
        if (av_audio_fifo_read(c->fifo, (void **)c->frame->data, count) < count) {
            return AVERROR(EIO);
        }
        c->frame->pts = c->pts;
        c->pts += count;
        if ((ret = encode(c, c->frame)) < 0) {
            return ret;
        }
    }
    return 0;
}

/// Converts `frame` (NULL flushes the resampler) to the encoder's format and queues it.
static int resample(Conversion *c, const AVFrame *frame) {
    int ret;
    if (!c->resampler) {
        if (!frame) {
            return 0;
        }
        AVChannelLayout layout = {0};
        ret = frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC
            ? (av_channel_layout_default(&layout, frame->ch_layout.nb_channels), 0)
            : av_channel_layout_copy(&layout, &frame->ch_layout);
        if (ret >= 0) {
            ret = swr_alloc_set_opts2(&c->resampler, &c->encoder->ch_layout, c->encoder->sample_fmt,
                                      c->encoder->sample_rate, &layout, frame->format, frame->sample_rate, 0, NULL);
        }
        av_channel_layout_uninit(&layout);
        if (ret < 0 || (ret = swr_init(c->resampler)) < 0) {
            return ret;
        }
    }
    int samples = swr_get_out_samples(c->resampler, frame ? frame->nb_samples : 0);
    if (samples <= 0) {
        return 0;
    }
    uint8_t **buffer = NULL;
    ret = av_samples_alloc_array_and_samples(&buffer, NULL, c->encoder->ch_layout.nb_channels, samples,
                                             c->encoder->sample_fmt, 0);
    if (ret < 0) {
        return ret;
    }
    ret = swr_convert(c->resampler, buffer, samples,
                      frame ? (const uint8_t *const *)frame->extended_data : NULL, frame ? frame->nb_samples : 0);
    if (ret > 0 && av_audio_fifo_write(c->fifo, (void **)buffer, ret) < ret) {
        ret = AVERROR(ENOMEM);
    }
    av_freep(&buffer[0]);
    av_freep(&buffer);
    return ret < 0 ? ret : 0;
}

/// Decodes `packet` (NULL flushes the decoder) and passes its audio on to the encoder.
static int decode(Conversion *c, const AVPacket *packet) {
    int ret = avcodec_send_packet(c->decoder, packet);
    if (ret == AVERROR_INVALIDDATA) {
        return 0;  // a damaged packet is a moment of silence, not a failed download
    }
    while (ret >= 0) {
        ret = avcodec_receive_frame(c->decoder, c->decoded);
        if (ret < 0) {
            break;
        }
        ret = resample(c, c->decoded);
        av_frame_unref(c->decoded);
        if (ret >= 0) {
            ret = drain(c, false);
        }
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

/// The MP3 sample rate for `rate`: the same when MP3 has it, else the next one up (or the highest).
static int mp3_sample_rate(const AVCodecContext *encoder, int rate) {
    if (rate <= 0) {
        rate = 44100;  // not declared up front: CD quality rather than the lowest rate
    }
    const int *rates = NULL;
    int count = 0;
    if (avcodec_get_supported_config(encoder, NULL, AV_CODEC_CONFIG_SAMPLE_RATE, 0,
                                     (const void **)&rates, &count) < 0 || !rates || count == 0) {
        return rate > 0 ? rate : 44100;
    }
    int best = 0, highest = 0;
    for (int i = 0; i < count; i++) {
        highest = FFMAX(highest, rates[i]);
        if (rates[i] >= rate && (!best || rates[i] < best)) {
            best = rates[i];
        }
    }
    return best ? best : highest;
}

int ytdl_convert_to_mp3(const char *input, const char *output, const char *const *metadata,
                        int metadata_count, char *error, size_t error_size) {
    AVFormatContext *in = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    Conversion c = {0};
    const AVCodec *decoder = NULL;
    bool header_written = false;
    int ret;

    av_log_set_level(AV_LOG_ERROR);  // failures are reported through `error`

    if ((ret = avformat_open_input(&in, input, NULL, NULL)) < 0
        || (ret = avformat_find_stream_info(in, NULL)) < 0) {
        set_error(error, error_size, "Could not read download", ret);
        goto end;
    }
    int audio = av_find_best_stream(in, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    if (audio < 0 || !decoder) {
        ret = audio < 0 ? audio : AVERROR_DECODER_NOT_FOUND;
        set_error(error, error_size, "Download has no audio this build can read", ret);
        goto end;
    }
    AVStream *stream = in->streams[audio];
    if (!(c.decoder = avcodec_alloc_context3(decoder))
        || (ret = avcodec_parameters_to_context(c.decoder, stream->codecpar)) < 0) {
        set_error(error, error_size, "Could not read the audio", ret < 0 ? ret : AVERROR(ENOMEM));
        goto end;
    }
    c.decoder->pkt_timebase = stream->time_base;
    if ((ret = avcodec_open2(c.decoder, decoder, NULL)) < 0) {
        set_error(error, error_size, "Could not read the audio", ret);
        goto end;
    }

    const AVCodec *encoder = avcodec_find_encoder_by_name("libmp3lame");
    if (!encoder || !(c.encoder = avcodec_alloc_context3(encoder))) {
        ret = AVERROR_ENCODER_NOT_FOUND;
        set_error(error, error_size, "This build can't make MP3s", ret);
        goto end;
    }
    // MP3 holds stereo or mono, at a handful of sample rates
    av_channel_layout_default(&c.encoder->ch_layout, c.decoder->ch_layout.nb_channels == 1 ? 1 : 2);
    c.encoder->sample_rate = mp3_sample_rate(c.encoder, c.decoder->sample_rate);
    const enum AVSampleFormat *formats = NULL;
    int format_count = 0;
    avcodec_get_supported_config(c.encoder, NULL, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                                 (const void **)&formats, &format_count);
    c.encoder->sample_fmt = formats && format_count > 0 ? formats[0] : AV_SAMPLE_FMT_S16P;
    c.encoder->time_base = (AVRational){1, c.encoder->sample_rate};
    // Variable bitrate, LAME's -V2: about 190 kbps, transparent for nearly everyone
    c.encoder->flags |= AV_CODEC_FLAG_QSCALE;
    c.encoder->global_quality = 2 * FF_QP2LAMBDA;
    if ((ret = avcodec_open2(c.encoder, encoder, NULL)) < 0) {
        set_error(error, error_size, "Could not start the MP3 encoder", ret);
        goto end;
    }

    if ((ret = avformat_alloc_output_context2(&c.out, NULL, "mp3", output)) < 0 || !c.out) {
        set_error(error, error_size, "Unknown output format", ret);
        goto end;
    }
    AVStream *out_stream = avformat_new_stream(c.out, NULL);
    if (!out_stream || (ret = avcodec_parameters_from_context(out_stream->codecpar, c.encoder)) < 0) {
        ret = ret < 0 ? ret : AVERROR(ENOMEM);
        set_error(error, error_size, "Could not add stream", ret);
        goto end;
    }
    out_stream->time_base = c.encoder->time_base;
    set_metadata(&c.out->metadata, metadata, metadata_count);

    c.fifo = av_audio_fifo_alloc(c.encoder->sample_fmt, c.encoder->ch_layout.nb_channels, c.encoder->frame_size);
    c.decoded = av_frame_alloc();
    c.frame = av_frame_alloc();
    c.encoded = av_packet_alloc();
    packet = av_packet_alloc();
    if (!c.fifo || !c.decoded || !c.frame || !c.encoded || !packet) {
        ret = AVERROR(ENOMEM);
        set_error(error, error_size, "Out of memory", ret);
        goto end;
    }

    if ((ret = avio_open(&c.out->pb, output, AVIO_FLAG_WRITE)) < 0) {
        set_error(error, error_size, "Could not create output file", ret);
        goto end;
    }
    av_dict_set(&options, "id3v2_version", "3", 0);  // the tag version Windows and older players read
    if ((ret = avformat_write_header(c.out, &options)) < 0) {
        set_error(error, error_size, "Could not write file header", ret);
        goto end;
    }
    header_written = true;

    while ((ret = av_read_frame(in, packet)) >= 0) {
        if (packet->stream_index == audio) {
            ret = decode(&c, packet);
        }
        av_packet_unref(packet);
        if (ret < 0) {
            set_error(error, error_size, "Could not convert the audio", ret);
            goto end;
        }
    }
    if (ret != AVERROR_EOF) {
        set_error(error, error_size, "Could not read download", ret);
        goto end;
    }
    // Everything still inside the decoder, resampler, FIFO and encoder
    if ((ret = decode(&c, NULL)) < 0 || (ret = resample(&c, NULL)) < 0
        || (ret = drain(&c, true)) < 0 || (ret = encode(&c, NULL)) < 0) {
        set_error(error, error_size, "Could not convert the audio", ret);
        goto end;
    }
    if ((ret = av_write_trailer(c.out)) < 0) {
        set_error(error, error_size, "Could not finish file", ret);
    }

end:
    av_dict_free(&options);
    av_packet_free(&packet);
    av_packet_free(&c.encoded);
    av_frame_free(&c.decoded);
    av_frame_free(&c.frame);
    if (c.fifo) av_audio_fifo_free(c.fifo);
    swr_free(&c.resampler);
    avcodec_free_context(&c.decoder);
    avcodec_free_context(&c.encoder);
    avformat_close_input(&in);
    if (c.out) {
        if (!header_written || ret < 0) {
            if (c.out->pb) avio_closep(&c.out->pb);
            remove(output);  // leave no half-written file behind
        } else {
            avio_closep(&c.out->pb);
        }
        avformat_free_context(c.out);
    }
    return ret < 0 ? ret : 0;
}
