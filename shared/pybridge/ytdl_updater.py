"""Over-the-air yt-dlp updates.

yt-dlp is pure Python, so a newer release can be downloaded from PyPI into
the app's writable storage and imported instead of the bundled copy. iOS code
signing only covers native code, so no rebuild is needed.

Layout of the update directory (``$YTDL_UPDATE_DIR``):
    current/   installed update: yt_dlp/, yt_dlp_ejs/, update.json
    staging/   an install in progress
    broken/    an update that failed to import (kept for debugging)

An update takes effect on the next launch: CPython can't cleanly unload an
already-imported package. If it fails to import, the bundled yt-dlp is used
and the update is moved to broken/.
"""
from __future__ import annotations

import compileall
import hashlib
import io
import json
import os
import py_compile
import re
import shutil
import ssl
import sys
import urllib.request
import zipfile

UPDATE_DIR = os.environ.get('YTDL_UPDATE_DIR')
_PYPI = 'https://pypi.org/pypi'
_MODULE_PREFIXES = ('yt_dlp', 'yt_dlp_ejs', 'jsc_provider')

load_state = {'source': 'bundled', 'error': None}


def _path(name):
    return os.path.join(UPDATE_DIR, name) if UPDATE_DIR else None


def _purge_modules():
    for name in list(sys.modules):
        if name.split('.')[0] in _MODULE_PREFIXES:
            del sys.modules[name]


def load_ytdlp():
    """Import yt-dlp (preferring an installed update) and register the JSC provider."""
    current = _path('current')
    if current and os.path.isdir(current):
        sys.path.insert(0, current)
        try:
            import yt_dlp  # noqa: F401
            import jsc_provider  # noqa: F401
            load_state['source'] = 'update'
            return
        except Exception as e:
            load_state['error'] = f'{type(e).__name__}: {e}'
            sys.path.remove(current)
            _purge_modules()
            broken = _path('broken')
            shutil.rmtree(broken, ignore_errors=True)
            try:
                os.rename(current, broken)
            except OSError:
                shutil.rmtree(current, ignore_errors=True)

    import yt_dlp  # noqa: F401
    import jsc_provider  # noqa: F401


def version_tuple(version):
    """'2026.08.19' and '2026.9.21.232924.dev0' -> comparable int tuples."""
    return tuple(int(p) for p in version.split('.') if p.isdigit())


def bundled_version():
    """Version of the yt-dlp shipped inside the app (not an update)."""
    current = _path('current')
    for entry in sys.path:
        if current and os.path.abspath(entry) == os.path.abspath(current):
            continue
        try:
            with open(os.path.join(entry, 'yt_dlp', 'version.py'), encoding='utf-8') as f:
                match = re.search(r"^__version__\s*=\s*'([^']+)'", f.read(), re.M)
                return match and match.group(1)
        except OSError:
            continue
    return None


# region: PyPI

def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


def _fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'yt-dlp-ios-updater'})
    with urllib.request.urlopen(request, timeout=60, context=_ssl_context()) as response:
        return response.read()


def _release_json(project, version=None):
    url = f'{_PYPI}/{project}/{version}/json' if version else f'{_PYPI}/{project}/json'
    return json.loads(_fetch(url))


def latest_version(nightly=False):
    data = _release_json('yt-dlp')
    if not nightly:
        return data['info']['version']
    # Nightly builds are published to PyPI as .devN pre-releases.
    candidates = [
        v for v, files in data['releases'].items()
        if files and not all(f.get('yanked') for f in files)]
    return max(candidates, key=version_tuple)


def _wheel(release):
    for f in release['urls']:
        if f['packagetype'] == 'bdist_wheel' and not f.get('yanked'):
            return f['url'], f['digests']['sha256']
    raise RuntimeError(f'No wheel published for {release["info"]["name"]} {release["info"]["version"]}')


def _download_verified(release):
    url, sha256 = _wheel(release)
    data = _fetch(url)
    if hashlib.sha256(data).hexdigest() != sha256:
        raise RuntimeError(f'Checksum mismatch for {url}')
    return data


def _required_ejs(release):
    for req in release['info'].get('requires_dist') or []:
        match = re.match(r'yt-dlp-ejs\s*==\s*([\w.]+)', req)
        if match:
            return match.group(1)
    return None

# endregion


def install(version, progress=lambda message: None):
    """Download, verify and stage yt-dlp ``version`` (+ its yt-dlp-ejs) as current/."""
    if not UPDATE_DIR:
        raise RuntimeError('Updates are not configured')
    os.makedirs(UPDATE_DIR, exist_ok=True)
    staging = _path('staging')
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging)

    progress(f'Downloading yt-dlp {version}')
    release = _release_json('yt-dlp', version)
    wheels = [_download_verified(release)]
    ejs_version = _required_ejs(release)
    if ejs_version:
        progress(f'Downloading yt-dlp-ejs {ejs_version}')
        wheels.append(_download_verified(_release_json('yt-dlp-ejs', ejs_version)))

    progress('Installing')
    for data in wheels:
        with zipfile.ZipFile(io.BytesIO(data)) as wheel:
            for member in wheel.namelist():
                top = member.split('/')[0]
                # Package code only: skip *.data (man pages, shell completions)
                if top.endswith('.data') or member.startswith(('/', '..')) or '/../' in member:
                    continue
                wheel.extract(member, staging)

    progress('Compiling')
    compileall.compile_dir(
        staging, quiet=1, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)

    with open(os.path.join(staging, 'update.json'), 'w') as f:
        json.dump({'yt_dlp': version, 'yt_dlp_ejs': ejs_version}, f)

    current, old = _path('current'), _path('old')
    shutil.rmtree(old, ignore_errors=True)
    if os.path.isdir(current):
        os.rename(current, old)
    os.rename(staging, current)
    shutil.rmtree(old, ignore_errors=True)


def installed_update_version():
    try:
        with open(os.path.join(_path('current'), 'update.json')) as f:
            return json.load(f)['yt_dlp']
    except (OSError, TypeError, ValueError, KeyError):
        return None


def remove():
    for name in ('current', 'staging', 'broken'):
        path = _path(name)
        if path:
            shutil.rmtree(path, ignore_errors=True)
