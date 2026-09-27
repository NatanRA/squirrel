# Third-party notices

Squirrel itself is licensed under the GNU GPL v3.0 (see [LICENSE](LICENSE)). It is built on
other open-source projects. This lists what each app ships, with its license. Full license texts come with each project's source; the build scripts in this
repository show exactly which versions are bundled and where they are downloaded from.

## In every app

| Project | Used for | License |
|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Finding and downloading media | [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) (public domain) |
| [yt-dlp-ejs](https://github.com/yt-dlp/ejs) | Solving YouTube's JavaScript challenges | Unlicense, MIT and ISC |
| [FFmpeg](https://ffmpeg.org) (libavformat, libavcodec, libswresample, libavutil) | Merging and rewrapping streams, embedding subtitles, converting audio to MP3; on iOS, converting AV1 and VP9 videos to HEVC for Photos | [LGPL 2.1 or later](https://ffmpeg.org/legal.html) |
| [LAME](https://lame.sourceforge.io) (libmp3lame) | Encoding MP3s | [LGPL 2.0 or later](https://lame.sourceforge.io/license.txt) |
| [CPython](https://www.python.org) | Running yt-dlp | [PSF License 2.0](https://docs.python.org/3/license.html) |
| [certifi](https://github.com/certifi/python-certifi) | Trusted certificate list | MPL 2.0 |

**About FFmpeg and LAME:** Squirrel uses a minimal FFmpeg build with demuxers, muxers, parsers and
bitstream filters, a few audio decoders and the resampler for MP3 conversion, text subtitle
codecs, and LAME as its MP3 encoder; on iOS also the VP9 and AV1 decoders and the VideoToolbox
HEVC encoder. It has no GPL or non-free parts (`--disable-everything`, no
`--enable-gpl`). The exact configuration and versions are in `ios/scripts/build_ffmpeg.sh`,
`android/scripts/build_ffmpeg.sh`, `desktop/scripts/build_remux.sh` and
`shared/native/build_lame.sh`, which download the unmodified sources from ffmpeg.org and
SourceForge. You can rebuild FFmpeg and LAME, or relink the apps against your own builds, with
those scripts and this repository's source.

## iOS

| Project | License |
|---|---|
| [Python-Apple-support](https://github.com/beeware/Python-Apple-support): the CPython build, plus the libraries it bundles: OpenSSL (Apache 2.0), libffi (MIT), XZ (0BSD), bzip2 (bzip2 license) | CPython under the PSF License; see the project for its own license |

## Android

| Project | License |
|---|---|
| [Chaquopy](https://chaquo.com/chaquopy/) (the Python build and bridge) | MIT |
| Android Jetpack (Compose, Material 3, Lifecycle, Activity, JavaScriptEngine) | Apache 2.0 |
| [Kotlin](https://kotlinlang.org), kotlinx.coroutines, kotlinx.serialization | Apache 2.0 |
| [Coil](https://coil-kt.github.io/coil/) | Apache 2.0 |
| Material icons | Apache 2.0 |

## Mac and Windows

| Project | License |
|---|---|
| [python-build-standalone](https://github.com/astral-sh/python-build-standalone): the CPython build, plus the libraries it bundles: OpenSSL (Apache 2.0), SQLite (public domain), libffi (MIT), XZ (0BSD), bzip2, zlib, Tcl/Tk (BSD-style), mpdecimal (BSD 2-Clause) | CPython under the PSF License; see the project for its own license and the full list |
| [requests](https://github.com/psf/requests) | Apache 2.0 |
| [urllib3](https://github.com/urllib3/urllib3), [charset-normalizer](https://github.com/jawah/charset_normalizer), [Brotli](https://github.com/google/brotli) | MIT |
| [idna](https://github.com/kjd/idna), [websockets](https://github.com/python-websockets/websockets) | BSD 3-Clause |
| [PyCryptodome](https://github.com/Legrandin/pycryptodome) (pycryptodomex) | BSD 2-Clause and public domain |

The Mac app uses macOS's own JavaScriptCore; nothing else is bundled for it.

### Windows only

| Project | License |
|---|---|
| [QuickJS-ng](https://github.com/quickjs-ng/quickjs) (runs yt-dlp-ejs on Windows) | MIT |
| [Compose Multiplatform](https://github.com/JetBrains/compose-multiplatform), Material 3, Material icons | Apache 2.0 |
| [Kotlin](https://kotlinlang.org), kotlinx.coroutines, kotlinx.serialization | Apache 2.0 |
| [Coil](https://coil-kt.github.io/coil/), [OkHttp](https://square.github.io/okhttp/) | Apache 2.0 |
| The Java runtime bundled by jpackage ([OpenJDK](https://openjdk.org)) | GPL 2.0 with the Classpath Exception |

## Browser extension

The extension contains only Squirrel's own code and icon.
