# yt-dlp for iOS and Android

Native apps that run the real [yt-dlp](https://github.com/yt-dlp/yt-dlp) on the phone, with no
server involved. You paste or share a link, pick a quality (up to 4K) or audio only, and the file
lands in Photos/Gallery or your music folder.

| | iOS | Android |
|---|---|---|
| UI | SwiftUI | Jetpack Compose (Material You) |
| Python | CPython 3.14 via [Python-Apple-support](https://github.com/beeware/Python-Apple-support) | CPython 3.14 via [Chaquopy](https://chaquo.com/chaquopy/) |
| YouTube's JS challenges | JavaScriptCore | V8 via Jetpack JavaScriptEngine |
| Merging streams | Embedded FFmpeg (remux only) | Same FFmpeg code via JNI |
| Where files go | Photos (videos), Files › yt-dlp (audio) | Movies/yt-dlp (Gallery), Music/yt-dlp |
| Background downloads | iOS 26+ continued-processing task | Foreground service with progress notification |
| Getting links in | Paste, `ytdlp://` URL, Shortcuts | Paste, **share sheet**, `ytdlp://` URL |
| Package | Ad-hoc signed IPA (~25 MB) | APK per CPU type (~21 MB) |

## Download

Always the latest release (sign in to GitHub first, since this repo is private):

| Platform | Download | Install |
|---|---|---|
| **Android** 10+ | [yt-dlp-arm64.apk](https://github.com/FormulaLatest/ytdlp-mobile/releases/latest/download/yt-dlp-arm64.apk) | Open it on the phone and allow installing from your browser or file manager, or run `adb install yt-dlp-arm64.apk` |
| **iOS** 18+ | [yt-dlp.ipa](https://github.com/FormulaLatest/ytdlp-mobile/releases/latest/download/yt-dlp.ipa) | Sideload with AltStore, SideStore, Sideloadly or TrollStore |
| Android emulator (Intel) | [yt-dlp-x86_64.apk](https://github.com/FormulaLatest/ytdlp-mobile/releases/latest/download/yt-dlp-x86_64.apk) | `adb install yt-dlp-x86_64.apk` |

Older versions and changes are on the [releases page](https://github.com/FormulaLatest/ytdlp-mobile/releases).
To publish a new release, run `./scripts/release.sh vX.Y.Z` (it builds both apps and uploads them).

## Layout

```
shared/pybridge/   Python used by both apps
  ytdl_bridge.py     JSON API the apps call: extract, download, progress, cancel, updates
  jsc_provider.py    yt-dlp JS challenge provider that calls the host's JS engine via `_host`
  ytdl_updater.py    Installs newer yt-dlp releases from PyPI, falling back to the built-in copy
shared/native/     C used by both apps
  Remux.c            Merges/rewraps streams into one file with FFmpeg's libraries, no re-encoding
ios/               Xcode project (XcodeGen), Swift sources, build scripts
android/           Gradle project, Kotlin sources, JNI glue, build scripts
```

Each app provides a small `_host` module that the shared bridge calls to run JavaScript:
`ios/App/Bridge/PyBridge.c` (JavaScriptCore) and `android/app/src/main/python/_host.py` (V8).

## How it works

Phones can't run yt-dlp the way desktops do, so both apps replace two things it normally shells
out to:

- **A JavaScript runtime (Deno/Node).** YouTube now requires one to solve its signature and "n"
  challenges. `jsc_provider.py` registers a yt-dlp challenge provider that runs the official EJS
  solver in the platform's own engine. Both engines return identical answers on YouTube's current
  player; V8 takes about 0.3 s and JavaScriptCore about 1 s.
- **The ffmpeg command-line tool.** yt-dlp downloads the video and audio streams separately, and
  `Remux.c` merges them with a minimal FFmpeg build that has no encoders or decoders (LGPL-2.1).
  It also rewraps single files, which fixes broken duration headers and turns HLS/MPEG-TS
  downloads into normal MP4s. Every codec is available, including YouTube's 1440p and 4K
  (AV1/VP9 only). Each app reports which codecs its device can play, and the rest are labelled
  "Plays in VLC". Files are tagged with title, artist, year and source URL.

yt-dlp updates itself: once a day each app checks PyPI, downloads and checksum-verifies any newer
release into app storage, and uses it from the next launch. yt-dlp is pure Python, so this needs
no rebuild. The built-in copy stays as a fallback if an update fails to load.

## Build: iOS

Requirements: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
and a host Python **3.14** (used to precompile bytecode that matches the embedded interpreter).

```bash
./ios/scripts/bootstrap.sh     # Python for iOS + yt-dlp into ios/Vendor/
./ios/scripts/build_ffmpeg.sh  # minimal FFmpeg into ios/Vendor/ (about a minute)
./ios/scripts/build_ipa.sh     # -> ios/build/YTDL.ipa
```

Install the IPA with AltStore, SideStore, Sideloadly, or TrollStore, which re-sign it with your
Apple ID. To run from Xcode instead, run `xcodegen generate` in `ios/`, open `YTDL.xcodeproj`, pick
your team under Signing, and run.

## Build: Android

Requirements: the Android SDK with platform 37 and NDK 27 (Android Studio installs both), JDK 17+,
and a host Python **3.14** (Chaquopy uses it to install yt-dlp at build time).

```bash
./android/scripts/build_ffmpeg.sh  # minimal FFmpeg for arm64 + x86_64 (about a minute)
./android/scripts/build_apk.sh     # -> android/build/apk/yt-dlp-arm64.apk (phones)
```

Install `yt-dlp-arm64.apk` on any Android 10+ phone: open it on the phone, or run
`adb install yt-dlp-arm64.apk`. It's signed with the Android debug key; set up your own
`signingConfig` in `android/app/build.gradle.kts` for a stable release key. You can also open
`android/` in Android Studio.

The bundled yt-dlp version is pinned in `ios/scripts/bootstrap.sh` and
`android/app/build.gradle.kts`. The apps update past it on their own.

## Using it

- Paste a link and tap **Download**, then pick a format. On Android you can also **share** a link
  from YouTube, a browser, or any app and pick **yt-dlp**.
- Tap a finished download to play it. Long-press for **Share**, **Retry**, **Delete** and more.
- **Settings › Accounts:** **Sign In to a Site** opens an in-app browser. Log in and tap **Done**,
  and that site's cookies are used for downloads. **Import cookies.txt** accepts a Netscape-format
  export from a desktop browser. YouTube may flag accounts used with yt-dlp, so use a spare
  account there.
- **Settings › Advanced:** **Check Now**, **Nightly Builds** (YouTube fixes before they reach a
  stable release), and **Revert to Built-in Version**.
- **iOS only:** videos go straight into Photos, moved rather than copied (Settings › Saving). To
  share from YouTube, make a Shortcut that opens `ytdlp://download?url=` plus the Shortcut Input.

## Limitations

- **YouTube's bot check.** After many requests from one network, YouTube may answer "Sign in to
  confirm you're not a bot". It usually clears within hours; signing in (Settings › Accounts)
  avoids it.
- **iOS background downloads** need iOS 26+ and haven't been tested on a device yet (the Simulator
  can't run them). On older versions, downloads get about 30 seconds in the background. Sideloading
  tools that rewrite the bundle ID, such as AltStore, disable this feature.
- **Google may refuse sign-in** in the in-app browser. If so, use **Import cookies.txt**.
- Nothing is re-encoded, so converting to MP3, and embedding subtitles and cover art, aren't
  supported yet.
- Debug builds log yt-dlp's verbose output: the system log on iOS, and logcat `python.stdout` on
  Android. The last failure's full log is also saved to `yt-dlp/last_error.log` in the app's cache.
