"""Finishes desktop downloads with the same Remux.c the mobile apps use.

Remux.c is built together with a minimal, LGPL-only FFmpeg into one shared
library (desktop/scripts/build_remux.sh) and called here through ctypes. It
merges yt-dlp's separate video and audio parts, or rewraps a single file into a
clean container, without re-encoding.
"""
from __future__ import annotations

import ctypes
import os
import shutil
import sys

_RUNTIME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_LIBRARY = {'darwin': 'libsquirrelremux.dylib', 'win32': 'squirrelremux.dll'}.get(sys.platform, 'libsquirrelremux.so')

# FFmpeg muxer for each output extension (matches the iOS and Android Remuxer)
MUXERS = {
    'mp4': 'mp4', 'm4a': 'ipod', 'mov': 'mov', 'mkv': 'matroska', 'webm': 'webm',
    'mp3': 'mp3', 'ogg': 'ogg', 'opus': 'ogg', 'flac': 'flac',
}

_lib = None


def _load():
    global _lib
    if _lib is None:
        path = os.environ.get('SQUIRREL_REMUX_LIB') or os.path.join(_RUNTIME, 'remux', _LIBRARY)
        lib = ctypes.CDLL(path)
        lib.ytdl_remux.argtypes = [
            ctypes.POINTER(ctypes.c_char_p), ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p,
            ctypes.POINTER(ctypes.c_char_p), ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t]
        lib.ytdl_remux.restype = ctypes.c_int
        _lib = lib
    return _lib


def remux(inputs, output, metadata=None):
    """Merge/rewrap ``inputs`` into ``output``; the extension picks the container."""
    muxer = MUXERS.get(os.path.splitext(output)[1][1:].lower())
    if not muxer:
        raise RuntimeError(f"Can't write {os.path.splitext(output)[1]} files")
    lib = _load()
    paths = (ctypes.c_char_p * len(inputs))(*(os.fsencode(p) if sys.platform != 'win32' else p.encode() for p in inputs))
    tags = [x.encode() for k, v in (metadata or {}).items() if v for x in (k, v)]
    tag_array = (ctypes.c_char_p * max(len(tags), 1))(*tags)
    error = ctypes.create_string_buffer(512)
    status = lib.ytdl_remux(paths, len(inputs), output.encode(), muxer.encode(),
                            tag_array, len(tags) // 2, error, len(error))
    if status != 0:
        raise RuntimeError(f"Couldn't finish the file: {error.value.decode(errors='replace')}")


def finish(files, out_dir, title, ext=None, audio=False, metadata=None):
    """Turn yt-dlp's downloaded parts into one file in ``out_dir``; returns its path."""
    if not files:
        raise RuntimeError('yt-dlp finished without producing a file')
    os.makedirs(out_dir, exist_ok=True)
    container = ext if ext and ext.lower() in MUXERS else ('m4a' if audio else 'mp4')
    destination = unique_path(out_dir, title, container)
    try:
        remux(files, destination, metadata)
    except Exception:
        if len(files) != 1:
            raise
        # A format FFmpeg can't rewrap: keep the file exactly as downloaded
        destination = unique_path(out_dir, title, file_extension(files[0], audio))
        shutil.move(files[0], destination)
    return destination


def file_extension(path, audio):
    """What a single downloaded file really contains (ported from the iOS app)."""
    ext = os.path.splitext(path)[1][1:].lower()
    try:
        with open(path, 'rb') as f:
            head = f.read(189)
    except OSError:
        return ext
    if len(head) == 189 and head[0] == 0x47 and head[188] == 0x47:
        return 'ts'  # HLS with MPEG-TS segments, even when named .mp4
    if len(head) >= 2 and head[0] == 0xFF and head[1] & 0xF6 == 0xF0:
        return 'aac'  # raw ADTS audio
    if audio and ext == 'mp4':
        return 'm4a'
    return ext


_ILLEGAL = set('/\\:?%*|"<>')


def unique_path(folder, title, ext):
    base = ''.join(' ' if c in _ILLEGAL or ord(c) < 32 else c for c in title).strip(' .')
    base = base[:120] or 'Download'
    path = os.path.join(folder, f'{base}.{ext}')
    counter = 2
    while os.path.exists(path):
        path = os.path.join(folder, f'{base} ({counter}).{ext}')
        counter += 1
    return path


def remove_tree(path):
    shutil.rmtree(path, ignore_errors=True)
