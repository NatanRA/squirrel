"""Bridge between the Swift app and yt-dlp.

Every public function takes a JSON string and returns a JSON string, so the
C layer only ever has to shuttle UTF-8 text back and forth.

iOS apps cannot spawn subprocesses, so neither ffmpeg nor an external JS
runtime (deno/node/...) is available. Instead:
  * YouTube's JS challenges are solved with the system JavaScriptCore, exposed
    to Python by the app as the built-in module ``_iosbridge``.
  * Separate video/audio streams are downloaded one at a time and merged by
    the app with AVFoundation.
"""
from __future__ import annotations

import copy
import json
import os
import shutil
import struct
import threading
import traceback

import ytdl_updater

# Prefers an over-the-air update; also registers the JavaScriptCore provider.
ytdl_updater.load_ytdlp()

import yt_dlp  # noqa: E402


_config = {'cache_dir': None, 'cookie_file': None}
_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()


class Cancelled(Exception):
    pass


class _Logger:
    def __init__(self, job=None):
        self.job = job
        self.lines = []

    def _add(self, msg):
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
        'js_runtimes': {'jsc': {}},
        'socket_timeout': 30,
        'retries': 5,
        'fragment_retries': 10,
        'concurrent_fragment_downloads': 4,
        'verbose': bool(_config.get('verbose')),
    }
    if _config['cache_dir']:
        opts['cachedir'] = _config['cache_dir']
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


def _err(e, logger=None):
    msg = str(e) or e.__class__.__name__
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

def _size(f):
    return f.get('filesize') or f.get('filesize_approx') or 0


def _is_avc(f):
    return (f.get('vcodec') or '').startswith(('avc1', 'h264'))


def _has_video(f):
    return f.get('vcodec') not in (None, 'none') or (f.get('height') and f.get('acodec') not in (None, 'none') and f.get('vcodec') is None)


def _has_audio(f):
    return f.get('acodec') not in (None, 'none')


def _quality(f):
    # Direct HTTPS beats HLS at equal resolution/fps: one request, known size
    return (f.get('height') or 0, f.get('fps') or 0, f.get('protocol') == 'https', f.get('tbr') or 0)


def _human(n):
    if not n:
        return None
    for unit in ('B', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return f'{n:.0f} {unit}' if unit in ('B', 'KB') else f'{n:.1f} {unit}'
        n /= 1024


def _presets(info):
    """Build a short list of download choices the app can handle without ffmpeg.

    AVFoundation can only mux H.264 video with AAC audio into MP4, so separate
    streams are limited to avc1 + m4a. Single-file formats of any codec are
    always offered as they need no merging.
    """
    formats = [f for f in (info.get('formats') or [info]) if f.get('url') or f.get('manifest_url')]
    # storyboards and other junk
    formats = [f for f in formats if f.get('ext') not in ('mhtml',) and f.get('protocol') != 'mhtml']

    audio_only = [f for f in formats if _has_audio(f) and f.get('vcodec') == 'none']
    m4a = sorted((f for f in audio_only if f.get('ext') in ('m4a', 'mp4')),
                 key=lambda f: (f.get('language_preference') or 0, f.get('abr') or f.get('tbr') or 0))
    best_m4a = m4a[-1] if m4a else None

    progressive = [f for f in formats if _has_audio(f) and f.get('vcodec') not in ('none',)]
    video_only = [f for f in formats if f.get('vcodec') not in (None, 'none') and f.get('acodec') == 'none']

    choices = {}

    def add(key, label, detail, ids, kind, height, ext):
        if key not in choices:
            choices[key] = {'id': key, 'label': label, 'detail': detail, 'format_ids': ids,
                            'kind': kind, 'height': height or 0, 'ext': ext}

    # Merged H.264 + AAC, per resolution
    if best_m4a:
        by_height = {}
        for f in video_only:
            if _is_avc(f) and f.get('ext') == 'mp4' and f.get('height'):
                cur = by_height.get(f['height'])
                if cur is None or _quality(f) > _quality(cur):
                    by_height[f['height']] = f
        for h, f in by_height.items():
            size = _size(f) and _size(f) + _size(best_m4a)
            fps = f' {int(f["fps"])}fps' if (f.get('fps') or 0) > 30 else ''
            detail = ' · '.join(filter(None, ['MP4', 'H.264', _human(size)]))
            add(f'v{h}', f'{h}p{fps}', detail, [f['format_id'], best_m4a['format_id']], 'video', h, 'mp4')

    # Single-file formats (already contain audio + video)
    for f in sorted(progressive, key=_quality, reverse=True):
        h = f.get('height') or 0
        key = f'v{h}' if h else f'p{f["format_id"]}'
        label = f'{h}p' if h else (f.get('format_note') or f.get('format_id'))
        codec = (f.get('vcodec') or '').split('.')[0].upper().replace('AVC1', 'H.264') or None
        detail = ' · '.join(filter(None, [(f.get('ext') or '').upper(), codec, _human(_size(f))]))
        add(key, label, detail, [f['format_id']], 'video', h, f.get('ext'))

    video = sorted(choices.values(), key=lambda c: c['height'], reverse=True)

    audio = []
    if best_m4a:
        abr = best_m4a.get('abr')
        detail = ' · '.join(filter(None, ['M4A', 'AAC', f'{abr:.0f} kbps' if abr else None, _human(_size(best_m4a))]))
        audio.append({'id': 'a-m4a', 'label': 'Audio', 'detail': detail,
                      'format_ids': [best_m4a['format_id']], 'kind': 'audio', 'height': 0, 'ext': 'm4a'})
    elif audio_only:
        f = max(audio_only, key=lambda f: f.get('abr') or f.get('tbr') or 0)
        detail = ' · '.join(filter(None, [(f.get('ext') or '').upper(), (f.get('acodec') or '').split('.')[0], _human(_size(f))]))
        audio.append({'id': 'a-best', 'label': 'Audio', 'detail': detail,
                      'format_ids': [f['format_id']], 'kind': 'audio', 'height': 0, 'ext': f.get('ext')})

    if not video and not audio and formats:
        # Unknown format metadata (common for generic extractors): let yt-dlp pick
        add('best', 'Best', 'Best single file', ['best'], 'video', 0, info.get('ext'))
        video = list(choices.values())

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


def _sidx_duration(path):
    """Exact duration of a DASH MP4 from its segment index (sidx) box, or None.

    YouTube's DASH files carry bogus header durations (roughly double) that
    AVFoundation trusts, so the app needs the real value to merge correctly.
    """
    try:
        with open(path, 'rb') as f:
            offset, end = 0, os.fstat(f.fileno()).st_size
            while offset + 8 <= end:
                f.seek(offset)
                size, kind = struct.unpack('>I4s', f.read(8))
                header = 8
                if size == 1:
                    size, header = struct.unpack('>Q', f.read(8))[0], 16
                elif size == 0:
                    size = end - offset
                if kind == b'sidx':
                    body = f.read(size - header)
                    version = body[0]
                    timescale = struct.unpack('>I', body[8:12])[0]
                    pos = 12 + (8 if version == 0 else 16) + 2
                    count = struct.unpack('>H', body[pos:pos + 2])[0]
                    pos += 2
                    total = sum(struct.unpack('>I', body[pos + 12 * i + 4:pos + 12 * i + 8])[0] for i in range(count))
                    return total / timescale if timescale else None
                if kind == b'moof' or size < 8:
                    return None  # the index, if any, precedes the first fragment
                offset += size
    except (OSError, struct.error, IndexError):
        pass
    return None


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
            if len(files) == before:
                # Already-downloaded files don't fire a "finished" hook
                path = (result.get('requested_downloads') or [{}])[0].get('filepath')
                if path and os.path.exists(path):
                    files.append(path)
                else:
                    raise RuntimeError(logger.lines[-1] if logger.lines else f'Format {fid} failed to download')
        return raw

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
            return _ok(files=files, durations=[_sidx_duration(f) for f in files],
                       title=raw.get('title'), id=raw.get('id'))
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
