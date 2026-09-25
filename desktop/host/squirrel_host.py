"""Squirrel's desktop engine: the shared yt-dlp bridge in its own Python process.

The Mac and Windows apps start it with ``--stdio`` and exchange one JSON object
per line. The browser extension reaches the same code through native messaging
(``--native-messaging``, or the extension origin Chrome passes as the first
argument), where each message is a 4-byte length followed by JSON.

Requests look like ``{"id": 1, "cmd": "extract", "args": {...}}`` and every
reply echoes the id: ``{"id": 1, "ok": true, ...}``. Each request runs on its
own thread, so ``progress`` and ``cancel`` are answered while a ``download``
is still running, just as the mobile apps poll the bridge.

Unlike the mobile apps, the host also finishes each download itself: it merges
the parts with Remux.c (see remux.py) and saves the file to the download folder
in ``settings.json``, which the desktop app writes and the extension shares.
"""
from __future__ import annotations

import json
import os
import struct
import sys
import threading
import traceback
import uuid

APP_NAME = 'Squirrel'
RUNTIME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _data_dir():
    if sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Application Support')
    elif sys.platform == 'win32':
        base = os.environ.get('APPDATA') or os.path.expanduser('~/AppData/Roaming')
    else:
        base = os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share')
    return os.path.join(base, APP_NAME)


def _cache_dir():
    if sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Caches')
    elif sys.platform == 'win32':
        base = os.environ.get('LOCALAPPDATA') or os.path.expanduser('~/AppData/Local')
    else:
        base = os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache')
    return os.path.join(base, APP_NAME)


DATA_DIR = os.environ.get('SQUIRREL_DATA_DIR') or _data_dir()
CACHE_DIR = os.environ.get('SQUIRREL_CACHE_DIR') or _cache_dir()
SETTINGS_FILE = os.path.join(DATA_DIR, 'settings.json')

# Runtime layout (see desktop/scripts/build_runtime.sh): app/ holds this file and
# the shared bridge, lib/ the pip packages. Must be set before the bridge loads.
sys.path[:0] = [os.path.join(RUNTIME, 'app'), os.path.join(RUNTIME, 'lib')]
os.environ.setdefault('YTDL_UPDATE_DIR', os.path.join(DATA_DIR, 'python-updates'))
# yt-dlp recurses deeply; the default thread stack (512 KB on macOS) is too small
threading.stack_size(16 << 20)

import remux  # noqa: E402
import ytdl_bridge  # noqa: E402


def default_download_dir():
    return os.path.join(os.path.expanduser('~'), 'Downloads', APP_NAME)


def load_settings():
    try:
        with open(SETTINGS_FILE, encoding='utf-8') as f:
            settings = json.load(f)
    except (OSError, ValueError):
        settings = {}
    settings.setdefault('download_dir', default_download_dir())
    return settings


def _deno_path():
    name = 'deno.exe' if sys.platform == 'win32' else 'deno'
    for folder in (os.path.join(RUNTIME, 'lib', 'bin'), os.path.join(RUNTIME, 'bin')):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            return path
    try:
        import deno
        return deno.find_deno_bin()
    except Exception:
        return None


def _configure():
    """Point the bridge at this machine's folders and the current settings."""
    settings = load_settings()
    config = {
        'cache_dir': os.path.join(CACHE_DIR, 'yt-dlp'),
        'cookies_from_browser': settings.get('cookies_from_browser') or None,
        # Written by the desktop app, which can ask the OS what it plays
        'av1_decode': bool(settings.get('av1_decode')),
        'vp9_decode': bool(settings.get('vp9_decode')),
        'verbose': bool(os.environ.get('SQUIRREL_VERBOSE')),
    }
    if not _has_js_host():
        deno = _deno_path()
        if deno:
            config['js_runtimes'] = {'deno': {'path': deno}}
    return json.loads(ytdl_bridge.configure(json.dumps(config)))


def _has_js_host():
    try:
        import _host  # noqa: F401
        return True
    except ImportError:
        return False


# region: commands

_phases: dict[str, str] = {}  # job id -> "merging" once yt-dlp is done
_early_cancels: set[str] = set()  # cancelled before yt-dlp registered the job


def cmd_start(args):
    result = _configure()
    result.update(download_dir=load_settings()['download_dir'], data_dir=DATA_DIR)
    return result


def cmd_extract(args):
    _configure()
    return json.loads(ytdl_bridge.extract(json.dumps({'url': args['url']})))


def cmd_download(args):
    """Download, merge and save one choice; returns the saved file's path.

    args: url, format_ids, ext (from the chosen preset), audio, title, job_id (optional)
    """
    _configure()
    job_id = args.get('job_id') or uuid.uuid4().hex
    out_dir = args.get('out_dir') or load_settings()['download_dir']
    work = os.path.join(CACHE_DIR, 'work', job_id)
    try:
        if job_id in _early_cancels:
            _early_cancels.discard(job_id)
            return {'ok': False, 'cancelled': True, 'error': 'Cancelled'}
        result = json.loads(ytdl_bridge.download(json.dumps({
            'url': args['url'], 'format_ids': args['format_ids'], 'out_dir': work, 'job_id': job_id})))
        if not result.get('ok'):
            return result
        _phases[job_id] = 'merging'
        title = result.get('title') or args.get('title') or 'Download'
        path = remux.finish(
            [f for f in result.get('files') or [] if f], out_dir, title,
            ext=args.get('ext'), audio=bool(args.get('audio')),
            metadata={'title': title, 'artist': result.get('artist') or '', 'date': result.get('date') or '',
                      'comment': result.get('url') or args['url']})
        return {'ok': True, 'path': path, 'title': title, 'job_id': job_id}
    except Exception as e:
        return {'ok': False, 'error': str(e) or type(e).__name__, 'traceback': traceback.format_exc()}
    finally:
        _phases.pop(job_id, None)
        _early_cancels.discard(job_id)  # a retry may reuse the id
        remux.remove_tree(work)


def cmd_progress(args):
    result = json.loads(ytdl_bridge.progress(json.dumps({'job_id': args['job_id']})))
    phase = _phases.get(args['job_id'])
    if phase and result.get('status') == 'unknown':
        result['status'] = phase
    return result


def cmd_cancel(args):
    if cmd_progress(args).get('status') == 'unknown':
        _early_cancels.add(args['job_id'])  # the download hasn't reached yt-dlp yet
    return json.loads(ytdl_bridge.cancel(json.dumps({'job_id': args['job_id']})))


def cmd_update_status(args):
    return json.loads(ytdl_bridge.update_status('{}'))


def cmd_check_update(args):
    return json.loads(ytdl_bridge.check_update(json.dumps({'nightly': bool(args.get('nightly'))})))


def cmd_install_update(args):
    return json.loads(ytdl_bridge.install_update(json.dumps({'version': args['version']})))


def cmd_remove_update(args):
    return json.loads(ytdl_bridge.remove_update('{}'))


def cmd_settings(args):
    """The extension shows where files will go."""
    settings = load_settings()
    return {'ok': True, 'download_dir': settings['download_dir']}


COMMANDS = {name[4:]: fn for name, fn in globals().items() if name.startswith('cmd_')}

# endregion


# region: transports

class _Transport:
    def __init__(self):
        self.lock = threading.Lock()

    def serve(self):
        while (message := self.read()) is not None:
            threading.Thread(target=self.handle, args=(message,), daemon=True).start()

    def handle(self, message):
        request_id = message.get('id') if isinstance(message, dict) else None
        try:
            command = COMMANDS.get(message.get('cmd'))
            if command is None:
                reply = {'ok': False, 'error': f'Unknown command {message.get("cmd")!r}'}
            else:
                reply = command(message.get('args') or {})
        except Exception as e:
            reply = {'ok': False, 'error': str(e) or type(e).__name__, 'traceback': traceback.format_exc()}
        reply = {**reply, 'id': request_id}
        with self.lock:
            self.write(reply)


class Stdio(_Transport):
    """One JSON object per line; used by the desktop apps."""

    def __init__(self):
        super().__init__()
        self.input = sys.stdin.buffer
        self.output = sys.stdout.buffer
        # Stray prints from libraries must not corrupt the protocol
        sys.stdout = sys.stderr

    def read(self):
        while line := self.input.readline():
            if line.strip():
                return json.loads(line)
        return None

    def write(self, message):
        self.output.write(json.dumps(message).encode() + b'\n')
        self.output.flush()


class NativeMessaging(_Transport):
    """Chrome/Firefox native messaging: little-endian uint32 length + UTF-8 JSON."""

    def __init__(self):
        super().__init__()
        self.input = sys.stdin.buffer
        self.output = sys.stdout.buffer
        sys.stdout = sys.stderr
        if sys.platform == 'win32':
            import msvcrt
            msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
            msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)

    def read(self):
        header = self.input.read(4)
        if len(header) < 4:
            return None
        (length,) = struct.unpack('<I', header)
        return json.loads(self.input.read(length))

    def write(self, message):
        data = json.dumps(message).encode()
        self.output.write(struct.pack('<I', len(data)) + data)
        self.output.flush()

# endregion


def _remove_stale_work():
    """Parts left by a host that was quit mid-download (other hosts may be running)."""
    import time
    work = os.path.join(CACHE_DIR, 'work')
    try:
        for name in os.listdir(work):
            path = os.path.join(work, name)
            if time.time() - os.path.getmtime(path) > 24 * 3600:
                remux.remove_tree(path)
    except OSError:
        pass


def main(argv):
    # Chrome passes the extension's origin, Firefox the manifest path and add-on id
    native = '--native-messaging' in argv or any(
        a.startswith(('chrome-extension://', 'moz-extension://')) or a.endswith('.json') for a in argv)
    if not native and '--stdio' not in argv:
        print(__doc__)
        return 2
    transport = NativeMessaging() if native else Stdio()
    _remove_stale_work()
    transport.serve()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
