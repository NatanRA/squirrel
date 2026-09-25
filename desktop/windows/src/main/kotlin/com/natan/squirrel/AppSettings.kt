package com.natan.squirrel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.io.File

/** Browsers yt-dlp can read cookies from (yt-dlp's names). */
enum class CookieBrowser(val id: String, val label: String) {
    Off("", "Don't use cookies"),
    Firefox("firefox", "Firefox"),
    Chrome("chrome", "Google Chrome"),
    Edge("edge", "Microsoft Edge"),
    Brave("brave", "Brave"),
    Chromium("chromium", "Chromium"),
    Opera("opera", "Opera"),
    Vivaldi("vivaldi", "Vivaldi"),
}

/** Settings shared with the engine through settings.json (see squirrel_host.py). */
object AppSettings {
    var downloadFolder by mutableStateOf(Paths.defaultDownloads)
        private set
    var cookieBrowser by mutableStateOf(CookieBrowser.Off)
        private set

    fun load() {
        val stored = runCatching { Json.parseToJsonElement(Paths.settings.readText()) as JsonObject }.getOrNull()
        stored?.string("download_dir")?.let { downloadFolder = File(it) }
        cookieBrowser = CookieBrowser.entries.firstOrNull { it.id == stored?.string("cookies_from_browser") } ?: CookieBrowser.Off
        save()
    }

    fun setDownloadFolder(folder: File) { downloadFolder = folder; save() }
    fun setCookieBrowser(browser: CookieBrowser) { cookieBrowser = browser; save() }

    private fun save() {
        // Windows 11 ships AV1 and VP9 support, so those count as playable there
        val settings = jsonOf(
            "download_dir" to downloadFolder.path,
            "cookies_from_browser" to cookieBrowser.id,
            "av1_decode" to isWindows,
            "vp9_decode" to isWindows,
        )
        runCatching {
            Paths.data.mkdirs()
            Paths.settings.writeText(settings.toString())
        }
    }
}

/** App-only preferences (the engine doesn't read these). */
object Preferences {
    private val values: MutableMap<String, String> = runCatching {
        (Json.parseToJsonElement(Paths.preferences.readText()) as JsonObject)
            .mapValues { (it.value as? kotlinx.serialization.json.JsonPrimitive)?.content.orEmpty() }.toMutableMap()
    }.getOrElse { mutableMapOf() }

    operator fun get(key: String): String? = values[key]

    operator fun set(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
        runCatching {
            Paths.data.mkdirs()
            Paths.preferences.writeText(jsonOf(*values.map { it.key to it.value }.toTypedArray()).toString())
        }
    }
}
