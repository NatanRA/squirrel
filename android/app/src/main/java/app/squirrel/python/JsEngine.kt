package app.squirrel.python

import android.content.Context
import androidx.javascriptengine.IsolateStartupParameters
import androidx.javascriptengine.JavaScriptSandbox
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit

/**
 * Runs yt-dlp's YouTube challenge solver in V8, via Jetpack JavaScriptEngine
 * (an isolated process backed by the system WebView). Called synchronously
 * from Python through `_host.run_js` (app/src/main/python/_host.py).
 */
object JsEngine {
    private lateinit var context: Context
    private var sandbox: JavaScriptSandbox? = null

    /** The solver prints its result with console.log; collect it and return it. */
    private const val PRELUDE = "var __out = []; var console = { log: function () " +
        "{ __out.push(Array.prototype.slice.call(arguments).join(' ')); }, warn: function () {}, error: function () {} };\n"
    private const val EPILOGUE = "\n;__out.join('\\n');"

    /** Scripts above this need a WebView that lifts the binder transaction limit. */
    private const val TRANSACTION_LIMIT = 512 * 1024

    fun init(context: Context) {
        this.context = context.applicationContext
    }

    @JvmStatic
    @Synchronized
    fun run(code: String): String {
        if (!JavaScriptSandbox.isSupported()) {
            throw IllegalStateException("This device's WebView doesn't support JavaScriptSandbox")
        }
        val box = sandbox ?: JavaScriptSandbox.createConnectedInstanceAsync(context)
            .get(30, TimeUnit.SECONDS)
            .also { sandbox = it }

        val script = PRELUDE + code + EPILOGUE
        if (script.length > TRANSACTION_LIMIT &&
            !box.isFeatureSupported(JavaScriptSandbox.JS_FEATURE_EVALUATE_WITHOUT_TRANSACTION_LIMIT)
        ) {
            throw IllegalStateException("Update Android System WebView to solve YouTube's challenges")
        }

        val parameters = IsolateStartupParameters()
        if (box.isFeatureSupported(JavaScriptSandbox.JS_FEATURE_ISOLATE_MAX_HEAP_SIZE)) {
            parameters.maxHeapSizeBytes = 512L shl 20
        }
        val isolate = box.createIsolate(parameters)
        try {
            return isolate.evaluateJavaScriptAsync(script).get(60, TimeUnit.SECONDS)
        } catch (e: ExecutionException) {
            throw IllegalStateException(e.cause?.message ?: "JavaScript failed", e.cause)
        } finally {
            isolate.close()
        }
    }
}
