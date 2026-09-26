package app.squirrel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.awt.Desktop
import java.io.File
import java.util.UUID

@Serializable
data class FormatChoice(
    val id: String,
    val label: String,
    val detail: String,
    val formatIds: List<String>,
    val kind: String,
    val ext: String? = null,
    /** False when only third-party players like VLC can play it. */
    val playable: Boolean? = null,
) {
    val isAudio get() = kind == "audio"

    companion object {
        fun from(o: JsonObject): FormatChoice? {
            val id = o.string("id") ?: return null
            val ids = (o["format_ids"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: return null
            return FormatChoice(id, o.string("label") ?: id, o.string("detail").orEmpty(), ids,
                o.string("kind") ?: "video", o.string("ext"), o.bool("playable"))
        }
    }
}

data class VideoInfo(
    val url: String,
    val title: String,
    val uploader: String?,
    val duration: Double?,
    val thumbnail: String?,
    val choices: List<FormatChoice>,
)

@Serializable
enum class DownloadState { Queued, Extracting, Downloading, Merging, Finished, Cancelled, Failed;
    val isActive get() = this in listOf(Queued, Extracting, Downloading, Merging)
}

@Serializable
data class DownloadItem(
    val id: String,
    val sourceUrl: String,
    val title: String,
    val thumbnail: String? = null,
    val choice: FormatChoice,
    val state: DownloadState,
    val error: String? = null,
    val filePath: String? = null,
    val createdAt: Long,
) {
    val file get() = filePath?.let(::File)
}

/** Live, non-persisted progress for an active download. */
data class LiveProgress(
    val downloaded: Double = 0.0,
    val total: Double = 0.0,
    val speed: Double = 0.0,
    val part: Int = 1,
    val parts: Int = 1,
) {
    /** Multi-part downloads (video, then audio) spread across one bar. */
    val fraction: Float?
        get() = if (total > 0) ((part - 1 + minOf(downloaded / total, 1.0)) / maxOf(parts, 1)).toFloat() else null

    /** "Video · 12.3 MB of 45 MB · 2.1 MB/s" */
    val summary: String
        get() = buildList {
            if (parts > 1) add(if (part == 1) "Video" else "Audio")
            add(if (total > 0) "${bytes(downloaded)} of ${bytes(total)}" else bytes(downloaded))
            if (speed > 0) add("${bytes(speed)}/s")
        }.joinToString(" · ")
}

fun bytes(n: Double): String = when {
    n >= 1 shl 30 -> "%.1f GB".format(n / (1 shl 30))
    n >= 1 shl 20 -> "%.1f MB".format(n / (1 shl 20))
    n >= 1 shl 10 -> "%.0f KB".format(n / (1 shl 10))
    else -> "%.0f B".format(n)
}

/** The download list and pipeline: the engine downloads, merges and saves; this tracks it. */
object DownloadStore {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    val items = mutableStateListOf<DownloadItem>()
    val live = mutableStateMapOf<String, LiveProgress>()
    var ytdlpVersion by mutableStateOf<String?>(null)
        private set
    var startupError by mutableStateOf<String?>(null)
        private set

    val hasActiveDownloads get() = items.any { it.state.isActive }

    fun load() {
        val saved = runCatching { json.decodeFromString<List<DownloadItem>>(Paths.library.readText()) }.getOrDefault(emptyList())
        // Anything that was running when the app quit can't be resumed
        items.addAll(saved.map { if (it.state.isActive) it.copy(state = DownloadState.Failed, error = "Interrupted") else it })
    }

    suspend fun start() {
        try {
            ytdlpVersion = Engine.call("start").string("version")
            startupError = null
        } catch (e: Exception) {
            startupError = e.message
        }
    }

    suspend fun fetchInfo(url: String): VideoInfo {
        val result = Engine.call("extract", jsonOf("url" to url))
        val choices = (result["choices"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let(FormatChoice::from) }
        if (choices.isEmpty()) throw EngineException("No downloadable formats found")
        return VideoInfo(
            url = result.string("webpage_url") ?: url,
            title = result.string("title") ?: "Untitled",
            uploader = result.string("uploader"),
            duration = result.double("duration"),
            thumbnail = result.string("thumbnail"),
            choices = choices,
        )
    }

    fun download(info: VideoInfo, choice: FormatChoice) {
        val item = DownloadItem(
            id = UUID.randomUUID().toString(), sourceUrl = info.url, title = info.title, thumbnail = info.thumbnail,
            choice = choice, state = DownloadState.Queued, createdAt = System.currentTimeMillis(),
        )
        items.add(0, item)
        save()
        scope.launch { perform(item.id) }
    }

    fun retry(id: String) {
        update(id) { it.copy(state = DownloadState.Queued, error = null) }
        scope.launch { perform(id) }
    }

    fun cancel(id: String) {
        scope.launch { runCatching { Engine.call("cancel", jsonOf("job_id" to id)) } }
    }

    /** Removes the row; the file stays unless [deleteFile] is set. */
    fun remove(id: String, deleteFile: Boolean = false) {
        items.firstOrNull { it.id == id }?.let { item ->
            if (item.state.isActive) cancel(id)
            if (deleteFile) item.file?.let { file ->
                if (Desktop.getDesktop().isSupported(Desktop.Action.MOVE_TO_TRASH)) Desktop.getDesktop().moveToTrash(file)
                else file.delete()
            }
        }
        items.removeAll { it.id == id }
        save()
    }

    fun clearFinished() {
        items.removeAll { !it.state.isActive }
        save()
    }

    fun open(item: DownloadItem) {
        item.file?.takeIf { it.exists() }?.let { runCatching { Desktop.getDesktop().open(it) } }
    }

    fun reveal(item: DownloadItem) {
        val file = item.file ?: return
        runCatching {
            if (isWindows) ProcessBuilder("explorer.exe", "/select,", file.path).start()
            else Desktop.getDesktop().open(file.parentFile)
        }
    }

    private suspend fun perform(id: String) {
        val item = items.firstOrNull { it.id == id } ?: return
        update(id) { it.copy(state = DownloadState.Extracting) }
        live[id] = LiveProgress(parts = item.choice.formatIds.size)

        val poller = scope.launch {
            while (isActive) {
                delay(400)
                runCatching { Engine.call("progress", jsonOf("job_id" to id)) }.getOrNull()?.let { apply(it, id) }
            }
        }
        try {
            // The engine downloads, merges and saves into the download folder
            val result = Engine.call("download", jsonOf(
                "url" to item.sourceUrl,
                "format_ids" to item.choice.formatIds,
                "ext" to item.choice.ext.orEmpty(),
                "audio" to item.choice.isAudio,
                "title" to item.title,
                "job_id" to id,
            ))
            update(id) { it.copy(state = DownloadState.Finished, title = result.string("title") ?: it.title, filePath = result.string("path")) }
        } catch (e: EngineException) {
            update(id) {
                if (e.cancelled) it.copy(state = DownloadState.Cancelled)
                else it.copy(state = DownloadState.Failed, error = e.message)
            }
        } catch (e: Exception) {
            update(id) { it.copy(state = DownloadState.Failed, error = e.message ?: e.toString()) }
        }
        poller.cancel()
        live.remove(id)
        save()
    }

    private fun apply(progress: JsonObject, id: String) {
        val current = live[id] ?: return
        live[id] = current.copy(
            downloaded = progress.double("downloaded") ?: current.downloaded,
            total = progress.double("total") ?: current.total,
            speed = progress.double("speed") ?: 0.0,
            part = progress.int("part") ?: current.part,
            parts = progress.int("parts") ?: current.parts,
        )
        val state = items.firstOrNull { it.id == id }?.state ?: return
        if (!state.isActive) return
        when (progress.string("status")) {
            "downloading" -> if (state != DownloadState.Downloading) update(id) { it.copy(state = DownloadState.Downloading) }
            "merging" -> if (state != DownloadState.Merging) update(id) { it.copy(state = DownloadState.Merging) }
        }
    }

    private fun update(id: String, body: (DownloadItem) -> DownloadItem) {
        val index = items.indexOfFirst { it.id == id }
        if (index >= 0) items[index] = body(items[index])
    }

    private fun save() {
        runCatching {
            Paths.data.mkdirs()
            Paths.library.writeText(json.encodeToString(items.toList()))
        }
    }
}
