"""Finishes desktop downloads with the same Remux.c the mobile apps use.

Remux.c is built together with a minimal, LGPL-only FFmpeg into one shared
library (desktop/scripts/build_remux.sh) and called here through ctypes. It
merges yt-dlp's separate video and audio parts, or rewraps a single file into a
clean container, without re-encoding, adding any subtitles as tracks. Audio can
also be converted to MP3.
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
        strings, text, size = ctypes.POINTER(ctypes.c_char_p), ctypes.c_char_p, ctypes.c_size_t
        lib.ytdl_remux_subtitled.argtypes = [
            strings, ctypes.c_int, strings, strings, strings, ctypes.c_int, text, text,
            strings, ctypes.c_int, text, size]
        lib.ytdl_remux_subtitled.restype = ctypes.c_int
        lib.ytdl_convert_to_mp3.argtypes = [text, text, strings, ctypes.c_int, text, size]
        lib.ytdl_convert_to_mp3.restype = ctypes.c_int
        _lib = lib
    return _lib


def _path(path):
    return os.fsencode(path) if sys.platform != 'win32' else path.encode()


def _strings(values):
    """A C array of UTF-8 strings (NULL for None)."""
    return (ctypes.c_char_p * max(len(values), 1))(*(v if v is None or isinstance(v, bytes) else v.encode() for v in values))


def _tags(metadata):
    tags = [x for k, v in (metadata or {}).items() if v for x in (k, v)]
    return _strings(tags), len(tags) // 2


def remux(inputs, output, metadata=None, subtitles=()):
    """Merge/rewrap ``inputs`` into ``output``; the extension picks the container.

    ``subtitles``: dicts with ``path``, and optionally ``lang`` (ISO 639-2) and ``name``.
    """
    muxer = MUXERS.get(os.path.splitext(output)[1][1:].lower())
    if not muxer:
        raise RuntimeError(f"Can't write {os.path.splitext(output)[1]} files")
    lib = _load()
    tags, tag_count = _tags(metadata)
    error = ctypes.create_string_buffer(512)
    status = lib.ytdl_remux_subtitled(
        _strings([_path(p) for p in inputs]), len(inputs),
        _strings([_path(s['path']) for s in subtitles]), _strings([s.get('lang') for s in subtitles]),
        _strings([s.get('name') for s in subtitles]), len(subtitles),
        _path(output), muxer.encode(), tags, tag_count, error, len(error))
    if status != 0:
        raise RuntimeError(f"Couldn't finish the file: {error.value.decode(errors='replace')}")


def convert_to_mp3(source, output, metadata=None):
    lib = _load()
    tags, tag_count = _tags(metadata)
    error = ctypes.create_string_buffer(512)
    status = lib.ytdl_convert_to_mp3(_path(source), _path(output), tags, tag_count, error, len(error))
    if status != 0:
        raise RuntimeError(f"Couldn't make the MP3: {error.value.decode(errors='replace')}")


def finish(files, out_dir, title, ext=None, audio=False, metadata=None, subtitles=(), convert=None):
    """Turn yt-dlp's downloaded parts into one file in ``out_dir``; returns its path.

    ``convert='mp3'`` re-encodes a single audio download as MP3 instead of rewrapping it.
    """
    if not files:
        raise RuntimeError('yt-dlp finished without producing a file')
    os.makedirs(out_dir, exist_ok=True)
    if convert == 'mp3':
        destination = unique_path(out_dir, title, 'mp3')
        try:
            convert_to_mp3(files[0], destination, metadata)
        except Exception:
            _remove(destination)
            raise
        return destination
    container = ext if ext and ext.lower() in MUXERS else ('m4a' if audio else 'mp4')
    destination = unique_path(out_dir, title, container)
    try:
        remux(files, destination, metadata, subtitles)
    except Exception:
        _remove(destination)  # the name unique_path reserved
        if len(files) != 1:
            raise
        # A format FFmpeg can't rewrap: keep the file exactly as downloaded
        destination = unique_path(out_dir, title, file_extension(files[0], audio))
        try:
            shutil.move(files[0], destination)  # replaces the reserved, empty file
        except Exception:
            _remove(destination)
            raise
    return destination


def _remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


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
# Names Windows won't create a file or folder with, whatever the extension
_RESERVED = {'con', 'prn', 'aux', 'nul', *(f'com{i}' for i in range(1, 10)), *(f'lpt{i}' for i in range(1, 10))}


def safe_name(title, limit=120, fallback='Download'):
    """``title`` as a file or folder name that works on macOS, Windows and Linux."""
    name = ''.join(' ' if c in _ILLEGAL or ord(c) < 32 else c for c in title or '')
    name = ' '.join(name.split())[:limit].strip(' .')
    if name.split('.')[0].lower() in _RESERVED:
        name = f'{name} _'
    return name or fallback


def unique_path(folder, title, ext):
    """A new file name in ``folder``, created empty right away so parallel downloads of
    same-titled videos can't pick the same one; the caller replaces or removes it."""
    base = safe_name(title)
    counter = 1
    while True:
        path = os.path.join(folder, f'{base}.{ext}' if counter == 1 else f'{base} ({counter}).{ext}')
        try:
            os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
            return path
        except FileExistsError:
            counter += 1


def remove_tree(path):
    shutil.rmtree(path, ignore_errors=True)
