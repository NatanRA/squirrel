# Squirrel for Mac and Windows

Both desktop apps are thin native front ends to the same **engine**: the shared yt-dlp bridge
(`shared/pybridge`) running in a bundled Python process, `host/squirrel_host.py`. The browser
extension uses the same engine. See the main README for build steps.

```
host/
  squirrel_host.py   The engine: JSON requests over stdio (apps) or native messaging (extension)
  remux.py           Finishes downloads with shared/native/Remux.c, loaded through ctypes
  _host.py           Mac only: runs YouTube's JS challenges in the system JavaScriptCore
scripts/
  build_remux.sh     Remux.c + minimal LGPL FFmpeg -> one shared library per platform
  build_runtime.sh   Python + yt-dlp + the above -> build/runtime-<platform>/
macos/               SwiftUI app; embeds build/runtime-macos-<arch> in Squirrel.app
windows/             Compose Desktop app; ships build/runtime-windows-x86_64 as app resources
```

## The engine protocol

The apps start `squirrel-host --stdio` and write one JSON object per line:

```json
{"id": 1, "cmd": "extract", "args": {"url": "https://…"}}
```

Every reply echoes the id and has `ok`, plus `error` on failure:

```json
{"id": 1, "ok": true, "title": "…", "choices": [{"id": "v1080", "label": "1080p", "format_ids": ["137", "140"], "ext": "mp4", …}]}
```

Each request runs on its own thread, so `progress` and `cancel` are answered while a `download`
is still running.

| Command | Arguments | Reply |
|---|---|---|
| `start` | | yt-dlp `version`, `download_dir` |
| `extract` | `url` | Title, thumbnail, and the format `choices` (the same list the phone apps show) |
| `download` | `url`, `format_ids`, `ext`, `audio`, `title`, `job_id` | `path` of the saved file |
| `progress` | `job_id` | `status` (`extracting`, `downloading`, `merging`), bytes, speed, `part`/`parts` |
| `cancel` | `job_id` | |
| `settings` | | `download_dir` |
| `update_status`, `check_update`, `install_update`, `remove_update` | as on mobile | as on mobile |

Browsers start the same launcher with the extension's origin as its argument. The engine then
switches to native messaging framing (a 4-byte length before each JSON message).

**Settings** are shared through `settings.json` in the app's data folder
(`~/Library/Application Support/Squirrel` or `%APPDATA%\Squirrel`): `download_dir`,
`cookies_from_browser`, and whether this computer plays AV1/VP9. The app writes the file, and the
engine reads it on every request, including requests from the extension.

## Running the engine during development

```bash
./desktop/scripts/build_runtime.sh linux-x86_64          # or macos-arm64 on a Mac
echo '{"id":1,"cmd":"extract","args":{"url":"https://www.youtube.com/watch?v=…"}}' \
    | ./desktop/build/runtime-linux-x86_64/squirrel-host --stdio
```

`SQUIRREL_DATA_DIR`, `SQUIRREL_CACHE_DIR` and `SQUIRREL_VERBOSE=1` override the folders and turn
on yt-dlp's verbose log. The Windows app also runs on Linux (`./gradlew run` in `windows/`) with
the Linux engine, which is handy for UI work.
