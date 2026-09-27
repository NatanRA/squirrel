package app.squirrel.data

import android.app.Application
import android.app.RecoverableSecurityException
import android.content.Context
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.os.LocaleList
import android.provider.DocumentsContract
import android.provider.MediaStore
import app.squirrel.Remuxer
import app.squirrel.python.BridgeException
import app.squirrel.python.PythonBridge
import app.squirrel.python.int
import app.squirrel.python.string
import app.squirrel.service.DownloadService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * The download list and pipeline: yt-dlp download -> FFmpeg remux -> shared storage.
 *
 * Downloads wait in a queue and a few run at once. The queue is only changed on the main
 * thread: by the UI, and by [scope], which runs there.
 */
class DownloadRepository(private val app: Application, private val scope: CoroutineScope) {
    private val libraryFile = File(app.filesDir, "library.json")
    private val workRoot = File(app.cacheDir, "work")
    private val json = Json { ignoreUnknownKeys = true }
    private val prefs = app.getSharedPreferences("downloads", Context.MODE_PRIVATE)

    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<DownloadItem>> = _items

    private val _live = MutableStateFlow<Map<String, LiveProgress>>(emptyMap())
    val live: StateFlow<Map<String, LiveProgress>> = _live

    private val _paused = MutableStateFlow(false)
    /** Waiting downloads don't start (after a relaunch, until the user resumes) */
    val paused: StateFlow<Boolean> = _paused

    /** Started and not yet done */
    private val running = mutableSetOf<String>()
    /** Running downloads to put back in the queue once they stop, rather than mark cancelled */
    private val requeue = mutableSetOf<String>()
    private var saveJob: Job? = null

    init {
        // Downloads that were running when the process died start over, but only once the user says so
        _items.update { list -> list.map { if (it.state.isActive) it.copy(state = DownloadState.QUEUED) else it } }
        _paused.value = _items.value.any { it.state == DownloadState.QUEUED }
        workRoot.deleteRecursively()
    }

    val hasActiveDownloads get() = _items.value.any { it.state.isActive }

    /** How many downloads run at once (Settings › Downloads); the rest wait their turn. */
    var limit: Int
        get() = prefs.getInt(KEY_LIMIT, DEFAULT_LIMIT).coerceIn(1, MAX_LIMIT)
        set(value) {
            prefs.edit().putInt(KEY_LIMIT, value).apply()
            pump()
        }

    /** Settings › Downloads: each playlist in a folder of its own. */
    var playlistFolders: Boolean
        get() = prefs.getBoolean(KEY_PLAYLIST_FOLDERS, true)
        set(value) = prefs.edit().putBoolean(KEY_PLAYLIST_FOLDERS, value).apply()

    /** Settings › Subtitles: embed subtitles in videos, in the phone's languages ([subtitleLanguages]). */
    var subtitles: Boolean
        get() = prefs.getBoolean(KEY_SUBTITLES, false)
        set(value) = prefs.edit().putBoolean(KEY_SUBTITLES, value).apply()

    /** Settings › Subtitles: also the site's automatic captions, in the video's own language. */
    var autoCaptions: Boolean
        get() = prefs.getBoolean(KEY_AUTO_CAPTIONS, false)
        set(value) = prefs.edit().putBoolean(KEY_AUTO_CAPTIONS, value).apply()

    /** The playlist sheet's last quality, a [DownloadTarget.id]. */
    var playlistQuality: String
        get() = prefs.getString(KEY_PLAYLIST_QUALITY, null) ?: DownloadTarget.BEST.id
        set(value) = prefs.edit().putString(KEY_PLAYLIST_QUALITY, value).apply()

    /** A video with its download choices, or a playlist's items. */
    suspend fun fetch(url: String): FetchResult {
        val result = PythonBridge.call("extract", JSONObject().put("url", url).put("playlists", true))
        if (result.string("type") == "playlist") {
            val pageUrl = result.string("webpage_url") ?: url
            val entries = result.optJSONArray("entries")?.objects().orEmpty()
                .mapIndexed { i, entry -> PlaylistEntry.from(entry, i + 1, pageUrl) }
            return FetchResult.Playlist(
                PlaylistInfo(
                    id = result.string("id") ?: pageUrl,
                    url = pageUrl,
                    title = result.string("title") ?: "Playlist",
                    uploader = result.string("uploader"),
                    count = result.int("count"),
                    truncated = result.optBoolean("truncated"),
                    folder = result.string("folder"),
                    sections = result.optJSONArray("sections")?.strings().orEmpty(),
                    isMusic = result.optBoolean("music"),
                    entries = entries,
                ),
            )
        }
        val choices = result.optJSONArray("choices")?.objects()?.mapNotNull(FormatChoice::from).orEmpty()
        if (choices.isEmpty()) throw BridgeException("No downloadable formats found")
        val available = result.optJSONObject("subtitles")
        return FetchResult.Video(
            VideoInfo(
                url = result.string("webpage_url") ?: url,
                title = result.string("title") ?: "Untitled",
                uploader = result.string("uploader"),
                duration = result.optDouble("duration").takeUnless { it.isNaN() },
                thumbnail = result.string("thumbnail"),
                choices = choices,
                key = result.string("key"),
                playlistUrl = result.string("playlist_url"),
                subtitleLanguages = available?.optJSONArray("languages")?.strings().orEmpty(),
                captionLanguages = available?.optJSONArray("auto")?.strings().orEmpty(),
            ),
        )
    }

    fun download(info: VideoInfo, choice: FormatChoice) {
        val item = DownloadItem(
            id = UUID.randomUUID().toString(), sourceUrl = info.url, title = info.title,
            thumbnail = info.thumbnail, choice = choice, state = DownloadState.QUEUED,
            createdAt = System.currentTimeMillis(), key = info.key,
        )
        _items.update { listOf(item) + it }
        save(now = true)
        resume()
    }

    /** Queues the chosen items of a playlist, each at [target] quality. */
    fun download(entries: List<PlaylistEntry>, playlist: PlaylistInfo, target: DownloadTarget) {
        val folder = playlist.folder?.takeIf { playlistFolders }
        val added = System.currentTimeMillis()
        val new = entries.map { entry ->
            DownloadItem(
                id = UUID.randomUUID().toString(), sourceUrl = entry.url, title = entry.title,
                thumbnail = entry.thumbnail, choice = FormatChoice.placeholder(target), state = DownloadState.QUEUED,
                createdAt = added, key = entry.key, target = target, pick = entry.pick,
                playlist = PlaylistRef(playlist.id, playlist.title, entry.index, playlist.entries.size, folder),
            )
        }
        _items.update { new + it }
        save(now = true)
        resume()
    }

    fun retry(id: String) {
        update(id) { it.copy(state = DownloadState.QUEUED, error = null) }
        save()
        resume()
    }

    fun cancel(id: String) {
        val item = _items.value.firstOrNull { it.id == id } ?: return
        if (item.state == DownloadState.QUEUED) {
            // Not started (perform skips it if it was about to)
            update(id) { it.copy(state = DownloadState.CANCELLED) }
            save()
        } else if (id in running) {
            requeue -= id
            scope.launch { runCatching { PythonBridge.call("cancel", JSONObject().put("job_id", id)) } }
        }
    }

    /** Cancels what's left of the playlist batch [item] belongs to. */
    fun cancelRest(item: DownloadItem) {
        _items.value.filter { it.state.isActive && it.isInBatch(item) }.forEach { cancel(it.id) }
    }

    /** Cancels every waiting download (the paused queue's "Cancel All"). */
    fun cancelWaiting() {
        _items.update { list ->
            list.map { if (it.state == DownloadState.QUEUED && it.id !in running) it.copy(state = DownloadState.CANCELLED) else it }
        }
        _paused.value = false
        save()
    }

    /**
     * Starts waiting downloads again. Only for the user's own actions, as it starts the
     * foreground service, which Android 12+ doesn't allow from the background.
     */
    fun resume() {
        _paused.value = false
        if (hasActiveDownloads) DownloadService.start(app)
        pump()
    }

    /**
     * Android ended the service's time in the background: running downloads go back in the
     * queue (they'll start over) and the queue waits until the user resumes it in the app.
     */
    fun interrupt() {
        _paused.value = true
        for (id in running) {
            requeue += id
            scope.launch { runCatching { PythonBridge.call("cancel", JSONObject().put("job_id", id)) } }
        }
    }

    /** The finished download of the same video, for the format sheet's "Downloaded" notice. */
    fun downloaded(key: String?, url: String): DownloadItem? = _items.value.firstOrNull {
        it.state == DownloadState.FINISHED && (key != null && it.key == key || it.pick == null && it.sourceUrl == url)
    }

    /** What the playlist sheet needs to mark items: keys and links already downloaded, or waiting/running now. */
    fun library(): Library {
        val downloaded = mutableSetOf<String>()
        val active = mutableSetOf<String>()
        for (item in _items.value) {
            // Videos of one post share its link, so only their ids tell them apart
            val ids = listOfNotNull(item.key, item.sourceUrl.takeIf { item.pick == null })
            if (item.state.isActive) active += ids
            else if (item.state == DownloadState.FINISHED) downloaded += ids
        }
        return Library(downloaded, active)
    }

    data class Library(val downloaded: Set<String>, val active: Set<String>)

    /**
     * Removes the row and the saved file in Movies/Squirrel, Music/Squirrel or a chosen folder.
     *
     * Returns Android's delete prompt when the file was saved by an earlier install of the app,
     * which Android asks the user about first; call again once they approve. Null means done.
     */
    fun delete(id: String): IntentSender? {
        val item = _items.value.firstOrNull { it.id == id } ?: return null
        if (item.state.isActive) cancel(id)
        val uri = item.contentUri?.let(Uri::parse)
        if (uri != null && DocumentsContract.isDocumentUri(app, uri)) {
            // In a folder chosen in Settings › Advanced
            runCatching { DocumentsContract.deleteDocument(app.contentResolver, uri) }
        } else if (uri != null) {
            try {
                app.contentResolver.delete(uri, null, null)
            } catch (e: SecurityException) {
                if (Build.VERSION.SDK_INT >= 30) {
                    return MediaStore.createDeleteRequest(app.contentResolver, listOf(uri)).intentSender
                }
                if (e is RecoverableSecurityException) return e.userAction.actionIntent.intentSender
            } catch (e: Exception) {
                // Already gone, e.g. deleted in the Gallery
            }
        }
        removeRow(id)
        return null
    }

    private fun removeRow(id: String) {
        _items.update { list -> list.filterNot { it.id == id } }
        save()
    }

    // region Queue

    /**
     * Starts waiting downloads, oldest first, while fewer than the limit run. Never starts the
     * service: it also runs when a download ends with the app in the background.
     */
    private fun pump() {
        if (_paused.value) return
        while (running.size < limit) {
            val next = nextWaiting() ?: break
            running += next.id
            scope.launch(Dispatchers.Main) {
                try {
                    perform(next.id)
                } finally {
                    running -= next.id
                    pump()
                }
            }
        }
    }

    private fun nextWaiting(): DownloadItem? =
        _items.value.filter { it.state == DownloadState.QUEUED && it.id !in running }
            .minWithOrNull(compareBy({ it.createdAt }, { it.playlist?.index ?: 0 }))

    // endregion

    // region Pipeline

    private suspend fun perform(id: String) {
        val item = _items.value.firstOrNull { it.id == id } ?: return
        // Cancelled, or paused, while it was about to start
        if (item.state != DownloadState.QUEUED || _paused.value) return
        val workDir = File(workRoot, id)
        update(id) { it.copy(state = DownloadState.EXTRACTING) }
        _live.update { it + (id to LiveProgress(parts = maxOf(1, item.choice.formatIds.size))) }

        val poller = scope.launch {
            while (isActive) {
                delay(400)
                runCatching { PythonBridge.call("progress", JSONObject().put("job_id", id)) }
                    .onSuccess { apply(it, id) }
            }
        }

        val args = JSONObject().put("url", item.sourceUrl).put("out_dir", workDir.path).put("job_id", id)
        if (item.target != null) {
            // The bridge picks this video's choice for the playlist's quality
            args.put("target", item.target.toJson())
        } else {
            args.put("format_ids", JSONArray(item.choice.formatIds))
        }
        item.pick?.let { args.put("playlist_index", it) }
        // Settings › Subtitles. A playlist item's choice isn't known yet: the bridge skips them for audio.
        if (subtitles && (item.target != null || !item.choice.isAudio)) {
            args.put("subtitles", JSONObject().put("languages", JSONArray(subtitleLanguages)).put("auto", autoCaptions))
        }

        try {
            val result = PythonBridge.call("download", args)
            poller.cancel()
            val files = result.optJSONArray("files")?.strings()?.map(::File).orEmpty()
            if (files.isEmpty()) throw BridgeException("yt-dlp finished without producing a file")
            val title = result.string("title") ?: item.title
            // A playlist item's choice is only known now; it decides the container and where it's saved
            val choice = result.optJSONObject("choice")?.let(FormatChoice::from) ?: item.choice

            update(id) {
                it.copy(state = DownloadState.MERGING, title = title, choice = choice, key = result.string("key") ?: it.key)
            }
            val metadata = mapOf(
                "title" to title,
                "artist" to result.string("artist").orEmpty(),
                "date" to result.string("date").orEmpty(),
                "comment" to (result.string("url") ?: item.sourceUrl),
            )
            var finished: File
            if (choice.convert == "mp3") {
                // Re-encoded from the best audio, whatever its format
                finished = File(workDir, "final.mp3")
                Remuxer.writeMp3(files[0], finished, metadata)
            } else {
                // Merge or rewrap with FFmpeg into the container the format picker chose, with any subtitles
                val tracks = result.optJSONArray("subtitles")?.objects().orEmpty().mapNotNull { track ->
                    track.string("path")?.let { Remuxer.Subtitle(File(it), track.string("lang"), track.string("name")) }
                }
                val container = choice.ext?.takeIf(Remuxer::canWrite) ?: if (choice.isAudio) "m4a" else "mp4"
                finished = File(workDir, "final.$container")
                try {
                    Remuxer.write(files, finished, metadata, tracks)
                } catch (e: BridgeException) {
                    // A format FFmpeg can't rewrap: keep the single file exactly as downloaded
                    if (files.size != 1) throw e
                    finished = files[0]
                }
            }

            // The folder chosen in Settings › Advanced; Movies/ or Music/Squirrel if there's none or it's gone.
            // Inside it, the playlist's own folder when Settings › Downloads says so.
            val subfolder = item.playlist?.folder
            val folder = SaveLocations.folder(app, choice.isAudio)
            val inFolder = folder?.let {
                runCatching {
                    val destination = SaveLocations.destination(app, it.tree, subfolder)
                    withContext(Dispatchers.IO) { MediaStoreSaver.saveToFolder(app, destination, finished, title, choice.isAudio) }
                }.getOrNull()
            }
            val saved = inFolder
                ?: withContext(Dispatchers.IO) { MediaStoreSaver.save(app, finished, title, choice.isAudio, subfolder) }
            update(id) {
                it.copy(
                    state = DownloadState.FINISHED, contentUri = saved.uri, mimeType = saved.mimeType,
                    fileType = finished.extension.uppercase(), folderName = folder?.name?.takeIf { inFolder != null },
                )
            }
        } catch (e: BridgeException) {
            update(id) {
                when {
                    // Stopped by Android's time limit: it waits to start over
                    e.cancelled && id in requeue -> it.copy(state = DownloadState.QUEUED)
                    e.cancelled -> it.copy(state = DownloadState.CANCELLED)
                    else -> it.copy(state = DownloadState.FAILED, error = e.message)
                }
            }
        } catch (e: Exception) {
            update(id) { it.copy(state = DownloadState.FAILED, error = e.message ?: e.toString()) }
        } finally {
            poller.cancel()
            requeue -= id
            workDir.deleteRecursively()
            _live.update { it - id }
            save()
        }
    }

    private fun apply(progress: JSONObject, id: String) {
        val status = progress.string("status")
        _live.update { map ->
            val current = map[id] ?: return@update map
            map + (id to current.copy(
                downloaded = progress.optDouble("downloaded", 0.0),
                total = progress.optDouble("total", 0.0),
                speed = progress.optDouble("speed", 0.0),
                part = progress.optInt("part", current.part),
                parts = progress.optInt("parts", current.parts),
            ))
        }
        if (status == "downloading") {
            update(id) { if (it.state == DownloadState.EXTRACTING) it.copy(state = DownloadState.DOWNLOADING) else it }
        }
    }

    // endregion

    // region Persistence

    private fun update(id: String, transform: (DownloadItem) -> DownloadItem) {
        _items.update { list -> list.map { if (it.id == id) transform(it) else it } }
    }

    private fun load(): List<DownloadItem> {
        if (!libraryFile.exists()) return emptyList()
        return try {
            json.decodeFromString<List<DownloadItem>>(libraryFile.readText())
        } catch (e: Exception) {
            // Keep a copy rather than let the next save replace the whole list with nothing
            runCatching { libraryFile.copyTo(File(app.filesDir, "library.json.bak"), overwrite = true) }
            emptyList()
        }
    }

    /**
     * Writes the list shortly, once for a burst of changes (e.g. cancelling a whole playlist), or
     * [now] for new downloads, which must survive the app being swiped away straight after.
     */
    private fun save(now: Boolean = false) {
        saveJob?.cancel()
        saveJob = scope.launch {
            if (!now) delay(300)
            withContext(Dispatchers.IO) { write() }
        }
    }

    @Synchronized
    private fun write() {
        runCatching {
            val tmp = File(libraryFile.path + ".tmp")
            tmp.writeText(json.encodeToString(_items.value))
            tmp.renameTo(libraryFile)
        }
    }

    // endregion

    companion object {
        const val DEFAULT_LIMIT = 2
        const val MAX_LIMIT = 5
        private const val KEY_LIMIT = "limit"
        private const val KEY_PLAYLIST_FOLDERS = "playlistFolders"
        private const val KEY_PLAYLIST_QUALITY = "playlistQuality"
        private const val KEY_SUBTITLES = "subtitles"
        private const val KEY_AUTO_CAPTIONS = "autoCaptions"

        /**
         * "en", "pt": the languages in the phone's Settings › Languages, in order. From language
         * tags, as [Locale.getLanguage] still says "iw" for Hebrew and "in" for Indonesian.
         */
        val subtitleLanguages: List<String>
            get() {
                val locales = LocaleList.getDefault()
                val codes = List(locales.size()) { locales[it].toLanguageTag().substringBefore('-') }
                return codes.filter { it.isNotEmpty() && it != "und" }.distinct().ifEmpty { listOf("en") }
            }

        /** "English" for "en", in the phone's language */
        fun languageName(code: String): String = Locale.forLanguageTag(code).displayLanguage.ifEmpty { code }
    }
}

private fun JSONArray.objects() = List(length()) { getJSONObject(it) }
private fun JSONArray.strings() = List(length()) { getString(it) }
