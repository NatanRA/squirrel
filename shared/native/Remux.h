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

/// `ytdl_remux` plus subtitle files (WebVTT or SubRip), each added as a subtitle
/// track: as they are in Matroska and WebM, converted to MP4's own text format
/// (mov_text) in MP4 and MOV. A subtitle file that can't be read or stored is
/// left out rather than failing the whole file.
///
/// - languages, titles: `subtitle_count` entries each (ISO 639-2 like "eng", and
///   a name like "English"); any entry, or either array, may be NULL.
int ytdl_remux_subtitled(const char *_Nonnull const *_Nonnull inputs, int input_count,
                         const char *_Nonnull const *_Nullable subtitles,
                         const char *_Nullable const *_Nullable languages,
                         const char *_Nullable const *_Nullable titles, int subtitle_count,
                         const char *_Nonnull output, const char *_Nonnull format,
                         const char *_Nonnull const *_Nullable metadata, int metadata_count,
                         char *_Nonnull error, size_t error_size);

/// Decodes the first audio stream of `input` and encodes it as an MP3 (LAME,
/// variable bitrate around 190 kbps, stereo or mono) at `output`, tagged with
/// `metadata` like `ytdl_remux`. Returns 0 on success; otherwise writes a
/// message into `error`.
int ytdl_convert_to_mp3(const char *_Nonnull input, const char *_Nonnull output,
                        const char *_Nonnull const *_Nullable metadata, int metadata_count,
                        char *_Nonnull error, size_t error_size);

#endif
