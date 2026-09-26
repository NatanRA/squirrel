<p align="center"><img src="branding/icon.svg" width="96" alt=""></p>

# Squirrel

Native apps for iPhone, Android, Mac and Windows that run the real
[yt-dlp](https://github.com/yt-dlp/yt-dlp) on your own device, with no server involved. Paste or
share a link, pick a quality (up to 4K) or audio only, and the file is saved: to Photos or the
Gallery on a phone, or to your Downloads folder on a computer. A small browser extension sends
links to the desktop app.

| | iOS | Android | Mac | Windows |
|---|---|---|---|---|
| UI | SwiftUI | Jetpack Compose (Material 3) | SwiftUI | Compose Desktop (Material 3) |
| Python | CPython 3.14 via [Python-Apple-support](https://github.com/beeware/Python-Apple-support) | CPython 3.14 via [Chaquopy](https://chaquo.com/chaquopy/) | CPython 3.14 via [python-build-standalone](https://github.com/astral-sh/python-build-standalone) | Same |
| YouTube's JS challenges | JavaScriptCore | V8 via Jetpack JavaScriptEngine | JavaScriptCore | [Deno](https://deno.com) |
| Merging streams | Embedded FFmpeg (remux only) | Same FFmpeg code via JNI | Same FFmpeg code as a library | Same |
| Where files go | Photos (videos), Files › Squirrel (audio) | Movies/Squirrel (Gallery), Music/Squirrel | ~/Downloads/Squirrel (you can change it) | Same |
| Getting links in | Paste, **share sheet**, `squirrel://` URL | Paste, **share sheet**, `squirrel://` URL | Paste, **Share menu**, browser extension | Paste, browser extension |
| Package | Ad-hoc signed IPA (~25 MB) | APK per CPU type (~21 MB) | Disk image per CPU type | MSI installer |

None of this can go in the App Store or Google Play: both stores reject apps that download from
YouTube. The apps are sideloaded instead, as described below.

## Download

Always the latest release (while this repo is private, sign in to GitHub first):

| Platform | Download | Install |
|---|---|---|
| **Android** 10+ | [Squirrel-arm64.apk](https://github.com/FormulaLatest/squirrel/releases/latest/download/Squirrel-arm64.apk) | Open it on the phone and allow installing from your browser or file manager, or run `adb install Squirrel-arm64.apk` |
| **iOS** 18+ | [Squirrel.ipa](https://github.com/FormulaLatest/squirrel/releases/latest/download/Squirrel.ipa) | Sideload with AltStore, SideStore, Sideloadly or TrollStore |
| **Mac** (Apple silicon), macOS 14+ | [Squirrel-macos-arm64.dmg](https://github.com/FormulaLatest/squirrel/releases/latest/download/Squirrel-macos-arm64.dmg) | Drag Squirrel to Applications. It isn't notarized, so the first time, right-click it and choose **Open** |
| **Windows** 10/11 (x64) | [Squirrel.msi](https://github.com/FormulaLatest/squirrel/releases/latest/download/Squirrel.msi) | Run the installer. It installs just for you, so no admin rights are needed. SmartScreen may warn about an unknown publisher: choose **More info › Run anyway** |
| **Browser extension** | [Squirrel-extension.zip](https://github.com/FormulaLatest/squirrel/releases/latest/download/Squirrel-extension.zip) | See [extension/README.md](extension/README.md). Needs the Mac or Windows app installed |
| Android emulator (Intel) | [Squirrel-x86_64.apk](https://github.com/FormulaLatest/squirrel/releases/latest/download/Squirrel-x86_64.apk) | `adb install Squirrel-x86_64.apk` |

Older versions and changes are on the [releases page](https://github.com/FormulaLatest/squirrel/releases).
To publish a new release, run `./scripts/release.sh vX.Y.Z` on a Mac (see [Releasing](#releasing)).

## Layout

```
shared/pybridge/   Python used by every app
  ytdl_bridge.py     JSON API the apps call: extract, download, progress, cancel, updates
  jsc_provider.py    yt-dlp JS challenge provider that calls the app's JS engine via `_host`
  ytdl_updater.py    Installs newer yt-dlp releases from PyPI, falling back to the built-in copy
shared/native/     C used by every app
  Remux.c            Merges/rewraps streams into one file with FFmpeg's libraries, no re-encoding
ios/               Xcode project (XcodeGen), Swift sources, build scripts
android/           Gradle project, Kotlin sources, JNI glue, build scripts
desktop/
  host/              The desktop engine: runs the shared bridge in its own Python process
  scripts/           Builds that engine (Python + yt-dlp + Remux.c) for each platform
  macos/             Mac app (SwiftUI, XcodeGen)
  windows/           Windows app (Compose Desktop, Gradle)
extension/         Chrome/Edge/Brave/Firefox extension (Manifest V3)
branding/          Icon sources and colours
```

The mobile apps each provide a small `_host` module that the shared bridge calls to run
JavaScript: `ios/App/Bridge/PyBridge.c` (JavaScriptCore) and
`android/app/src/main/python/_host.py` (V8). On the Mac, `desktop/host/_host.py` calls the system
JavaScriptCore through ctypes. Windows has no built-in engine that yt-dlp can use, so it bundles Deno.

## How it works

Phones can't run yt-dlp the way desktops do, so the mobile apps replace two things it normally
shells out to:

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

The desktop apps use the same pieces rather than a separate yt-dlp GUI, so every platform picks
formats and names files the same way. There, the bridge runs in a separate Python process: the
**engine** (`desktop/host/squirrel_host.py`). It takes one JSON request per line from the app,
downloads, merges with `Remux.c` (built as a small shared library), and saves into the download
folder. The browser extension talks to that same engine through
[native messaging](https://developer.mozilla.org/docs/Mozilla/Add-ons/WebExtensions/Native_messaging).
Each desktop app registers the engine with installed browsers every time it starts, so the app
doesn't have to be open for the extension to work.

yt-dlp updates itself: once a day each app checks PyPI, downloads and checksum-verifies any newer
release into app storage, and uses it from the next launch (on desktop, as soon as the engine
restarts). yt-dlp is pure Python, so this needs no rebuild. The built-in copy stays as a fallback
if an update fails to load.

## Build: iOS

Requirements: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
and a host Python **3.14** (used to precompile bytecode that matches the embedded interpreter).

```bash
./ios/scripts/bootstrap.sh     # Python for iOS + yt-dlp into ios/Vendor/
./ios/scripts/build_ffmpeg.sh  # minimal FFmpeg into ios/Vendor/ (about a minute)
./ios/scripts/build_ipa.sh     # -> ios/build/Squirrel.ipa
```

Install the IPA with AltStore, SideStore, Sideloadly, or TrollStore, which re-sign it with your
Apple ID. To run from Xcode instead, run `xcodegen generate` in `ios/`, open `Squirrel.xcodeproj`,
pick your team under Signing, and run.

## Build: Android

Requirements: the Android SDK with platform 37 and NDK 27 (Android Studio installs both), JDK 17+,
and a host Python **3.14** (Chaquopy uses it to install yt-dlp at build time).

```bash
./android/scripts/build_ffmpeg.sh  # minimal FFmpeg for arm64 + x86_64 (about a minute)
./android/scripts/build_apk.sh     # -> android/build/apk/Squirrel-arm64.apk (phones)
```

Install `Squirrel-arm64.apk` on any Android 10+ phone: open it on the phone, or run
`adb install Squirrel-arm64.apk`. It's signed with the Android debug key; set up your own
`signingConfig` in `android/app/build.gradle.kts` for a stable release key. You can also open
`android/` in Android Studio.

The bundled yt-dlp version is pinned in `ios/scripts/bootstrap.sh`,
`android/app/build.gradle.kts` and `desktop/scripts/build_runtime.sh`. The apps update past it on
their own.

## Build: Mac

Requirements: Xcode 16+ and XcodeGen, plus `curl` and any `python3` with pip (the build downloads
its own Python 3.14).

```bash
./desktop/macos/scripts/build_dmg.sh                # -> desktop/build/Squirrel-macos-arm64.dmg
ARCH=x86_64 ./desktop/macos/scripts/build_dmg.sh    # Intel Macs
```

That runs `desktop/scripts/build_runtime.sh macos-<arch>` first, which assembles the engine:
standalone Python, yt-dlp, and `Remux.c` with a minimal FFmpeg (`build_remux.sh`). To work in
Xcode, build the engine once, then run `xcodegen generate` in `desktop/macos/` and open
`Squirrel.xcodeproj`. The app is ad-hoc signed; set your team under Signing to sign it properly.

## Build: Windows

The engine is built with bash, and the installer with Gradle on Windows:

```bash
# On Linux, macOS or WSL, with mingw-w64 installed (apt install mingw-w64 / brew install mingw-w64)
./desktop/scripts/build_runtime.sh windows-x86_64
```

```powershell
# On Windows, with JDK 17+ and the WiX Toolset 3 (for the MSI) installed
cd desktop\windows
.\gradlew packageMsi    # -> build\compose\binaries\main\msi\Squirrel-1.0.0.msi
```

`.\gradlew run` starts the app without packaging it. Pass `-PappVersion=1.2.3` to set the
installer version.

## Build: browser extension

The extension needs no build step. For Chrome, Edge and Brave, load `extension/` unpacked. For
Firefox, package and sign it with `web-ext`. See [extension/README.md](extension/README.md).

## Releasing

`./scripts/release.sh vX.Y.Z` runs on a Mac. It builds the iOS, Android and Mac apps, zips the
extension, and publishes them all as a GitHub release. Build the Windows installer on Windows
first and pass its path to include it:

```bash
WINDOWS_MSI=/path/to/Squirrel-1.2.3.msi ./scripts/release.sh v1.2.3
```

## Using it

- Paste a link and tap **Download**, then pick a format. On a phone or Mac you can also **share** a
  link from YouTube, a browser, or any app and pick **Squirrel**; the app opens with the formats
  ready. On a Mac, turn it on first in System Settings › General › Login Items & Extensions ›
  Sharing.
- **Settings › Pasting (phones):** with **Auto-Paste Copied Links** on, opening Squirrel after
  copying a link pastes it and shows the formats. On iOS, set Settings › Apps › Squirrel ›
  **Paste from Other Apps** to **Allow** so iOS doesn't ask each time.
- Tap a finished download to play it. Long-press for **Share**, **Retry**, **Delete** and more.
  On a phone, **Delete** also removes the file from Photos or the Gallery (iOS asks you to
  confirm); on iOS, **Remove from List** keeps the video in Photos. On a computer, double-click to
  open, or right-click for **Show in Finder/Folder** and more.
- **Browser extension:** click the squirrel, check the link (it starts with the page you're on),
  pick a format, and the file is saved to the desktop app's download folder. Downloads keep going
  after the popup closes.
- **Settings › Accounts (phones):** **Sign In to a Site** opens an in-app browser. Log in and tap
  **Done**, and that site's cookies are used for downloads. **Import cookies.txt** accepts a
  Netscape-format export from a desktop browser.
- **Settings › Accounts (computers):** **Use cookies from** reads the cookies of a browser you're
  signed in with. On Windows, Firefox works best: recent Chrome versions lock their cookies while
  Chrome is running. YouTube may flag accounts used with yt-dlp, so use a spare account there.
- **Settings › Advanced › Save Locations (phones):** pick where videos and audio go instead of
  Photos/Files › Squirrel (iOS) or Movies/Music › Squirrel (Android). On iOS that can be any folder
  in the Files app, including other apps' folders like VLC or Documents, and iCloud Drive; on
  Android, any folder the system file picker offers.
- **Updates:** **Check Now**, **Nightly Builds** (YouTube fixes before they reach a
  stable release), and **Revert to Built-in Version**.
- **iOS only:** videos go straight into Photos, moved rather than copied (Settings › Saving).
  Links with `ytdlp://` from before the rename still work. With a free Apple ID, AltStore and
  SideStore count the share extension as one more app ID.

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
- The Mac app isn't notarized and the Windows installer isn't code-signed, so both show a warning
  the first time.
- Debug builds log yt-dlp's verbose output: the system log on iOS, and logcat `python.stdout` on
  Android. On desktop, set `SQUIRREL_VERBOSE=1` before starting the app. The last failure's full
  log is also saved to `yt-dlp/last_error.log` in the app's cache folder.

## License

Squirrel is free software under the [GNU General Public License v3.0](LICENSE): you can use,
change and share it, and anything you distribute that's built from it must stay open source under
the same license. It bundles yt-dlp, FFmpeg, Python and other projects under their own licenses,
all compatible with the GPL; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Squirrel isn't affiliated with yt-dlp, YouTube or any site it downloads from. Only download what
you have the right to.
