"""Bridge between the Swift app and yt-dlp.

Every public function takes a JSON string and returns a JSON string, so the
C layer only ever has to shuttle UTF-8 text back and forth.

Shared by the iOS and Android apps. Neither can rely on spawning ffmpeg or an
external JS runtime (deno/node/...), so instead:
  * YouTube's JS challenges are solved with the platform's JS engine, exposed
    to Python by the app as the module ``_host`` (see jsc_provider.py).
  * Separate video/audio streams are downloaded one at a time and merged by
    the app with an embedded FFmpeg library (remux only, no re-encoding).
"""
from __future__ import annotations

import copy
import json
import os
import re
import shutil
import threading
import traceback

import ytdl_updater

# Prefers an over-the-air update; also registers the JavaScriptCore provider.
ytdl_updater.load_ytdlp()

import yt_dlp  # noqa: E402


_config = {'cache_dir': None, 'cookie_file': None, 'av1_decode': False, 'vp9_decode': False}
_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()


class Cancelled(Exception):
    pass


class _Logger:
    def __init__(self, job=None):
        self.job = job
        self.lines = []

    def _add(self, msg):
        if _config.get('verbose'):
            print(msg)  # the system log on iOS, logcat (python.stdout) on Android
        self.lines.append(msg)
        del self.lines[:-200]
        if self.job is not None:
            self.job['log'] = msg

    def debug(self, msg):
        if not msg.startswith('[debug] ') or _config.get('verbose'):
            self._add(msg)

    def info(self, msg):
        self._add(msg)

    def warning(self, msg):
        self._add(f'WARNING: {msg}')

    def error(self, msg):
        self._add(msg)


def _base_opts(logger):
    opts = {
        'quiet': True,
        'noprogress': True,
        'noplaylist': True,
        'logger': logger,
        # The app's own JS engine by default; desktop builds without one pass Deno
        'js_runtimes': _config.get('js_runtimes') or {'jsc': {}},
        'socket_timeout': 30,
        'retries': 5,
        'fragment_retries': 10,
        'concurrent_fragment_downloads': 4,
        'verbose': bool(_config.get('verbose')),
    }
    if _config['cache_dir']:
        opts['cachedir'] = _config['cache_dir']
    if _config.get('extractor_args'):
        opts['extractor_args'] = _config['extractor_args']
    if _config.get('cookies_from_browser'):
        # Desktop: read the cookies of a browser the user is signed in with
        opts['cookiesfrombrowser'] = (_config['cookies_from_browser'],)
    cookie_file = _config.get('cookie_file')
    if cookie_file and os.path.exists(cookie_file) and _config.get('cache_dir'):
        # yt-dlp writes the jar back on exit; give it a private copy so the
        # app's cookie file is never clobbered by concurrent jobs.
        copy_path = os.path.join(_config['cache_dir'], f'cookies-{threading.get_ident()}.txt')
        shutil.copyfile(cookie_file, copy_path)
        opts['cookiefile'] = copy_path
    return opts


def _ok(**data):
    return json.dumps({'ok': True, **data})


# Plain-language versions of errors people commonly hit; the original stays in the log.
_HINTS = (
    (('confirm you’re not a bot', "confirm you're not a bot"),
     "YouTube is asking this network to prove it isn't a bot. Try again later, or sign in to "
     "YouTube in Settings › Accounts."),
    (('Your IP address is blocked',),
     "This post isn't available from your network or region."),
    (('Private video', 'This video is private'),
     "This video is private. If you have access, sign in to the site in Settings › Accounts."),
    (('Unsupported URL',),
     "yt-dlp doesn't recognise this link. Check that it points to a video or audio page."),
)


def _err(e, logger=None):
    msg = str(e) or e.__class__.__name__
    for needles, hint in _HINTS:
        if any(n in msg for n in needles):
            if logger:
                logger.lines.append(msg)
            msg = hint
            break
    # Keep the last failure's log around for debugging (Caches/yt-dlp/last_error.log)
    if _config.get('cache_dir'):
        try:
            with open(os.path.join(_config['cache_dir'], 'last_error.log'), 'w') as f:
                f.write('\n'.join([msg, *(logger.lines if logger else []), traceback.format_exc()]))
        except OSError:
            pass
    # yt-dlp prefixes messages with ANSI-free "ERROR: " already in most cases
    return json.dumps({
        'ok': False,
        'error': msg.removeprefix('ERROR: '),
        'log': logger.lines[-30:] if logger else [],
        'traceback': traceback.format_exc(),
    })


def configure(arg: str) -> str:
    _config.update(json.loads(arg))
    if _config.get('cache_dir'):
        os.makedirs(_config['cache_dir'], exist_ok=True)
    return _ok(version=yt_dlp.version.__version__)


# region: updates

def update_status(arg: str) -> str:
    return _ok(
        version=yt_dlp.version.__version__,
        source=ytdl_updater.load_state['source'],
        load_error=ytdl_updater.load_state['error'],
        bundled_version=ytdl_updater.bundled_version(),
        pending_version=ytdl_updater.installed_update_version(),
    )


def check_update(arg: str) -> str:
    params = json.loads(arg)
    try:
        latest = ytdl_updater.latest_version(nightly=params.get('nightly', False))
        # Compare with whatever will load next launch, not just what's running now.
        baseline = ytdl_updater.installed_update_version() or yt_dlp.version.__version__
        newer = ytdl_updater.version_tuple(latest) > ytdl_updater.version_tuple(baseline)
        return _ok(latest=latest, current=yt_dlp.version.__version__, available=newer)
    except Exception as e:
        return _err(e)


def install_update(arg: str) -> str:
    params = json.loads(arg)
    try:
        ytdl_updater.install(params['version'])
        return _ok(version=params['version'])
    except Exception as e:
        return _err(e)


def remove_update(arg: str) -> str:
    ytdl_updater.remove()
    return _ok(bundled_version=ytdl_updater.bundled_version())

# endregion


# region: format presets

# yt-dlp uses None for "unknown" and 'none' for "definitely absent", so a
# format with unknown codecs (common for direct MP4s, e.g. on X) counts as
# possibly having both audio and video.

def _size(f):
    return f.get('filesize') or f.get('filesize_approx') or 0


def _size_text(*fs):
    """Human size of the given formats; "~" when any is only an estimate."""
    total = sum(_size(f) for f in fs)
    if not total or any(not _size(f) for f in fs):
        return None
    approx = any(not f.get('filesize') for f in fs)
    return ('~' if approx else '') + _human(total)


_STANDARD_HEIGHTS = (144, 240, 360, 480, 720, 1080, 1440, 2160, 4320)


def _resolution(f):
    """Short side of the frame: 1080 for both 1920x1080 and a vertical 1080x1920."""
    width, height = f.get('width'), f.get('height')
    if width and height:
        return min(width, height)
    match = re.search(r'\b(\d{3,4})p', f.get('format_note') or '')
    return int(match.group(1)) if match else (height or 0)


def _label(res):
    """Snap near-standard sizes to their usual name (854x470 is "480p")."""
    nearest = min(_STANDARD_HEIGHTS, key=lambda h: abs(h - res))
    return nearest if abs(nearest - res) <= nearest * 0.05 else res


def _is_drc(f):
    # YouTube's dynamic-range-compressed audio: quieter peaks, worse for music
    return 'drc' in (f.get('format_id') or '').lower() or 'DRC' in (f.get('format_note') or '')


def _audio_rank(f):
    # Direct files with a declared codec over HLS streams (YouTube's HLS audio
    # is raw AAC in a .mp4-named file), then original language.
    return (not _is_drc(f), 'm3u8' not in (f.get('protocol') or ''), f.get('acodec') is not None,
            f.get('language_preference') or 0, f.get('abr') or f.get('tbr') or 0)


def _quality(f):
    # Direct HTTPS beats HLS at equal resolution/fps: one request, known size
    return (_resolution(f), f.get('fps') or 0, f.get('protocol') == 'https', f.get('tbr') or 0)


_CODEC_NAMES = {'avc1': 'H.264', 'h264': 'H.264', 'hvc1': 'HEVC', 'hev1': 'HEVC', 'vp09': 'VP9',
                'vp9': 'VP9', 'av01': 'AV1', 'mp4a': 'AAC', 'aac': 'AAC', 'opus': 'Opus', 'mp3': 'MP3'}


def _codec(codec):
    if not codec or codec == 'none':
        return None
    base = codec.split('.')[0].lower()
    return _CODEC_NAMES.get(base, base.upper())


def _detail(*parts):
    """Join non-empty parts, dropping repeats such as "MP3 · MP3"."""
    out = []
    for part in parts:
        if part and part.lower() not in (p.lower() for p in out):
            out.append(part)
    return ' · '.join(out)


def _human(n):
    if not n:
        return None
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return f'{n:.0f} {unit}' if unit in ('B', 'KB') else f'{n:.1f} {unit}'
        n /= 1024


# Codecs FFmpeg's MP4 muxer accepts; anything else is kept in Matroska.
_MP4_VIDEO = {'H.264', 'HEVC', 'AV1', 'VP9', None}
_MP4_AUDIO = {'AAC', 'MP3', 'Opus', 'FLAC', 'ALAC', 'AC3', 'EAC3', None}


def _plays_natively(f):
    """Whether the platform's own players (Photos/Gallery, Files) can play the video."""
    codec = _codec(f.get('vcodec'))
    return (codec in ('H.264', 'HEVC', None)
            or (codec == 'AV1' and _config.get('av1_decode'))
            or (codec == 'VP9' and _config.get('vp9_decode')))  # Android: yes; iOS: no


def _video_rank(f):
    # H.264 first (plays and edits anywhere), then AV1 (much smaller files),
    # then whatever else exists at that size.
    preference = {'H.264': 3, 'HEVC': 2, 'AV1': 2, 'VP9': 1}.get(_codec(f.get('vcodec')), 0)
    return (_plays_natively(f), preference, f.get('fps') or 0, f.get('protocol') == 'https', f.get('tbr') or 0)


def _container(video, audio=None):
    """Output extension for the app's remux step."""
    vcodec = _codec(video.get('vcodec')) if video else None
    acodec = _codec(audio.get('acodec')) if audio else _codec((video or {}).get('acodec'))
    return 'mp4' if vcodec in _MP4_VIDEO and acodec in _MP4_AUDIO else 'mkv'


def _audio_container(f):
    codec = _codec(f.get('acodec'))
    ext = f.get('ext')
    # Audio in an MP4 wrapper is conventionally .m4a (e.g. X's undeclared-codec audio)
    return {'AAC': 'm4a', 'ALAC': 'm4a', 'MP3': 'mp3', 'FLAC': 'flac'}.get(codec) or ('m4a' if ext in (None, 'mp4') else ext)


def _presets(info):
    """Build a short list of download choices.

    yt-dlp downloads each chosen format separately and the app remuxes them
    into one file with FFmpeg (no re-encoding), so any codec works; choices
    prefer what Apple's players can play and flag the rest.
    """
    formats = [f for f in (info.get('formats') or [info]) if f.get('url') or f.get('manifest_url')]
    # storyboards and other junk
    formats = [f for f in formats if f.get('ext') not in ('mhtml',) and f.get('protocol') != 'mhtml']

    audio_only = [f for f in formats if f.get('vcodec') == 'none' and f.get('acodec') != 'none']
    video_only = [f for f in formats if f.get('acodec') == 'none' and f.get('vcodec') != 'none' and _resolution(f)]
    progressive = [f for f in formats if f.get('acodec') != 'none' and f.get('vcodec') != 'none' and _resolution(f)]

    # AAC merges into MP4 and plays everywhere, so prefer it for merging too
    aac = [f for f in audio_only
           if f.get('ext') in ('m4a', 'mp4') or (f.get('acodec') or '').startswith('mp4a')]
    best_audio = max(aac, key=_audio_rank, default=None) or max(audio_only, key=_audio_rank, default=None)

    choices = {}

    def add(f, ids, container, *extra):
        res = _label(_resolution(f))
        key = f'v{res}'  # by displayed size, so 854x470 and 872x480 share "480p"
        if key in choices:
            return
        fps = f' {int(f["fps"])}fps' if (f.get('fps') or 0) > 30 else ''
        name = {2160: '4K', 4320: '8K'}.get(res, f'{res}p')
        note = None if _plays_natively(f) else 'Plays in VLC'
        choices[key] = {'id': key, 'label': name + fps, 'kind': 'video', 'height': res, 'ext': container,
                        'format_ids': ids, 'playable': note is None,
                        'detail': _detail(container.upper(), _codec(f.get('vcodec')), *extra, note)}

    # 1. Single files with audio and video, best per resolution
    for f in sorted(progressive, key=lambda f: (_label(_resolution(f)), *_video_rank(f)), reverse=True):
        add(f, [f['format_id']], _container(f), _size_text(f))

    # 2. Separate video + audio, merged by the app, for resolutions not covered above
    if best_audio:
        for f in sorted(video_only, key=lambda f: (_label(_resolution(f)), *_video_rank(f)), reverse=True):
            add(f, [f['format_id'], best_audio['format_id']], _container(f, best_audio),
                _size_text(f, best_audio))

    # 3. Silent videos (e.g. GIF-style posts) have no audio to merge
    if not audio_only and not progressive:
        for f in sorted(video_only, key=lambda f: (_label(_resolution(f)), *_video_rank(f)), reverse=True):
            add(f, [f['format_id']], _container(f), 'No audio', _size_text(f))

    video = sorted(choices.values(), key=lambda c: c['height'], reverse=True)

    audio = []
    if best_audio:
        abr = best_audio.get('abr')
        container = _audio_container(best_audio)
        audio.append({'id': 'audio', 'label': 'Audio', 'kind': 'audio', 'height': 0, 'ext': container,
                      'format_ids': [best_audio['format_id']], 'playable': True,
                      'detail': _detail(container.upper(), _codec(best_audio.get('acodec')),
                                        f'{abr:.0f} kbps' if abr else None, _size_text(best_audio))})

    if not video and not audio and formats:
        # No usable format metadata (common for generic extractors): let yt-dlp pick
        video = [{'id': 'best', 'label': 'Best', 'detail': 'Best single file', 'format_ids': ['best'],
                  'kind': 'video', 'height': 0, 'ext': 'mp4', 'playable': True}]

    return video + audio

# endregion


def extract(arg: str) -> str:
    params = json.loads(arg)
    logger = _Logger()
    try:
        with yt_dlp.YoutubeDL(_base_opts(logger)) as ydl:
            info = ydl.extract_info(params['url'], download=False)
            if info.get('_type') == 'playlist':
                entries = [e for e in (info.get('entries') or []) if e]
                if not entries:
                    raise ValueError('Playlist is empty')
                info = entries[0]
            return _ok(
                id=info.get('id'),
                title=info.get('title'),
                uploader=info.get('uploader') or info.get('channel'),
                duration=info.get('duration'),
                thumbnail=info.get('thumbnail'),
                webpage_url=info.get('webpage_url') or params['url'],
                extractor=info.get('extractor_key'),
                choices=_presets(info),
            )
    except Exception as e:
        return _err(e, logger)


def download(arg: str) -> str:
    """Blocking. Call from a background thread; poll ``progress`` meanwhile."""
    params = json.loads(arg)
    job_id = params['job_id']
    job = {'status': 'starting', 'downloaded': 0, 'total': 0, 'speed': 0, 'eta': None,
           'part': 0, 'parts': len(params['format_ids']), 'cancel': False, 'log': ''}
    with _jobs_lock:
        _jobs[job_id] = job
    logger = _Logger(job)
    out_dir = params['out_dir']
    os.makedirs(out_dir, exist_ok=True)

    files = []

    def hook(d):
        if job['cancel']:
            raise Cancelled('Cancelled')
        if d['status'] == 'downloading':
            job['status'] = 'downloading'
            job['downloaded'] = d.get('downloaded_bytes') or 0
            job['total'] = d.get('total_bytes') or d.get('total_bytes_estimate') or 0
            job['speed'] = d.get('speed') or 0
            job['eta'] = d.get('eta')
        elif d['status'] == 'finished':
            files.append(d.get('filename'))

    opts = _base_opts(logger)
    opts.update({
        'progress_hooks': [hook],
        'paths': {'home': out_dir, 'temp': out_dir},
        'outtmpl': '%(title).120B [%(id)s].f%(format_id)s.%(ext)s',
        'restrictfilenames': False,
        'windowsfilenames': True,
        'overwrites': True,
    })

    def run(ydl):
        job['status'] = 'extracting'
        raw = ydl.extract_info(params['url'], download=False, process=False)
        if raw.get('_type') in ('playlist', 'multi_video'):
            raw = next(e for e in raw['entries'] if e)
            if raw.get('_type') == 'url':
                raw = ydl.extract_info(raw['url'], download=False, process=False)
        for i, fid in enumerate(params['format_ids']):
            if job['cancel']:
                raise Cancelled('Cancelled')
            job['part'] = i + 1
            job['downloaded'] = job['total'] = 0
            before = len(files)
            ydl.format_selector = ydl.build_format_selector(fid)
            result = ydl.process_ie_result(copy.deepcopy(raw), download=True)
            # Processing fills in fields the raw result lacks, e.g. a placeholder
            # title for untitled TikToks
            processed.update(
                title=result.get('title'), id=result.get('id'),
                artist=result.get('artist') or ', '.join(result.get('artists') or [])
                or result.get('uploader') or result.get('channel'),
                date=(result.get('release_date') or result.get('upload_date') or '')[:4],
                url=result.get('webpage_url'))
            if len(files) == before:
                # Already-downloaded files don't fire a "finished" hook
                path = (result.get('requested_downloads') or [{}])[0].get('filepath')
                if path and os.path.exists(path):
                    files.append(path)
                else:
                    raise RuntimeError(logger.lines[-1] if logger.lines else f'Format {fid} failed to download')
        return raw

    processed = {}

    def remove_files():
        for f in files:
            try:
                os.remove(f)
            except OSError:
                pass
        files.clear()

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            for attempt in range(2):
                try:
                    raw = run(ydl)
                    break
                except yt_dlp.utils.DownloadError as e:
                    # YouTube intermittently rejects stream URLs; fresh ones usually work.
                    if attempt or job['cancel'] or 'HTTP Error 403' not in str(e):
                        raise
                    logger.warning('Got HTTP 403, retrying with fresh URLs')
                    remove_files()
            job['status'] = 'finished'
            return _ok(files=files, title=processed.get('title') or raw.get('title'),
                       id=processed.get('id') or raw.get('id'), artist=processed.get('artist'),
                       date=processed.get('date'), url=processed.get('url'))
    except Exception as e:
        if isinstance(e, Cancelled) or job['cancel']:
            job['status'] = 'cancelled'
            remove_files()
            return json.dumps({'ok': False, 'cancelled': True, 'error': 'Cancelled'})
        job['status'] = 'error'
        return _err(e, logger)
    finally:
        with _jobs_lock:
            _jobs.pop(job_id, None)


def progress(arg: str) -> str:
    job = _jobs.get(json.loads(arg)['job_id'])
    if job is None:
        return _ok(status='unknown')
    return _ok(**{k: v for k, v in job.items() if k != 'cancel'})


def cancel(arg: str) -> str:
    job = _jobs.get(json.loads(arg)['job_id'])
    if job is not None:
        job['cancel'] = True
    return _ok()
