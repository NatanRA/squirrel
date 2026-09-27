#ifndef Convert_h
#define Convert_h

#include <stddef.h>

#ifndef __clang__  // nullability annotations are clang-only
#define _Nonnull
#define _Nullable
#endif

/// Called now and then with how far a conversion is (0 to 1). Return non-zero to stop it.
typedef int (*ytdl_progress_t)(void *_Nullable context, double fraction);

/// Writes the FFmpeg name of the first video stream's codec in `path` ("h264",
/// "hevc", "av1", "vp9", ...) into `codec`. Returns 0, or a negative FFmpeg error
/// when the file can't be read or has no video.
int ytdl_video_codec(const char *_Nonnull path, char *_Nonnull codec, size_t codec_size);

/// Re-encodes the first video stream of `input` as HEVC with Apple's hardware
/// encoder (VideoToolbox) into an MP4 at `output`, copying the first audio
/// stream, the subtitle tracks and the file's tags as they are. For AV1 and VP9
/// videos, which Photos won't take: AV1 is decoded in hardware (so only where
/// VideoToolbox can), VP9 in software. 8-bit video stays 8-bit and 10-bit (HDR)
/// becomes HEVC Main 10.
///
/// Returns 0 on success; otherwise writes a message into `error` and leaves no
/// file at `output`. Stopping through `progress` returns AVERROR_EXIT.
int ytdl_convert_to_hevc(const char *_Nonnull input, const char *_Nonnull output,
                         ytdl_progress_t _Nullable progress, void *_Nullable context,
                         char *_Nonnull error, size_t error_size);

#endif
