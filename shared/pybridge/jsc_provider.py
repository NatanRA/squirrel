"""yt-dlp JS challenge provider backed by the system JavaScriptCore.

Mobile apps can't spawn deno/node, so the EJS solver scripts run in the
platform's own engine instead, exposed by the app as the module ``_host``:
JavaScriptCore on iOS, V8 via Jetpack JavaScriptEngine on Android.
This relies on yt-dlp internals; if a future yt-dlp moves them, importing this
module fails and ytdl_updater falls back to the bundled yt-dlp.
"""
from __future__ import annotations

import _host

from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot._provider import BuiltinIEContentProvider
from yt_dlp.globals import supported_js_runtimes
from yt_dlp.utils._jsruntime import JsRuntime, JsRuntimeInfo


class JavaScriptCoreRuntime(JsRuntime):
    def _info(self):
        return JsRuntimeInfo(
            name='javascriptcore', path='builtin', version='1.0', version_tuple=(1, 0))


supported_js_runtimes.value['jsc'] = JavaScriptCoreRuntime


@register_provider
class JavaScriptCoreJCP(EJSBaseJCP, BuiltinIEContentProvider):
    PROVIDER_NAME = 'javascriptcore'
    JS_RUNTIME_NAME = 'jsc'

    def _run_js_runtime(self, stdin: str, /) -> str:
        try:
            return _host.run_js(stdin)
        except RuntimeError as e:
            raise JsChallengeProviderError(f'JavaScript engine error: {e}') from e


@register_preference(JavaScriptCoreJCP)
def _jsc_preference(provider, requests):
    return 900
