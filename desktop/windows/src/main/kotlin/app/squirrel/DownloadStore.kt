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
import kotlinx.serialization.json.contentOrNull
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

        /** Stands in for a playlist item's choice until the engine picks one from the video's formats. */
        fun placeholder(target: DownloadTarget) = FormatChoice("target", target.label, "", emptyList(), target.kind)
    }
}

/**
 * A playlist's quality: the best version up to a height, or just the audio. The engine turns it
 * into one of each video's own choices when that video downloads.
 */
@Serializable
data class DownloadTarget(val kind: String, val maxHeight: Int? = null) {
    val id get() = if (kind == "audio") "audio" else maxHeight?.let { "v$it" } ?: "best"
    val label get() = if (kind == "audio") "Audio" else maxHeight?.let { "${it}p" } ?: "Best"

    val arguments
        get() = if (maxHeight != null) jsonOf("kind" to kind, "max_height" to maxHeight) else jsonOf("kind" to kind)

    companion object {
        val Best = DownloadTarget("video")
        val Audio = DownloadTarget("audio")
        val all = listOf(Best, DownloadTarget("video", 1080), DownloadTarget("video", 720), DownloadTarget("video", 480), Audio)
    }
}

/** What a pasted link turned out to be */
sealed interface FetchResult

data class VideoInfo(
    val url: String,
    val title: String,
    val uploader: String?,
    val duration: Double?,
    val thumbnail: String?,
    val choices: List<FormatChoice>,
    /** Identifies the video across links (yt-dlp's archive id, "youtube dQw4w9WgXcQ") */
    val key: String? = null,
    /** The playlist a YouTube link also names, for "Whole Playlist" */
    val playlistUrl: String? = null,
) : FetchResult

data class PlaylistEntry(
    /** Position in the playlist, from 1 */
    val index: Int,
    val key: String?,
    val title: String,
    val duration: Double?,
    val thumbnail: String?,
    val url: String,
    /** Set when the entry has no link of its own (e.g. the 2nd video of a post): which item of [url] */
    val pick: Int?,
    val section: String?,
    val unavailable: Boolean,
    val live: Boolean,
) {
    companion object {
        fun from(o: JsonObject, index: Int, fallbackUrl: String) = PlaylistEntry(
            index = o.int("index") ?: index,
            key = o.string("key"),
            title = o.string("title") ?: "Item $index",
            duration = o.double("duration"),
            thumbnail = o.string("thumbnail"),
            url = o.string("url") ?: fallbackUrl,
            pick = o.int("pick"),
            section = o.string("section"),
            unavailable = o.bool("unavailable") == true,
            live = o.bool("live") == true,
        )
    }
}

data class PlaylistInfo(
    val id: String,
    val url: String,
    val title: String,
    val uploader: String?,
    /** All items, which can be more than [entries] holds (see [truncated]); null when the site doesn't say */
    val count: Int?,
    val truncated: Boolean,
    /** The playlist's own folder; null for the videos of a single post */
    val folder: String?,
    val sections: List<String>,
    /** From YouTube Music, so audio is the likely choice */
    val isMusic: Boolean,
    val entries: List<PlaylistEntry>,
) : FetchResult

@Serializable
enum class DownloadState { Queued, Extracting, Downloading, Merging, Finished, Cancelled, Failed;
    /** Waiting or running */
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
    // Defaults so libraries saved by older versions still load
    val key: String? = null,
    /** A playlist item's quality; [choice] becomes the resolved choice once it downloads */
    val target: DownloadTarget? = null,
    val pick: Int? = null,
    val playlist: PlaylistRef? = null,
) {
    val file get() = filePath?.let(::File)

    /** Which playlist a download came from, and where in it */
    @Serializable
    data class PlaylistRef(
        val id: String,
        val title: String,
        val index: Int,
        val count: Int,
        /** Saved in a folder with this name inside the download folder */
        val folder: String? = null,
    )

    /** Downloads added together from one playlist */
    fun isInBatch(other: DownloadItem) = playlist != null && playlist.id == other.playlist?.id && createdAt == other.createdAt
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
    private const val LIMIT = "downloads.limit"
    private const val PLAYLIST_FOLDERS = "playlists.ownFolder"

    // Everything here runs on the UI thread, including the pipeline's coroutines
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    val items = mutableStateListOf<DownloadItem>()
    val live = mutableStateMapOf<String, LiveProgress>()
    var ytdlpVersion by mutableStateOf<String?>(null)
        private set
    var startupError by mutableStateOf<String?>(null)
        private set
    /** Waiting downloads don't start (after a relaunch, until the user resumes) */
    var paused by mutableStateOf(false)
        private set
    /** How many downloads run at once (Settings); the rest wait their turn */
    var limit by mutableStateOf(Preferences[LIMIT]?.toIntOrNull()?.coerceIn(1, 5) ?: 3)
        private set
    /** Each playlist is saved in a folder of its own inside the download folder (Settings) */
    var playlistFolders by mutableStateOf(Preferences[PLAYLIST_FOLDERS] != "false")
        private set
    /** Started and not yet done */
    private val running = mutableSetOf<String>()

    val hasActiveDownloads get() = items.any { it.state.isActive }
    val waitingCount get() = items.count { it.state == DownloadState.Queued }

    fun load() {
        val text = runCatching { Paths.library.readText() }.getOrNull() ?: return
        val saved = try {
            json.decodeFromString<List<DownloadItem>>(text)
        } catch (e: Exception) {
            // Keep a copy rather than let the next save replace the whole list with nothing
            runCatching { Paths.library.copyTo(File(Paths.data, "library.json.bak"), overwrite = true) }
            return
        }
        // Downloads that were running when the app quit start over, but only once the user says so
        items.addAll(saved.map { if (it.state.isActive) it.copy(state = DownloadState.Queued) else it })
        paused = waitingCount > 0
    }

    fun updateLimit(value: Int) {
        limit = value
        Preferences[LIMIT] = value.toString()
        pump()
    }

    fun updatePlaylistFolders(value: Boolean) {
        playlistFolders = value
        Preferences[PLAYLIST_FOLDERS] = value.toString()
    }

    suspend fun start() {
        try {
            ytdlpVersion = Engine.call("start").string("version")
            startupError = null
        } catch (e: Exception) {
            startupError = e.message
        }
    }

    /** A video with its download choices, or a playlist's items. */
    suspend fun fetch(url: String): FetchResult {
        val result = Engine.call("extract", jsonOf("url" to url, "playlists" to true))
        if (result.string("type") == "playlist") {
            val pageUrl = result.string("webpage_url") ?: url
            val entries = (result["entries"] as? JsonArray).orEmpty().mapIndexedNotNull { i, entry ->
                (entry as? JsonObject)?.let { PlaylistEntry.from(it, i + 1, pageUrl) }
            }
            return PlaylistInfo(
                id = result.string("id") ?: pageUrl,
                url = pageUrl,
                title = result.string("title") ?: "Playlist",
                uploader = result.string("uploader"),
                count = result.int("count"),
                truncated = result.bool("truncated") == true,
                folder = result.string("folder"),
                sections = (result["sections"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                isMusic = result.bool("music") == true,
                entries = entries,
            )
        }
        val choices = (result["choices"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let(FormatChoice::from) }
        if (choices.isEmpty()) throw EngineException("No downloadable formats found")
        return VideoInfo(
            url = result.string("webpage_url") ?: url,
            title = result.string("title") ?: "Untitled",
            uploader = result.string("uploader"),
            duration = result.double("duration"),
            thumbnail = result.string("thumbnail"),
            choices = choices,
            key = result.string("key"),
            playlistUrl = result.string("playlist_url"),
        )
    }

    fun download(info: VideoInfo, choice: FormatChoice) {
        val item = DownloadItem(
            id = UUID.randomUUID().toString(), sourceUrl = info.url, title = info.title, thumbnail = info.thumbnail,
            choice = choice, state = DownloadState.Queued, createdAt = System.currentTimeMillis(), key = info.key,
        )
        items.add(0, item)
        save()
        resume()
    }

    /** Queues the chosen items of a playlist, each at [target] quality. */
    fun download(entries: List<PlaylistEntry>, playlist: PlaylistInfo, target: DownloadTarget) {
        val added = System.currentTimeMillis()
        val new = entries.map { entry ->
            DownloadItem(
                id = UUID.randomUUID().toString(), sourceUrl = entry.url, title = entry.title, thumbnail = entry.thumbnail,
                choice = FormatChoice.placeholder(target), state = DownloadState.Queued, createdAt = added,
                key = entry.key, target = target, pick = entry.pick,
                playlist = DownloadItem.PlaylistRef(
                    playlist.id, playlist.title, entry.index, playlist.entries.size,
                    folder = playlist.folder.takeIf { playlistFolders },
                ),
            )
        }
        items.addAll(0, new)
        save()
        resume()
    }

    fun retry(id: String) {
        update(id) { it.copy(state = DownloadState.Queued, error = null) }
        save()
        resume()
    }

    fun cancel(id: String) {
        val item = items.firstOrNull { it.id == id } ?: return
        if (item.state == DownloadState.Queued) {
            // Not started (perform skips it if it was about to)
            update(id) { it.copy(state = DownloadState.Cancelled) }
            save()
        } else if (id in running) {
            scope.launch { runCatching { Engine.call("cancel", jsonOf("job_id" to id)) } }
        }
    }

    /** Cancels what's left of the playlist batch [item] belongs to. */
    fun cancelRest(item: DownloadItem) {
        for (index in items.indices) {
            val other = items[index]
            if (!other.state.isActive || !other.isInBatch(item)) continue
            if (other.state == DownloadState.Queued) {
                items[index] = other.copy(state = DownloadState.Cancelled)  // saved once below, not per video
            } else {
                cancel(other.id)
            }
        }
        save()
    }

    /** Cancels every waiting download (the paused queue's "Cancel All"). */
    fun cancelWaiting() {
        for (index in items.indices) {
            val item = items[index]
            if (item.state == DownloadState.Queued && item.id !in running) items[index] = item.copy(state = DownloadState.Cancelled)
        }
        paused = false
        save()
    }

    /** Starts waiting downloads again. */
    fun resume() {
        paused = false
        pump()
    }

    /** Starts waiting downloads, oldest first, while fewer than the limit run. */
    fun pump() {
        if (paused) return
        while (running.size < limit) {
            val next = nextWaiting() ?: break
            running += next.id
            scope.launch {
                try {
                    perform(next.id)
                } finally {
                    running -= next.id
                    pump()
                }
            }
        }
    }

    private fun nextWaiting() = items
        .filter { it.state == DownloadState.Queued && it.id !in running }
        .minWithOrNull(compareBy({ it.createdAt }, { it.playlist?.index ?: 0 }))

    /** The finished download of the same video, if its file is still there. */
    fun downloaded(key: String?, url: String): DownloadItem? = items.firstOrNull { item ->
        item.state == DownloadState.Finished && (key != null && item.key == key || item.pick == null && item.sourceUrl == url)
            && item.file?.exists() == true
    }

    /** What the playlist picker needs to mark items: (already downloaded, waiting or running now). */
    fun library(): Pair<Set<String>, Set<String>> {
        val downloaded = mutableSetOf<String>()
        val active = mutableSetOf<String>()
        for (item in items) {
            // Videos of one post share its link, so only their ids tell them apart
            val ids = listOfNotNull(item.key, item.sourceUrl.takeIf { item.pick == null })
            if (item.state.isActive) active += ids
            else if (item.state == DownloadState.Finished && item.file?.exists() == true) downloaded += ids
        }
        return downloaded to active
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
        val item = items.firstOrNull { it.id == id }?.takeIf { it.state == DownloadState.Queued } ?: return
        update(id) { it.copy(state = DownloadState.Extracting) }
        live[id] = LiveProgress(parts = maxOf(1, item.choice.formatIds.size))

        val poller = scope.launch {
            while (isActive) {
                delay(400)
                runCatching { Engine.call("progress", jsonOf("job_id" to id)) }.getOrNull()?.let { apply(it, id) }
            }
        }
        val args = buildList<Pair<String, Any?>> {
            add("url" to item.sourceUrl)
            add("title" to item.title)
            add("job_id" to id)
            if (item.target != null) {
                // The engine picks this video's choice for the playlist's quality
                add("target" to item.target.arguments)
            } else {
                add("format_ids" to item.choice.formatIds)
                add("ext" to item.choice.ext.orEmpty())
                add("audio" to item.choice.isAudio)
            }
            item.pick?.let { add("playlist_index" to it) }
            item.playlist?.folder?.let { add("subfolder" to it) }
        }
        try {
            // The engine downloads, merges and saves into the download folder
            val result = Engine.call("download", jsonOf(*args.toTypedArray()))
            update(id) {
                it.copy(
                    state = DownloadState.Finished,
                    title = result.string("title") ?: it.title,
                    filePath = result.string("path"),
                    key = result.string("key") ?: it.key,
                    choice = (result["choice"] as? JsonObject)?.let(FormatChoice::from) ?: it.choice,
                )
            }
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
