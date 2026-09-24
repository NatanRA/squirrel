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
| `App/PythonApp/ytdl_bridge.py` | JSON API used by the app: `extract`, `download`, `progress`, `cancel` |
| `App/Sources/PythonRuntime.swift` | Swift side of the bridge, plus the **JavaScriptCore** runner |
| `App/Sources/MediaMerger.swift` | Muxes separate video and audio streams with AVFoundation |

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

To update yt-dlp (YouTube breaks things often), run
`YTDLP_VERSION=<new version> ./scripts/bootstrap.sh`, then rebuild. If a new yt-dlp release
requires a new `yt-dlp-ejs`, set `EJS_VERSION` too.

## Using it

- Paste a link and tap **Get Video**, then pick a format.
- Tap a finished download to play it. Long-press for **Share**, **Save to Photos**, **Retry**, or
  **Delete**.
- Files appear under *Files → On My iPhone → yt-dlp*.
- **Share-sheet shortcut:** in Shortcuts, create a shortcut that receives URLs from the share sheet
  and runs *Open URL* with `ytdlp://download?url=` followed by the *Shortcut Input* variable. The
  app then opens with that link already loaded.

## Limitations

- Downloads only continue for a short time after the app leaves the foreground, because iOS
  suspends it. Keep the app open for long downloads.
- Formats that would need ffmpeg (VP9/AV1 merges, remuxing HLS MPEG-TS to MP4, embedding
  subtitles or thumbnails) aren't available. MPEG-TS HLS downloads are saved as `.ts`, which VLC or
  Infuse can play.
- Sites that require login (for example Vimeo) will fail, because the app has no cookie support
  yet.
- The last failure's full yt-dlp log is saved to `Library/Caches/yt-dlp/last_error.log`. Debug
  builds also log yt-dlp's verbose output.
