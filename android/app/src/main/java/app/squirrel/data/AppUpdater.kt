package app.squirrel.data

import android.app.Application
import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Checks GitHub for a newer release of Squirrel itself when the app opens, and installs it:
 * the APK is downloaded, then Android's installer takes over (it asks once to allow installs
 * from Squirrel). UpdateManager is separate: it keeps yt-dlp up to date inside the app.
 */
class AppUpdater(private val app: Application, private val scope: CoroutineScope) {
    data class Release(val version: String, val page: String, val apk: String?)

    private val prefs = app.getSharedPreferences("app_update", Application.MODE_PRIVATE)

    private val _available = MutableStateFlow<Release?>(null)
    /** A newer release the user hasn't dismissed */
    val available: StateFlow<Release?> = _available

    private val _progress = MutableStateFlow<Float?>(null)
    /** 0 to 1 while the APK downloads */
    val progress: StateFlow<Float?> = _progress

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error

    val currentVersion: String = runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }
        .getOrNull() ?: "0"

    fun check() {
        scope.launch {
            val release = runCatching { withContext(Dispatchers.IO) { fetchLatest() } }.getOrNull() ?: return@launch
            if (isNewer(release.version, currentVersion) && release.version != prefs.getString(KEY_DISMISSED, null)) {
                _available.value = release
            }
        }
    }

    /** Hides this version; the next one is offered again. */
    fun dismiss() {
        _available.value?.let { prefs.edit().putString(KEY_DISMISSED, it.version).apply() }
        _available.value = null
    }

    fun install() {
        val release = _available.value ?: return
        val apk = release.apk ?: return openPage(release.page)
        if (_progress.value != null) return
        scope.launch {
            _error.value = null
            _progress.value = 0f
            try {
                val file = withContext(Dispatchers.IO) { download(apk) }
                val uri = FileProvider.getUriForFile(app, "${app.packageName}.updates", file)
                app.startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (e: Exception) {
                _error.value = "Couldn't download the update: ${e.message ?: e}"
            } finally {
                _progress.value = null
            }
        }
    }

    private fun openPage(page: String) {
        app.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(page)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun fetchLatest(): Release {
        val connection = URL(LATEST_RELEASE).openConnection() as HttpURLConnection
        connection.setRequestProperty("Accept", "application/vnd.github+json")
        val json = connection.inputStream.bufferedReader().use { JSONObject(it.readText()) }
        val assets = json.optJSONArray("assets")
        // Phones are arm64; the x86_64 build is for Intel emulators
        val name = if (Build.SUPPORTED_ABIS.firstOrNull() == "x86_64") "Squirrel-x86_64.apk" else "Squirrel-arm64.apk"
        val apk = (0 until (assets?.length() ?: 0)).map { assets!!.getJSONObject(it) }
            .firstOrNull { it.optString("name") == name }?.optString("browser_download_url")
        return Release(json.getString("tag_name").removePrefix("v"), json.getString("html_url"), apk)
    }

    private fun download(url: String): File {
        val dir = File(app.cacheDir, "updates").apply { deleteRecursively(); mkdirs() }
        val file = File(dir, "Squirrel.apk")
        val connection = URL(url).openConnection() as HttpURLConnection  // follows GitHub's redirect to the file
        val total = connection.contentLengthLong
        connection.inputStream.use { input ->
            file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var done = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    done += read
                    if (total > 0) _progress.value = done.toFloat() / total
                }
            }
        }
        return file
    }

    companion object {
        private const val LATEST_RELEASE = "https://api.github.com/repos/NatanRA/squirrel/releases/latest"
        private const val KEY_DISMISSED = "dismissedVersion"

        /** "1.10.0" is newer than "1.9.2" */
        fun isNewer(version: String, other: String): Boolean {
            val a = version.split('.').map { it.toIntOrNull() ?: 0 }
            val b = other.split('.').map { it.toIntOrNull() ?: 0 }
            for (i in 0 until maxOf(a.size, b.size)) {
                val x = a.getOrElse(i) { 0 }
                val y = b.getOrElse(i) { 0 }
                if (x != y) return x > y
            }
            return false
        }
    }
}
