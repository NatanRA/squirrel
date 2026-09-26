"""Mac implementation of ``_host``: runs yt-dlp's YouTube challenge solver in
the system JavaScriptCore, like the iOS app, so no JavaScript engine needs to be bundled.

Uses JavaScriptCore's C API through ctypes. As on Android, the solver's
console.log output is collected in JavaScript and returned as the result.
Only bundled in the Mac runtime; the Windows app bundles QuickJS-ng instead.
"""
from __future__ import annotations

import ctypes
import os

_PATH = os.environ.get('SQUIRREL_JSC_LIB') or '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore'
_jsc = ctypes.CDLL(_PATH)

_ref = ctypes.c_void_p
_jsc.JSGlobalContextCreate.argtypes = [_ref]
_jsc.JSGlobalContextCreate.restype = _ref
_jsc.JSGlobalContextRelease.argtypes = [_ref]
_jsc.JSStringCreateWithUTF8CString.argtypes = [ctypes.c_char_p]
_jsc.JSStringCreateWithUTF8CString.restype = _ref
_jsc.JSStringRelease.argtypes = [_ref]
_jsc.JSStringGetMaximumUTF8CStringSize.argtypes = [_ref]
_jsc.JSStringGetMaximumUTF8CStringSize.restype = ctypes.c_size_t
_jsc.JSStringGetUTF8CString.argtypes = [_ref, ctypes.c_char_p, ctypes.c_size_t]
_jsc.JSStringGetUTF8CString.restype = ctypes.c_size_t
_jsc.JSEvaluateScript.argtypes = [_ref, _ref, _ref, _ref, ctypes.c_int, ctypes.POINTER(_ref)]
_jsc.JSEvaluateScript.restype = _ref
_jsc.JSValueToStringCopy.argtypes = [_ref, _ref, ctypes.POINTER(_ref)]
_jsc.JSValueToStringCopy.restype = _ref

_PRELUDE = ("var __out = []; var console = { log: function () "
            "{ __out.push(Array.prototype.slice.call(arguments).join(' ')); }, warn: function () {}, error: function () {} };\n")
_EPILOGUE = "\n;__out.join('\\n');"


def _to_text(context, value):
    string = _jsc.JSValueToStringCopy(context, value, None)
    if not string:
        return ''
    try:
        size = _jsc.JSStringGetMaximumUTF8CStringSize(string)
        buffer = ctypes.create_string_buffer(size)
        _jsc.JSStringGetUTF8CString(string, buffer, size)
        return buffer.value.decode('utf-8', errors='replace')
    finally:
        _jsc.JSStringRelease(string)


def run_js(code):
    """Evaluate JavaScript in a fresh context; returns what it logged."""
    context = _jsc.JSGlobalContextCreate(None)
    if not context:
        raise RuntimeError('Could not create a JavaScriptCore context')
    script = _jsc.JSStringCreateWithUTF8CString((_PRELUDE + code + _EPILOGUE).encode('utf-8'))
    try:
        exception = _ref()
        result = _jsc.JSEvaluateScript(context, script, None, None, 1, ctypes.byref(exception))
        if exception.value:
            raise RuntimeError(_to_text(context, exception) or 'Unknown JavaScript error')
        return _to_text(context, result)
    finally:
        _jsc.JSStringRelease(script)
        _jsc.JSGlobalContextRelease(context)
