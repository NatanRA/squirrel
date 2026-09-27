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
import time
import traceback
import urllib.parse

import ytdl_updater

# Prefers an over-the-air update; also registers the JavaScriptCore provider.
ytdl_updater.load_ytdlp()

import yt_dlp  # noqa: E402


_config = {'cache_dir': None, 'cookie_file': None, 'av1_decode': False, 'vp9_decode': False}
_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()
# Cancels that arrived before their download started: job id -> when
_early_cancels: dict[str, float] = {}
_EARLY_CANCEL_SECONDS = 30  # a later retry may reuse the id


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
        # The same audio re-encoded by the app (Remux.c), for players that only take MP3
        if container != 'mp3':
            audio.append({'id': 'mp3', 'label': 'MP3', 'kind': 'audio', 'height': 0, 'ext': 'mp3', 'convert': 'mp3',
                          'format_ids': [best_audio['format_id']], 'playable': True,
                          'detail': 'MP3 · about 190 kbps · converted'})

    if not video and not audio and formats:
        # No usable format metadata (common for generic extractors): let yt-dlp pick
        video = [{'id': 'best', 'label': 'Best', 'detail': 'Best single file', 'format_ids': ['best'],
                  'kind': 'video', 'height': 0, 'ext': 'mp4', 'playable': True}]

    return video + audio


def _resolve_target(choices, target):
    """The preset a playlist item's quality ("Best", "up to 720p", "Audio", "MP3") means for this video."""
    if target.get('kind') == 'audio':
        # MP3 when asked for; a video whose audio already is MP3 has no separate MP3 choice
        wanted = 'mp3' if target.get('convert') == 'mp3' else 'audio'
        audio = (next((c for c in choices if c['id'] == wanted), None)
                 or next((c for c in choices if c['kind'] == 'audio'), None))
        if audio:
            return audio
    videos = [c for c in choices if c['kind'] == 'video']  # highest first
    if not videos:
        raise ValueError('No downloadable formats found')
    if target.get('kind') == 'audio':
        return videos[-1]  # no audio-only stream: the smallest video still has the sound
    cap = target.get('max_height')
    pool = [c for c in videos if not cap or c['height'] <= cap] or videos[-1:]
    # Rather 1080p that plays everywhere than 4K that only VLC opens
    return next((c for c in pool if c['playable']), pool[0])

# endregion


# region: subtitles

# Old codes some sites (YouTube) still use, and the ones devices report
_LANGUAGE_ALIASES = {'iw': 'he', 'in': 'id', 'ji': 'yi', 'jw': 'jv'}


def _language(key):
    """'en' for subtitle keys like 'en', 'en-GB' and 'en-orig' ('he' for YouTube's 'iw')."""
    language = key.split('-')[0].lower()
    return _LANGUAGE_ALIASES.get(language, language)


def _subtitle_summary(info):
    """The languages a video has subtitles in, and automatic captions (in its own language only)."""
    manual = [k for k in info.get('subtitles') or {} if k != 'live_chat']
    automatic = [k for k in info.get('automatic_captions') or {} if k.endswith('-orig')]
    return {'languages': list(dict.fromkeys(map(_language, manual))),
            'auto': list(dict.fromkeys(map(_language, automatic)))}


def _subtitle_tracks(info, languages, auto):
    """Subtitle keys to embed: per wanted language, subtitles people wrote, else (with ``auto``)
    the site's automatic captions in the video's own language, never machine translations."""
    manual = [k for k in info.get('subtitles') or {} if k != 'live_chat']
    automatic = [k for k in info.get('automatic_captions') or {} if k.endswith('-orig')]
    picked = []
    for language in dict.fromkeys(_language(lang) for lang in languages):
        key = next((k for k in manual if _language(k) == language), None)
        if not key and auto:
            key = next((k for k in automatic if _language(k) == language), None)
        if key:
            picked.append(key)
    return picked


def _write_subtitles(ydl, raw, keys, logger):
    """Downloads the subtitles ``keys`` next to the video; returns them for Remux.c to embed.
    Subtitles are a bonus: any failure only drops them."""
    params = ydl.params
    saved = {k: params.get(k) for k in ('skip_download', 'writesubtitles', 'writeautomaticsub',
                                         'subtitleslangs', 'subtitlesformat')}
    params.update(skip_download=True, writesubtitles=True, writeautomaticsub=True,
                  subtitleslangs=[re.escape(k) for k in keys],  # yt-dlp reads these as patterns
                  subtitlesformat='vtt/srt/best')
    try:
        ydl.format_selector = None
        result = ydl.process_ie_result(copy.deepcopy(raw), download=True)
    except Exception as e:
        logger.warning(f'Subtitles skipped: {e}')
        return []
    finally:
        params.update(saved)
    tracks = []
    for key in keys:
        sub = (result.get('requested_subtitles') or {}).get(key) or {}
        path = sub.get('filepath')
        if not path or not os.path.exists(path):
            continue
        name = sub.get('name') or key
        if key.endswith('-orig'):
            name = name.removesuffix(' (Original)') + ' (auto-generated)'
        tracks.append({'path': path, 'name': name,
                       'lang': yt_dlp.utils.ISO639Utils.short2long(_language(key)) or 'und'})
    return tracks

# endregion


# region: playlists

PLAYLIST_CAP = 500
_SECTION_NAMES = {'videos': 'Videos', 'shorts': 'Shorts', 'streams': 'Live', 'live': 'Live',
                  'podcasts': 'Podcasts', 'releases': 'Releases', 'playlists': 'Playlists'}
_UNAVAILABLE = ('private', 'premium_only', 'subscriber_only', 'needs_auth')
_YOUTUBE_HOSTS = ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be')


def _key(info):
    """Identifies a video across links, like yt-dlp's download archive ("youtube dQw4w9WgXcQ")."""
    ie, video_id = info.get('ie_key') or info.get('extractor_key'), info.get('id')
    return yt_dlp.utils.make_archive_id(ie, video_id) if ie and video_id else None


def _playlist_hint(url):
    """The playlist a YouTube video link also names (watch?v=…&list=…), for "Whole playlist"."""
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or '').lower()
    if host not in _YOUTUBE_HOSTS or parsed.path.startswith('/playlist'):
        return None
    playlist_id = urllib.parse.parse_qs(parsed.query).get('list', [None])[0]
    # Mixes ("RD…") are generated endlessly from the current video
    if not playlist_id or playlist_id.startswith('RD'):
        return None
    base = 'https://music.youtube.com' if host == 'music.youtube.com' else 'https://www.youtube.com'
    return f'{base}/playlist?list={urllib.parse.quote(playlist_id)}'


def _thumbnail(entry):
    if entry.get('thumbnail'):
        return entry['thumbnail']
    thumbs = [t for t in entry.get('thumbnails') or [] if t.get('url')]
    if not thumbs:
        return None
    # A list row needs a small one: closest to 320 px wide when sizes are known
    sized = [t for t in thumbs if t.get('width')]
    return min(sized, key=lambda t: abs(t['width'] - 320))['url'] if sized else thumbs[-1]['url']


def _section_name(playlist):
    """"Videos", "Shorts" or "Live" for the tabs yt-dlp returns for a whole YouTube channel."""
    path = urllib.parse.urlparse(playlist.get('webpage_url') or '').path.rstrip('/')
    name = _SECTION_NAMES.get(path.rsplit('/', 1)[-1])
    if name:
        return name
    title = playlist.get('title') or ''
    return title.rsplit(' - ', 1)[-1] or None


def _indexed_entries(playlist):
    """(index within the playlist, entry) pairs; yt-dlp only lists indexes when some are missing."""
    entries = playlist.get('entries') or []
    indexes = playlist.get('requested_entries') or range(1, len(entries) + 1)
    return list(zip(indexes, entries))


def _entry_payload(entry, position, group, section):
    flat = entry.get('_type') in ('url', 'url_transparent')
    url = entry.get('url') if flat else (entry.get('webpage_url') or entry.get('original_url'))
    container = group.get('webpage_url') or group.get('original_url')
    # Posts with several videos (e.g. on X) share one link: those are picked by index instead
    own = isinstance(url, str) and '://' in url and url != container  # not a bare id
    title = entry.get('title')
    return {
        'index': position,
        'key': _key(entry),
        'title': title or f'Item {position}',
        'uploader': entry.get('uploader') or entry.get('channel'),
        'duration': entry.get('duration'),
        'thumbnail': _thumbnail(entry),
        'url': url if own else container,
        'pick': None if own else entry.get('playlist_index') or position,
        'section': section,
        'unavailable': entry.get('availability') in _UNAVAILABLE
                       or title in ('[Private video]', '[Deleted video]'),
        'live': entry.get('live_status') in ('is_live', 'is_upcoming') or bool(entry.get('is_live')),
    }


def _playlist_payload(info, url):
    """Every item of a (flat-extracted) playlist, channel or multi-video post, for the picker."""
    # A whole channel comes back as one playlist per tab (Videos, Shorts, Live): each is a section
    groups, loose = [], []
    for index, entry in _indexed_entries(info):
        if entry and entry.get('_type') in ('playlist', 'multi_video'):
            groups.append((_section_name(entry), entry, [(i, e) for i, e in _indexed_entries(entry) if e]))
        elif entry:
            loose.append((index, entry))
    if loose or not groups:
        groups.insert(0, (None, info, loose))

    entries, truncated, count = [], False, 0
    for section, group, items in groups:
        room = PLAYLIST_CAP - len(entries)
        if len(items) > room:
            truncated, items = True, items[:room]
            # How many there are in all, if the site says (YouTube playlists do, channel tabs don't)
            if count is not None and group.get('playlist_count'):
                count += group['playlist_count']
            else:
                count = None
        elif count is not None:
            count += max(group.get('playlist_count') or 0, len(items))
        for index, entry in items:
            entry = {**entry, 'playlist_index': index}
            entries.append(_entry_payload(entry, len(entries) + 1, group, section))

    is_post = info.get('_type') == 'multi_video'
    return {
        'type': 'playlist',
        'kind': info.get('_type'),
        'id': info.get('id'),
        'title': info.get('title') or info.get('id') or 'Playlist',
        'uploader': info.get('uploader') or info.get('channel'),
        'webpage_url': info.get('webpage_url') or url,
        'extractor': info.get('extractor_key'),
        'count': count,
        'truncated': truncated,
        # Videos of one post stay with the other downloads; a playlist gets its own folder
        'folder': None if is_post else info.get('title'),
        'sections': list(dict.fromkeys(e['section'] for e in entries if e['section'])),  # ones with items
        'music': (urllib.parse.urlparse(url).hostname or '').lower() == 'music.youtube.com',
        'entries': entries,
    }

# endregion


def _video_payload(info, url):
    return dict(
        type='video',
        id=info.get('id'),
        key=_key(info),
        title=info.get('title'),
        uploader=info.get('uploader') or info.get('channel'),
        duration=info.get('duration'),
        thumbnail=info.get('thumbnail'),
        webpage_url=info.get('webpage_url') or url,
        extractor=info.get('extractor_key'),
        playlist_url=_playlist_hint(url),
        subtitles=_subtitle_summary(info),
        choices=_presets(info),
    )


def extract(arg: str) -> str:
    """Video details and download choices; with ``playlists``, a playlist's items instead.

    Playlist replies are opt-in so an older browser extension (which expects
    ``choices``) keeps working against a newer engine.
    """
    params = json.loads(arg)
    url = params['url']
    playlists = bool(params.get('playlists'))
    logger = _Logger()
    opts = _base_opts(logger)
    if playlists:
        opts.update(extract_flat='in_playlist', playlistend=PLAYLIST_CAP + 1)
    else:
        opts['playlist_items'] = '1'  # only the first item is used; don't process the rest
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if playlists and info.get('_type') in ('playlist', 'multi_video'):
                payload = _playlist_payload(info, url)
                if not payload['entries']:
                    raise ValueError('Playlist is empty')
                if len(payload['entries']) > 1:
                    return _ok(**payload)
            while info.get('_type') in ('playlist', 'multi_video'):
                entries = [e for e in info.get('entries') or [] if e]
                if not entries:
                    raise ValueError('Playlist is empty')
                info = entries[0]
            if info.get('_type') in ('url', 'url_transparent'):
                # A flat-extracted single item
                info = ydl.extract_info(info['url'], download=False, ie_key=info.get('ie_key'))
            return _ok(**_video_payload(info, url))
    except Exception as e:
        return _err(e, logger)


def download(arg: str) -> str:
    """Blocking. Call from a background thread; poll ``progress`` meanwhile.

    params: url, out_dir, job_id, and either ``format_ids`` (a choice from
    ``extract``) or ``target`` ({kind: video|audio, max_height}) for playlist
    items, whose formats aren't known until they're extracted. ``playlist_index``
    picks one item of a link that holds several (e.g. a post with 4 videos).
    ``subtitles`` ({languages, auto}, for videos) also fetches subtitles to embed;
    the result lists them for Remux.c.
    """
    params = json.loads(arg)
    job_id = params['job_id']
    target = params.get('target')
    job = {'status': 'starting', 'downloaded': 0, 'total': 0, 'speed': 0, 'eta': None,
           'part': 0, 'parts': len(params.get('format_ids') or []) or 1, 'cancel': False, 'log': ''}
    with _jobs_lock:
        _jobs[job_id] = job
        cancelled_at = _early_cancels.pop(job_id, None)
    if cancelled_at is not None and time.monotonic() - cancelled_at < _EARLY_CANCEL_SECONDS:
        with _jobs_lock:
            _jobs.pop(job_id, None)
        return json.dumps({'ok': False, 'cancelled': True, 'error': 'Cancelled'})
    logger = _Logger(job)
    out_dir = params['out_dir']
    os.makedirs(out_dir, exist_ok=True)

    files = []

    def hook(d):
        if job['cancel']:
            raise Cancelled('Cancelled')
        if job['status'] == 'subtitles':
            return  # subtitle files aren't parts of the video, and are too small to show progress for
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
            index = params.get('playlist_index')
            if index:
                raw = next((e for _, e in yt_dlp.utils.PlaylistEntries(ydl, raw)[int(index)]), None)
                if not raw:
                    raise ValueError(f'Item {index} is no longer in this playlist')
            else:
                raw = next(e for e in raw['entries'] if e)
            if raw.get('_type') in ('url', 'url_transparent'):
                raw = ydl.extract_info(raw['url'], download=False, process=False, ie_key=raw.get('ie_key'))
        if raw.get('_type') in ('playlist', 'multi_video'):
            # Downloading it would save every video as "parts" of one file
            raise ValueError('This link is a playlist. Paste it in Squirrel to choose its videos.')
        format_ids = params.get('format_ids') or []
        if target:
            ydl.format_selector = None  # yt-dlp's default, just to list the formats
            info = ydl.process_ie_result(copy.deepcopy(raw), download=False)
            chosen.update(_resolve_target(_presets(info), target))
            format_ids = chosen['format_ids']
        job['parts'] = len(format_ids)
        for i, fid in enumerate(format_ids):
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
        wanted = params.get('subtitles')
        if wanted and chosen.get('kind', 'video') == 'video' and not job['cancel']:
            keys = _subtitle_tracks(raw, wanted.get('languages') or [], wanted.get('auto'))
            if keys:
                job['status'] = 'subtitles'
                subtitles[:] = _write_subtitles(ydl, raw, keys, logger)
        return raw

    processed = {}
    chosen = {}  # the preset a target resolved to
    subtitles = []

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
                       id=processed.get('id') or raw.get('id'), key=_key(raw), artist=processed.get('artist'),
                       date=processed.get('date'), url=processed.get('url'), choice=chosen or None,
                       subtitles=subtitles)
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
    job_id = json.loads(arg)['job_id']
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is not None:
            job['cancel'] = True
        else:
            # The app may cancel just before its download call gets here
            _early_cancels[job_id] = time.monotonic()
    return _ok()
