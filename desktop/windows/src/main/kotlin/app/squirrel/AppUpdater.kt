package app.squirrel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.awt.Desktop
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.prefs.Preferences
import kotlin.system.exitProcess

/**
 * Checks GitHub for a newer release of Squirrel itself when the app opens, and installs it:
 * the MSI is downloaded, then the app quits and the installer upgrades it in place (the
 * installer's upgradeUuid stays the same across versions). UpdateManager is separate: it
 * keeps yt-dlp up to date.
 */
object AppUpdater {
    data class Release(val version: String, val page: String, val installer: String?)

    private const val LATEST_RELEASE = "https://api.github.com/repos/NatanRA/squirrel/releases/latest"
    private val prefs = Preferences.userRoot().node("app/squirrel/appUpdate")

    /** A newer release the user hasn't dismissed */
    var available by mutableStateOf<Release?>(null)
        private set

    /** 0 to 1 while the installer downloads */
    var progress by mutableStateOf<Float?>(null)
        private set

    var error by mutableStateOf<String?>(null)
        private set

    /** Set by the packaged app (jpackage); null when run from Gradle, which never offers updates */
    val currentVersion: String? = System.getProperty("jpackage.app-version")

    suspend fun check() {
        val current = currentVersion ?: return
        val release = runCatching { withContext(Dispatchers.IO) { fetchLatest() } }.getOrNull() ?: return
        if (isNewer(release.version, current) && release.version != prefs.get("dismissed", null)) available = release
    }

    /** Hides this version; the next one is offered again. */
    fun dismiss() {
        available?.let { prefs.put("dismissed", it.version) }
        available = null
    }

    suspend fun install() {
        val release = available ?: return
        val installer = release.installer ?: return open(release.page)
        if (progress != null) return
        error = null
        progress = 0f
        try {
            val file = withContext(Dispatchers.IO) { download(installer) }
            // msiexec closes the running app's files, so hand over and quit
            ProcessBuilder("msiexec", "/i", file.absolutePath).start()
            exitProcess(0)
        } catch (e: Exception) {
            error = "Couldn't download the update: ${e.message ?: e}"
        } finally {
            progress = null
        }
    }

    private fun open(page: String) {
        runCatching { Desktop.getDesktop().browse(URI(page)) }
    }

    private fun fetchLatest(): Release {
        val connection = URL(LATEST_RELEASE).openConnection() as HttpURLConnection
        connection.setRequestProperty("Accept", "application/vnd.github+json")
        val json = connection.inputStream.bufferedReader().use { Json.parseToJsonElement(it.readText()) as JsonObject }
        val installer = json["assets"]?.jsonArray?.map { it.jsonObject }
            ?.firstOrNull { it["name"]?.jsonPrimitive?.content == "Squirrel.msi" }
            ?.get("browser_download_url")?.jsonPrimitive?.content
        return Release(
            json.getValue("tag_name").jsonPrimitive.content.removePrefix("v"),
            json.getValue("html_url").jsonPrimitive.content,
            installer,
        )
    }

    private fun download(url: String): File {
        val file = File(System.getProperty("java.io.tmpdir"), "Squirrel-update.msi")
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
                    if (total > 0) progress = done.toFloat() / total
                }
            }
        }
        return file
    }

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
