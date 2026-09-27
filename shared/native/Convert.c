#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>

#include "Convert.h"

/// Audio and subtitle packets that can wait for the first video frame (the file can only start once
/// it's decoded)
#define MAX_EARLY_PACKETS 4096

typedef struct {
    AVFormatContext *in;
    AVFormatContext *out;
    AVStream *video_in, *video_out;
    int *copies;          // input stream index -> output stream copied as it is (audio, subtitles), or -1
    AVCodecContext *decoder;
    AVCodecContext *encoder;
    AVBufferRef *device;  // VideoToolbox, which decodes AV1
    AVPacket *packet;
    AVPacket *encoded;
    AVFrame *frame;
    AVFrame *converted;   // 10-bit frames rearranged the way VideoToolbox takes them
    AVPacket *early[MAX_EARLY_PACKETS];
    int early_count;
    bool header_written;
    char *error;
    size_t error_size;
} Conversion;

static int fail(Conversion *c, const char *what, int code) {
    char reason[AV_ERROR_MAX_STRING_SIZE] = "";
    if (code < 0 && code != AVERROR_EXIT) {
        av_strerror(code, reason, sizeof(reason));
    }
    snprintf(c->error, c->error_size, "%s%s%s", what, reason[0] ? ": " : "", reason);
    return code < 0 ? code : AVERROR_UNKNOWN;
}

int ytdl_video_codec(const char *path, char *codec, size_t codec_size) {
    AVFormatContext *in = NULL;
    int ret = avformat_open_input(&in, path, NULL, NULL);
    if (ret < 0) {
        return ret;
    }
    ret = AVERROR_STREAM_NOT_FOUND;
    for (unsigned s = 0; s < in->nb_streams; s++) {
        const AVStream *stream = in->streams[s];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            snprintf(codec, codec_size, "%s", avcodec_get_name(stream->codecpar->codec_id));
            ret = 0;
            break;
        }
    }
    avformat_close_input(&in);
    return ret;
}

/// FFmpeg's AV1 decoder only drives hardware, so it's VideoToolbox's frames or nothing.
static enum AVPixelFormat videotoolbox_format(AVCodecContext *context, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *format;
        }
    }
    return AV_PIX_FMT_NONE;
}

/// Bits per second for the HEVC: twice the source's, about what hardware HEVC needs to look the same
/// as AV1 or VP9, kept between 0.04 and 0.1 bits per pixel (2.5 to 6 Mbps for 1080p at 30 fps).
static int64_t hevc_bit_rate(const Conversion *c, int width, int height, AVRational rate) {
    double pixels = (double)width * height * (rate.num > 0 && rate.den > 0 ? av_q2d(rate) : 30);
    int64_t source = c->video_in->codecpar->bit_rate > 0 ? c->video_in->codecpar->bit_rate : c->in->bit_rate;
    double target = source > 0 ? 2.0 * source : 0.07 * pixels;
    return (int64_t)av_clipd(target, 0.04 * pixels, 0.1 * pixels);
}

/// 10-bit planar 4:2:0, which FFmpeg's VP9 decoder makes, as P010, which VideoToolbox takes.
static int to_p010(const AVFrame *src, AVFrame *dst) {
    av_frame_unref(dst);
    dst->format = AV_PIX_FMT_P010;
    dst->width = src->width;
    dst->height = src->height;
    int ret = av_frame_get_buffer(dst, 0);
    if (ret < 0 || (ret = av_frame_copy_props(dst, src)) < 0) {
        return ret;
    }
    for (int y = 0; y < src->height; y++) {
        const uint16_t *luma = (const uint16_t *)(src->data[0] + y * src->linesize[0]);
        uint16_t *out = (uint16_t *)(dst->data[0] + y * dst->linesize[0]);
        for (int x = 0; x < src->width; x++) {
            out[x] = luma[x] << 6;
        }
    }
    for (int y = 0; y < (src->height + 1) / 2; y++) {
        const uint16_t *u = (const uint16_t *)(src->data[1] + y * src->linesize[1]);
        const uint16_t *v = (const uint16_t *)(src->data[2] + y * src->linesize[2]);
        uint16_t *out = (uint16_t *)(dst->data[1] + y * dst->linesize[1]);
        for (int x = 0; x < (src->width + 1) / 2; x++) {
            out[2 * x] = u[x] << 6;
            out[2 * x + 1] = v[x] << 6;
        }
    }
    return 0;
}

static int open_decoder(Conversion *c) {
    enum AVCodecID id = c->video_in->codecpar->codec_id;
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec) {
        char what[96];
        snprintf(what, sizeof(what), "Can't decode %s video", avcodec_get_name(id));
        return fail(c, what, AVERROR_DECODER_NOT_FOUND);
    }
    AVCodecContext *decoder = c->decoder = avcodec_alloc_context3(codec);
    if (!decoder) {
        return fail(c, "Out of memory", AVERROR(ENOMEM));
    }
    int ret = avcodec_parameters_to_context(decoder, c->video_in->codecpar);
    if (ret < 0) {
        return fail(c, "Could not read the video", ret);
    }
    decoder->pkt_timebase = c->video_in->time_base;
    if (id == AV_CODEC_ID_AV1) {
        // Hardware AV1 decoding: A17 Pro, M3 and later
        ret = av_hwdevice_ctx_create(&c->device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
        if (ret < 0) {
            return fail(c, "This device can't decode AV1 video", ret);
        }
        decoder->hw_device_ctx = av_buffer_ref(c->device);
        decoder->get_format = videotoolbox_format;
    } else {
        decoder->thread_count = 0;  // one per core
    }
    ret = avcodec_open2(decoder, codec, NULL);
    return ret < 0 ? fail(c, "Could not start decoding the video", ret) : 0;
}

static int write_packet(Conversion *c, AVPacket *packet, AVRational time_base, AVStream *to) {
    av_packet_rescale_ts(packet, time_base, to->time_base);
    packet->stream_index = to->index;
    packet->pos = -1;
    int ret = av_interleaved_write_frame(c->out, packet);  // takes the packet's data
    return ret < 0 ? fail(c, "Could not write the file", ret) : 0;
}

/// Writes a packet of a stream that's copied as it is.
static int copy_packet(Conversion *c, AVPacket *packet) {
    AVStream *from = c->in->streams[packet->stream_index];
    return write_packet(c, packet, from->time_base, c->out->streams[c->copies[packet->stream_index]]);
}

/// Sets up the encoder for the kind of frames the decoder makes, then starts the file.
static int open_encoder(Conversion *c, const AVFrame *frame) {
    const AVCodec *codec = avcodec_find_encoder_by_name("hevc_videotoolbox");
    if (!codec) {
        return fail(c, "HEVC encoding isn't available", AVERROR_ENCODER_NOT_FOUND);
    }
    AVCodecContext *encoder = c->encoder = avcodec_alloc_context3(codec);
    if (!encoder) {
        return fail(c, "Out of memory", AVERROR(ENOMEM));
    }
    switch (frame->format) {
    case AV_PIX_FMT_VIDEOTOOLBOX:  // straight from the hardware decoder, never copied
        encoder->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
        encoder->sw_pix_fmt = ((const AVHWFramesContext *)frame->hw_frames_ctx->data)->sw_format;
        break;
    case AV_PIX_FMT_YUV420P:
    case AV_PIX_FMT_NV12:
    case AV_PIX_FMT_P010:
        encoder->pix_fmt = frame->format;
        break;
    case AV_PIX_FMT_YUV420P10:
        encoder->pix_fmt = AV_PIX_FMT_P010;  // see to_p010
        break;
    default: {
        char what[96];
        const char *name = av_get_pix_fmt_name(frame->format);
        snprintf(what, sizeof(what), "Can't convert %s video", name ? name : "this kind of");
        return fail(c, what, AVERROR_PATCHWELCOME);
    }
    }
    AVRational rate = av_guess_frame_rate(c->in, c->video_in, NULL);
    encoder->width = frame->width;
    encoder->height = frame->height;
    encoder->sample_aspect_ratio = frame->sample_aspect_ratio;
    encoder->time_base = c->video_in->time_base;
    encoder->framerate = rate;
    encoder->color_range = frame->color_range;
    encoder->color_primaries = frame->color_primaries;
    encoder->color_trc = frame->color_trc;
    encoder->colorspace = frame->colorspace;
    encoder->chroma_sample_location = frame->chroma_location;
    encoder->bit_rate = hevc_bit_rate(c, frame->width, frame->height, rate);
    if (c->out->oformat->flags & AVFMT_GLOBALHEADER) {
        encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    av_opt_set_int(encoder->priv_data, "allow_sw", 1, 0);  // in case the hardware encoder is busy
    int ret = avcodec_open2(encoder, codec, NULL);
    if (ret < 0) {
        return fail(c, "Could not start the HEVC encoder", ret);
    }

    AVCodecParameters *params = c->video_out->codecpar;
    if ((ret = avcodec_parameters_from_context(params, encoder)) < 0) {
        return fail(c, "Could not add the video", ret);
    }
    params->codec_tag = MKTAG('h', 'v', 'c', '1');  // Photos refuses FFmpeg's default, hev1
    c->video_out->time_base = encoder->time_base;
    c->video_out->avg_frame_rate = rate;
    // Keep the rotation of videos filmed sideways
    const AVCodecParameters *source = c->video_in->codecpar;
    const AVPacketSideData *matrix = av_packet_side_data_get(source->coded_side_data, source->nb_coded_side_data,
                                                             AV_PKT_DATA_DISPLAYMATRIX);
    if (matrix) {
        AVPacketSideData *copy = av_packet_side_data_new(&params->coded_side_data, &params->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX, matrix->size, 0);
        if (copy) {
            memcpy(copy->data, matrix->data, matrix->size);
        }
    }

    AVDictionary *options = NULL;
    av_dict_set(&options, "movflags", "+faststart", 0);  // index up front: streams and scrubs well
    ret = avformat_write_header(c->out, &options);
    av_dict_free(&options);
    if (ret < 0) {
        return fail(c, "Could not write the file header", ret);
    }
    c->header_written = true;
    for (int i = 0; i < c->early_count; i++) {
        ret = copy_packet(c, c->early[i]);
        av_packet_free(&c->early[i]);
        if (ret < 0) {
            return ret;
        }
    }
    c->early_count = 0;
    return 0;
}

/// Encodes a frame, or with NULL flushes the encoder, writing what comes out.
static int encode(Conversion *c, AVFrame *frame) {
    int ret;
    if (frame && !c->encoder && (ret = open_encoder(c, frame)) < 0) {
        return ret;
    }
    if (frame && frame->format == AV_PIX_FMT_YUV420P10) {
        if ((ret = to_p010(frame, c->converted)) < 0) {
            return fail(c, "Out of memory", ret);
        }
        frame = c->converted;
    }
    if (frame) {
        frame->pict_type = AV_PICTURE_TYPE_NONE;  // the encoder places its own keyframes
    }
    if ((ret = avcodec_send_frame(c->encoder, frame)) < 0) {
        return fail(c, "Could not encode the video", ret);
    }
    for (;;) {
        ret = avcodec_receive_packet(c->encoder, c->encoded);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            return fail(c, "Could not encode the video", ret);
        }
        if ((ret = write_packet(c, c->encoded, c->encoder->time_base, c->video_out)) < 0) {
            return ret;
        }
    }
}

static int drain_decoder(Conversion *c) {
    for (;;) {
        int ret = avcodec_receive_frame(c->decoder, c->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return 0;
        }
        if (ret < 0) {
            return fail(c, "Could not decode the video", ret);
        }
        c->frame->pts = c->frame->best_effort_timestamp;
        ret = encode(c, c->frame);
        av_frame_unref(c->frame);
        if (ret < 0) {
            return ret;
        }
    }
}

int ytdl_convert_to_hevc(const char *input, const char *output, ytdl_progress_t progress, void *context,
                         char *error, size_t error_size) {
    Conversion c = {.error = error, .error_size = error_size};
    int ret;

    av_log_set_level(AV_LOG_ERROR);  // failures are reported through `error`
    if (error_size) {
        error[0] = '\0';
    }

    if ((ret = avformat_open_input(&c.in, input, NULL, NULL)) < 0) {
        fail(&c, "Could not open the video", ret);
        goto end;
    }
    if ((ret = avformat_find_stream_info(c.in, NULL)) < 0) {
        fail(&c, "Could not read the video", ret);
        goto end;
    }
    for (unsigned s = 0; s < c.in->nb_streams && !c.video_in; s++) {
        AVStream *stream = c.in->streams[s];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            c.video_in = stream;
        }
    }
    if (!c.video_in) {
        ret = fail(&c, "The file has no video", AVERROR_STREAM_NOT_FOUND);
        goto end;
    }
    if ((ret = open_decoder(&c)) < 0) {
        goto end;
    }

    ret = avformat_alloc_output_context2(&c.out, NULL, "mp4", output);
    if (ret < 0 || !c.out) {
        fail(&c, "Could not create the file", ret < 0 ? ret : AVERROR(ENOMEM));
        ret = ret < 0 ? ret : AVERROR(ENOMEM);
        goto end;
    }
    // The video's parameters come from the encoder, once the first frame shows what it's given
    c.video_out = avformat_new_stream(c.out, NULL);
    if (!c.video_out) {
        ret = fail(&c, "Out of memory", AVERROR(ENOMEM));
        goto end;
    }
    av_dict_copy(&c.video_out->metadata, c.video_in->metadata, 0);
    // The first audio and every subtitle track (Remux.c embeds them) are copied as they are
    c.copies = av_malloc_array(c.in->nb_streams, sizeof(*c.copies));
    if (!c.copies) {
        ret = fail(&c, "Out of memory", AVERROR(ENOMEM));
        goto end;
    }
    bool have_audio = false;
    for (unsigned s = 0; s < c.in->nb_streams; s++) {
        AVStream *stream = c.in->streams[s];
        enum AVMediaType type = stream->codecpar->codec_type;
        bool wanted = (type == AVMEDIA_TYPE_AUDIO && !have_audio) || type == AVMEDIA_TYPE_SUBTITLE;
        c.copies[s] = -1;
        if (!wanted) {
            continue;
        }
        if (avformat_query_codec(c.out->oformat, stream->codecpar->codec_id, FF_COMPLIANCE_NORMAL) != 1) {
            if (type == AVMEDIA_TYPE_SUBTITLE) {
                continue;  // left out rather than losing the whole video
            }
            char what[96];
            snprintf(what, sizeof(what), "%s audio can't be stored in MP4", avcodec_get_name(stream->codecpar->codec_id));
            ret = fail(&c, what, AVERROR(EINVAL));
            goto end;
        }
        AVStream *copy = avformat_new_stream(c.out, NULL);
        if (!copy || (ret = avcodec_parameters_copy(copy->codecpar, stream->codecpar)) < 0) {
            ret = fail(&c, "Could not add the audio or subtitles", copy ? ret : AVERROR(ENOMEM));
            goto end;
        }
        copy->codecpar->codec_tag = 0;
        copy->time_base = stream->time_base;
        copy->disposition = stream->disposition;
        av_dict_copy(&copy->metadata, stream->metadata, 0);  // language, and a subtitle track's name
        c.copies[s] = copy->index;
        have_audio |= type == AVMEDIA_TYPE_AUDIO;
    }
    av_dict_copy(&c.out->metadata, c.in->metadata, 0);  // title, artist, the source link
    if ((ret = avio_open(&c.out->pb, output, AVIO_FLAG_WRITE)) < 0) {
        fail(&c, "Could not create the file", ret);
        goto end;
    }

    c.packet = av_packet_alloc();
    c.encoded = av_packet_alloc();
    c.frame = av_frame_alloc();
    c.converted = av_frame_alloc();
    if (!c.packet || !c.encoded || !c.frame || !c.converted) {
        ret = fail(&c, "Out of memory", AVERROR(ENOMEM));
        goto end;
    }

    AVRational time_base = c.video_in->time_base;
    int64_t start = c.video_in->start_time != AV_NOPTS_VALUE ? c.video_in->start_time : 0;
    double duration = c.video_in->duration > 0 ? c.video_in->duration * av_q2d(time_base)
                    : c.in->duration > 0 ? c.in->duration / (double)AV_TIME_BASE : 0;

    while ((ret = av_read_frame(c.in, c.packet)) >= 0) {
        if (c.packet->stream_index == c.video_in->index) {
            double fraction = duration > 0 && c.packet->pts != AV_NOPTS_VALUE
                ? av_clipd((c.packet->pts - start) * av_q2d(time_base) / duration, 0, 1) : 0;
            ret = avcodec_send_packet(c.decoder, c.packet);
            av_packet_unref(c.packet);
            if (ret < 0 && ret != AVERROR_INVALIDDATA) {  // skip a damaged packet, as players do
                fail(&c, "Could not decode the video", ret);
                goto end;
            }
            if ((ret = drain_decoder(&c)) < 0) {
                goto end;
            }
            if (progress && progress(context, fraction)) {
                ret = fail(&c, "Cancelled", AVERROR_EXIT);
                goto end;
            }
        } else if (c.copies[c.packet->stream_index] >= 0) {
            if (c.header_written) {
                if ((ret = copy_packet(&c, c.packet)) < 0) {
                    goto end;
                }
            } else if (c.early_count < MAX_EARLY_PACKETS && (c.early[c.early_count] = av_packet_clone(c.packet))) {
                c.early_count++;
                av_packet_unref(c.packet);
            } else {
                ret = fail(&c, "The audio runs too far ahead of the video", AVERROR_INVALIDDATA);
                goto end;
            }
        } else {
            av_packet_unref(c.packet);
        }
    }
    if (ret != AVERROR_EOF) {
        fail(&c, "Could not read the video", ret);
        goto end;
    }
    // What the decoder and encoder still hold
    if ((ret = avcodec_send_packet(c.decoder, NULL)) < 0 || (ret = drain_decoder(&c)) < 0) {
        if (!error[0]) fail(&c, "Could not decode the video", ret);
        goto end;
    }
    if (!c.encoder) {
        ret = fail(&c, "No video could be decoded", AVERROR_INVALIDDATA);
        goto end;
    }
    if ((ret = encode(&c, NULL)) < 0) {
        goto end;
    }
    if ((ret = av_write_trailer(c.out)) < 0) {
        fail(&c, "Could not finish the file", ret);
    }

end:
    for (int i = 0; i < c.early_count; i++) {
        av_packet_free(&c.early[i]);
    }
    av_freep(&c.copies);
    av_packet_free(&c.packet);
    av_packet_free(&c.encoded);
    av_frame_free(&c.frame);
    av_frame_free(&c.converted);
    avcodec_free_context(&c.decoder);
    avcodec_free_context(&c.encoder);
    av_buffer_unref(&c.device);
    avformat_close_input(&c.in);
    if (c.out) {
        if (c.out->pb) {
            avio_closep(&c.out->pb);
        }
        if (ret < 0) {
            remove(output);  // leave no half-written file behind
        }
        avformat_free_context(c.out);
    }
    return ret < 0 ? ret : 0;
}
