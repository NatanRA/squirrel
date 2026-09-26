package com.natan.ytdlp.data

import android.app.Application
import android.app.RecoverableSecurityException
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.natan.ytdlp.Remuxer
import com.natan.ytdlp.python.BridgeException
import com.natan.ytdlp.python.PythonBridge
import com.natan.ytdlp.python.string
import com.natan.ytdlp.service.DownloadService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** The download list and pipeline: yt-dlp download -> FFmpeg remux -> shared storage. */
class DownloadRepository(private val app: Application, private val scope: CoroutineScope) {
    private val libraryFile = File(app.filesDir, "library.json")
    private val workRoot = File(app.cacheDir, "work")
    private val json = Json { ignoreUnknownKeys = true }

    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<DownloadItem>> = _items

    private val _live = MutableStateFlow<Map<String, LiveProgress>>(emptyMap())
    val live: StateFlow<Map<String, LiveProgress>> = _live

    private val jobs = ConcurrentHashMap<String, Job>()

    init {
        // Anything that was running when the process died can't be resumed
        _items.update { list ->
            list.map { if (it.state.isActive) it.copy(state = DownloadState.FAILED, error = "Interrupted") else it }
        }
        workRoot.deleteRecursively()
    }

    val hasActiveDownloads get() = _items.value.any { it.state.isActive }

    suspend fun fetchInfo(url: String): VideoInfo {
        val result = PythonBridge.call("extract", JSONObject().put("url", url))
        val choices = result.optJSONArray("choices")?.objects()?.mapNotNull(FormatChoice::from).orEmpty()
        if (choices.isEmpty()) throw BridgeException("No downloadable formats found")
        return VideoInfo(
            url = result.string("webpage_url") ?: url,
            title = result.string("title") ?: "Untitled",
            uploader = result.string("uploader"),
            duration = result.optDouble("duration").takeUnless { it.isNaN() },
            thumbnail = result.string("thumbnail"),
            choices = choices,
        )
    }

    fun download(info: VideoInfo, choice: FormatChoice) {
        val item = DownloadItem(
            id = UUID.randomUUID().toString(), sourceUrl = info.url, title = info.title,
            thumbnail = info.thumbnail, choice = choice, state = DownloadState.QUEUED,
            createdAt = System.currentTimeMillis(),
        )
        _items.update { listOf(item) + it }
        save()
        run(item.id)
    }

    fun retry(id: String) {
        update(id) { it.copy(state = DownloadState.QUEUED, error = null) }
        run(id)
    }

    fun cancel(id: String) {
        scope.launch { runCatching { PythonBridge.call("cancel", JSONObject().put("job_id", id)) } }
    }

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

    // region Pipeline

    private fun run(id: String) {
        jobs[id] = scope.launch { perform(id) }
        DownloadService.start(app)
    }

    private suspend fun perform(id: String) {
        val item = _items.value.firstOrNull { it.id == id } ?: return
        val workDir = File(workRoot, id)
        update(id) { it.copy(state = DownloadState.EXTRACTING) }
        _live.update { it + (id to LiveProgress(parts = item.choice.formatIds.size)) }

        val poller = scope.launch {
            while (isActive) {
                delay(400)
                runCatching { PythonBridge.call("progress", JSONObject().put("job_id", id)) }
                    .onSuccess { apply(it, id) }
            }
        }

        try {
            val result = PythonBridge.call(
                "download",
                JSONObject()
                    .put("url", item.sourceUrl)
                    .put("format_ids", JSONArray(item.choice.formatIds))
                    .put("out_dir", workDir.path)
                    .put("job_id", id),
            )
            poller.cancel()
            val files = result.optJSONArray("files")?.strings()?.map(::File).orEmpty()
            if (files.isEmpty()) throw BridgeException("yt-dlp finished without producing a file")
            val title = result.string("title") ?: item.title

            // Merge or rewrap with FFmpeg into the container the format picker chose
            update(id) { it.copy(state = DownloadState.MERGING, title = title) }
            val container = item.choice.ext?.takeIf(Remuxer::canWrite) ?: if (item.choice.isAudio) "m4a" else "mp4"
            var finished = File(workDir, "final.$container")
            try {
                Remuxer.write(
                    files, finished,
                    mapOf(
                        "title" to title,
                        "artist" to result.string("artist").orEmpty(),
                        "date" to result.string("date").orEmpty(),
                        "comment" to (result.string("url") ?: item.sourceUrl),
                    ),
                )
            } catch (e: BridgeException) {
                // A format FFmpeg can't rewrap: keep the single file exactly as downloaded
                if (files.size != 1) throw e
                finished = files[0]
            }

            // The folder chosen in Settings › Advanced; Movies/ or Music/Squirrel if there's none or it's gone
            val folder = SaveLocations.folder(app, item.choice.isAudio)
            val inFolder = folder?.let {
                runCatching { MediaStoreSaver.saveToFolder(app, it.tree, finished, title, item.choice.isAudio) }.getOrNull()
            }
            val saved = inFolder ?: MediaStoreSaver.save(app, finished, title, item.choice.isAudio)
            update(id) {
                it.copy(
                    state = DownloadState.FINISHED, contentUri = saved.uri, mimeType = saved.mimeType,
                    fileType = finished.extension.uppercase(), folderName = folder?.name?.takeIf { inFolder != null },
                )
            }
        } catch (e: BridgeException) {
            update(id) {
                if (e.cancelled) it.copy(state = DownloadState.CANCELLED)
                else it.copy(state = DownloadState.FAILED, error = e.message)
            }
        } catch (e: Exception) {
            update(id) { it.copy(state = DownloadState.FAILED, error = e.message ?: e.toString()) }
        } finally {
            poller.cancel()
            workDir.deleteRecursively()
            _live.update { it - id }
            jobs.remove(id)
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

    private fun load(): List<DownloadItem> = runCatching {
        json.decodeFromString<List<DownloadItem>>(libraryFile.readText())
    }.getOrDefault(emptyList())

    @Synchronized
    private fun save() {
        runCatching {
            val tmp = File(libraryFile.path + ".tmp")
            tmp.writeText(json.encodeToString(_items.value))
            tmp.renameTo(libraryFile)
        }
    }

    // endregion
}

private fun JSONArray.objects() = List(length()) { getJSONObject(it) }
private fun JSONArray.strings() = List(length()) { getString(it) }
