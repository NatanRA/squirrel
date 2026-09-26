package app.squirrel.data

import android.text.format.Formatter
import kotlinx.serialization.Serializable
import app.squirrel.python.string
import org.json.JSONObject

/** One entry of the format picker, built by the shared bridge's `_presets`. */
@Serializable
data class FormatChoice(
    val id: String,
    val label: String,
    val detail: String,
    val formatIds: List<String>,
    val kind: String,
    /** Output container, e.g. "mp4" or "m4a". */
    val ext: String? = null,
    /** False when the platform's own players can't play it. */
    val playable: Boolean? = null,
) {
    val isAudio get() = kind == "audio"

    companion object {
        fun from(json: JSONObject): FormatChoice? {
            val ids = json.optJSONArray("format_ids") ?: return null
            return FormatChoice(
                id = json.optString("id"),
                label = json.optString("label"),
                detail = json.optString("detail"),
                formatIds = List(ids.length()) { ids.getString(it) },
                kind = json.optString("kind", "video"),
                ext = json.string("ext"),
                playable = if (json.has("playable")) json.optBoolean("playable") else null,
            )
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
enum class DownloadState {
    QUEUED, EXTRACTING, DOWNLOADING, MERGING, FINISHED, FAILED, CANCELLED;

    val isActive get() = this in setOf(QUEUED, EXTRACTING, DOWNLOADING, MERGING)
}

@Serializable
data class DownloadItem(
    val id: String,
    val sourceUrl: String,
    val title: String,
    val thumbnail: String?,
    val choice: FormatChoice,
    val state: DownloadState,
    val error: String? = null,
    /** MediaStore entry in Movies/Squirrel or Music/Squirrel, or a document in [folderName]. */
    val contentUri: String? = null,
    val mimeType: String? = null,
    val fileType: String? = null,
    /** Set when the file went to a folder chosen in Settings › Advanced. */
    val folderName: String? = null,
    val createdAt: Long,
)

/** Live, non-persisted progress for an active download. */
data class LiveProgress(
    val downloaded: Double = 0.0,
    val total: Double = 0.0,
    val speed: Double = 0.0,
    val part: Int = 1,
    val parts: Int = 1,
) {
    val fraction: Float?
        get() = if (total > 0) ((part - 1 + minOf(downloaded / total, 1.0)) / maxOf(parts, 1)).toFloat() else null

    /** "Video · 12.3 MB of 45 MB · 2.1 MB/s" */
    fun summary(context: android.content.Context): String = buildList {
        if (parts > 1) add(if (part == 1) "Video" else "Audio")
        val bytes = Formatter.formatShortFileSize(context, downloaded.toLong())
        add(if (total > 0) "$bytes of ${Formatter.formatShortFileSize(context, total.toLong())}" else bytes)
        if (speed > 0) add("${Formatter.formatShortFileSize(context, speed.toLong())}/s")
    }.joinToString(" · ")
}
