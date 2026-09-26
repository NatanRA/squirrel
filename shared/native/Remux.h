#ifndef Remux_h
#define Remux_h

#include <stddef.h>

#ifndef __clang__  // nullability annotations are clang-only (the Windows build uses mingw gcc)
#define _Nonnull
#define _Nullable
#endif

/// Copies the first video and first audio stream found across `inputs` into a
/// new file at `output`, without re-encoding. Used both to merge yt-dlp's
/// separate video/audio downloads and to rewrap single files into a clean
/// container (e.g. MPEG-TS or fragmented MP4 into a regular MP4).
///
/// - format: FFmpeg muxer name ("mp4", "ipod" for .m4a, "matroska", ...)
/// - metadata: `metadata_count` key/value pairs, e.g. {"title", "…", "artist", "…"}
/// Returns 0 on success; otherwise writes a message into `error`.
int ytdl_remux(const char *_Nonnull const *_Nonnull inputs, int input_count,
               const char *_Nonnull output, const char *_Nonnull format,
               const char *_Nonnull const *_Nullable metadata, int metadata_count,
               char *_Nonnull error, size_t error_size);

#endif
