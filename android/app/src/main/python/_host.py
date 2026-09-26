"""Android implementation of ``_host``, the module the shared bridge calls into.

The iOS app provides the same module in C (ios/App/Bridge/PyBridge.c).
"""
from java import jclass

_JsEngine = jclass('app.squirrel.python.JsEngine')


def run_js(code):
    """Evaluate JavaScript in V8 (Jetpack JavaScriptEngine); returns console output."""
    try:
        return _JsEngine.run(code)
    except Exception as e:  # Java exceptions arrive as Python exceptions
        raise RuntimeError(str(e)) from None
