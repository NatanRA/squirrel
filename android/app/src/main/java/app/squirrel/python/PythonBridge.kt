package app.squirrel.python

import android.app.Application
import android.content.pm.ApplicationInfo
import android.media.MediaCodecList
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import app.squirrel.data.CookieStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class BridgeException(message: String, val cancelled: Boolean = false) : Exception(message)

/** org.json turns JSON null into the text "null"; this returns null for missing, null or empty values. */
fun JSONObject.string(key: String): String? = if (isNull(key)) null else optString(key).ifEmpty { null }

/**
 * Runs the shared yt-dlp bridge (shared/pybridge/ytdl_bridge.py) through Chaquopy.
 * Every call takes and returns JSON, exactly as on iOS.
 */
object PythonBridge {
    /** Python calls get big-stack threads: yt-dlp can recurse deeply. */
    private val dispatcher = Executors.newCachedThreadPool { runnable ->
        Thread(null, runnable, "python", 16L shl 20)
    }.asCoroutineDispatcher()

    private val ready = CompletableDeferred<String>()
    private lateinit var module: PyObject

    /** Starts Python in the background; returns immediately. */
    fun start(app: Application) {
        Thread(null, {
            try {
                if (!Python.isStarted()) Python.start(AndroidPlatform(app))
                val python = Python.getInstance()
                // Read by ytdl_updater.py before yt-dlp is imported
                python.getModule("os").get("environ")!!
                    .callAttr("__setitem__", "YTDL_UPDATE_DIR", File(app.filesDir, "python-updates").path)
                JsEngine.init(app)
                module = python.getModule("ytdl_bridge")
                val config = JSONObject()
                    .put("cache_dir", File(app.cacheDir, "yt-dlp").path)
                    .put("cookie_file", CookieStore.cookieFile(app).path)
                    .put("av1_decode", canDecode("video/av01"))
                    .put("vp9_decode", canDecode("video/x-vnd.on2.vp9"))
                    // Debug builds log yt-dlp's verbose output to logcat (python.stdout)
                    .put("verbose", app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
                ready.complete(invoke("configure", config).string("version") ?: "unknown")
            } catch (e: Throwable) {
                ready.completeExceptionally(e)
            }
        }, "python-start", 16L shl 20).start()
    }

    /** The bundled or updated yt-dlp version, once Python is up. */
    suspend fun version(): String = ready.await()

    suspend fun call(function: String, args: JSONObject = JSONObject()): JSONObject {
        ready.await()
        return withContext(dispatcher) { invoke(function, args) }
    }

    private fun invoke(function: String, args: JSONObject): JSONObject {
        val result = JSONObject(module.callAttr(function, args.toString()).toString())
        if (!result.optBoolean("ok")) {
            throw BridgeException(result.string("error") ?: "Unknown error", result.optBoolean("cancelled"))
        }
        return result
    }

    /** Any decoder counts: Android's software AV1/VP9 decoders play fine in gallery apps. */
    private fun canDecode(mime: String): Boolean =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
}
