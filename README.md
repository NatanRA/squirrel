# yt-dlp for iOS

A native SwiftUI wrapper that runs the real [yt-dlp](https://github.com/yt-dlp/yt-dlp) on-device,
with no server involved. You can paste a link, pick a quality, and the file is saved to the app's
folder in the Files app. From there you can share it or save it to Photos.

## How it works

| Piece | What it does |
|---|---|
| `Vendor/Python.xcframework` | CPython 3.14 for iOS from [BeeWare's Python-Apple-support](https://github.com/beeware/Python-Apple-support) |
| `Vendor/app_packages` | `yt-dlp`, `yt-dlp-ejs` (YouTube challenge solver scripts) and `certifi`, precompiled to bytecode |
| `App/Bridge/PyBridge.c` | Starts the interpreter, calls into Python from any thread, and exposes `_iosbridge.run_js` |
| `App/PythonApp/ytdl_bridge.py` | JSON API used by the app: `extract`, `download`, `progress`, `cancel`, updates |
| `App/PythonApp/jsc_provider.py` | yt-dlp JS challenge provider backed by JavaScriptCore |
| `App/PythonApp/ytdl_updater.py` | Installs newer yt-dlp releases from PyPI, with fallback to the built-in copy |
| `App/Sources/PythonRuntime.swift` | Swift side of the bridge, plus the **JavaScriptCore** runner |
| `App/Sources/MediaMerger.swift` | Muxes separate video and audio streams with AVFoundation |
| `App/Sources/BackgroundContinuation.swift` | Keeps downloads running in the background (iOS 26+) |
| `App/Sources/CookieStore.swift`, `SignInView.swift` | In-app sign-in and cookies.txt import for sites that need an account |

iOS apps can't spawn subprocesses, which rules out two things yt-dlp normally depends on:

- **External JS runtime (Deno/Node).** YouTube downloads need a JS runtime to solve the signature
  and "n" challenges. The bridge registers a custom yt-dlp challenge provider that runs the
  official EJS solver in the system JavaScriptCore instead, which takes about 2 s per video.
- **ffmpeg.** yt-dlp downloads the video and audio streams separately, and the app merges them
  with `AVAssetExportSession` (passthrough, no re-encode). AVFoundation can only mux H.264 + AAC
  into MP4, so merged options are limited to H.264. That covers up to 1080p60 on YouTube.
  Single-file formats of any codec are offered as-is.

## Build

Requirements: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
and a host Python **3.14** (used to precompile bytecode that matches the embedded interpreter).

```bash
./scripts/bootstrap.sh     # downloads Python for iOS + yt-dlp into Vendor/
./scripts/build_ipa.sh     # -> build/YTDL.ipa
```

The IPA is ad-hoc signed. Install it with AltStore, SideStore, Sideloadly, or TrollStore, which
re-sign it with your Apple ID. To run from Xcode instead, run `xcodegen generate`, open
`YTDL.xcodeproj`, pick your team under Signing, and run.

The app updates yt-dlp by itself (see below). To change the version bundled in the IPA instead,
run `YTDLP_VERSION=<version> ./scripts/bootstrap.sh` and rebuild. If that release needs a new
`yt-dlp-ejs`, set `EJS_VERSION` too.

## Using it

- Paste a link and tap **Download**, then pick a format.
- Tap a finished download to play it. Long-press for **Share**, **Save to Photos**, **Retry**, or
  **Delete**.
- Files appear under *Files → On My iPhone → yt-dlp*.
- **Share-sheet shortcut:** in Shortcuts, create a shortcut that receives URLs from the share sheet
  and runs *Open URL* with `ytdlp://download?url=` followed by the *Shortcut Input* variable. The
  app then opens with that link already loaded.

### Settings (gear icon)

- **Updates are automatic.** Once a day (and on first launch) the app checks PyPI for a newer
  yt-dlp. If there is one, the app downloads it in the background and verifies its checksum,
  then uses it from the next launch. Nothing needs tapping. The version built into the app stays
  as a fallback: it's used until the first update arrives, and whenever an update fails to load.
  yt-dlp is pure Python, so none of this needs a rebuild or re-signing. It would not be allowed
  on the App Store.
- **Advanced** holds the manual controls: **Check Now**, **Nightly Builds** (YouTube fixes
  before they reach a stable release), and **Revert to Built-in Version**. Revert removes a
  downloaded update that misbehaves, and that version isn't reinstalled automatically afterwards.
- **Accounts.** **Sign In to a Site** opens an in-app browser. Log in and tap **Done**, and the
  site's cookies are saved for yt-dlp. **Import cookies.txt** accepts a Netscape-format cookie
  export from a desktop browser. Swipe a site to sign out. YouTube may flag accounts used with
  yt-dlp, so use a spare account there.

## Limitations

- **Background downloads** keep running after you leave the app on **iOS 26+**, with a
  system progress indicator. You or the system can stop them from there. On older iOS versions,
  downloads get about 30 seconds after the app leaves the screen. The iOS 26 path can't run in
  the Simulator, so it needs testing on a real device. Some sideloading tools (e.g. AltStore)
  rewrite the bundle ID. That disables this feature, because the permitted task identifier no
  longer matches, and downloads fall back to the 30-second behaviour.
- **Google may refuse sign-in** inside the in-app browser. If that happens, export cookies from a
  desktop browser and use **Import cookies.txt**.
- Formats that would need ffmpeg (VP9/AV1 merges, remuxing HLS MPEG-TS to MP4, embedding
  subtitles or thumbnails) aren't available. MPEG-TS HLS downloads are saved as `.ts`, which VLC or
  Infuse can play.
- The last failure's full yt-dlp log is saved to `Library/Caches/yt-dlp/last_error.log`. Debug
  builds also log yt-dlp's verbose output.
