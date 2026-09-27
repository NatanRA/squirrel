package app.squirrel.data

import android.text.format.Formatter
import kotlinx.serialization.Serializable
import app.squirrel.python.int
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
        /** Stands in for a playlist item's choice until the bridge picks one from the video's formats. */
        fun placeholder(target: DownloadTarget) =
            FormatChoice(id = "target", label = target.label, detail = "", formatIds = emptyList(), kind = target.kind)

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

/**
 * A playlist's quality: the best version up to a height, or just the audio. The bridge turns it
 * into one of each video's own choices when that video downloads.
 */
@Serializable
data class DownloadTarget(val kind: String, val maxHeight: Int? = null) {
    val id get() = if (kind == "audio") "audio" else maxHeight?.let { "v$it" } ?: "best"
    val label get() = if (kind == "audio") "Audio" else maxHeight?.let { "${it}p" } ?: "Best"

    fun toJson(): JSONObject = JSONObject().put("kind", kind).apply { maxHeight?.let { put("max_height", it) } }

    companion object {
        val BEST = DownloadTarget("video")
        val AUDIO = DownloadTarget("audio")
        val ALL = listOf(BEST, DownloadTarget("video", 1080), DownloadTarget("video", 720), DownloadTarget("video", 480), AUDIO)
    }
}

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
)

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
        fun from(json: JSONObject, index: Int, fallbackUrl: String) = PlaylistEntry(
            index = json.int("index") ?: index,
            key = json.string("key"),
            title = json.string("title") ?: "Item $index",
            duration = json.optDouble("duration").takeUnless { it.isNaN() },
            thumbnail = json.string("thumbnail"),
            url = json.string("url") ?: fallbackUrl,
            pick = json.int("pick"),
            section = json.string("section"),
            unavailable = json.optBoolean("unavailable"),
            live = json.optBoolean("live"),
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
)

/** What a pasted link turned out to be */
sealed interface FetchResult {
    data class Video(val info: VideoInfo) : FetchResult
    data class Playlist(val playlist: PlaylistInfo) : FetchResult
}

@Serializable
enum class DownloadState {
    QUEUED, EXTRACTING, DOWNLOADING, MERGING, FINISHED, FAILED, CANCELLED;

    /** Waiting or running */
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
    // Null in libraries saved by older versions
    val key: String? = null,
    /** A playlist item's quality; [choice] becomes the resolved choice once it downloads */
    val target: DownloadTarget? = null,
    val pick: Int? = null,
    val playlist: PlaylistRef? = null,
) {
    /** Downloads added together from one playlist */
    fun isInBatch(other: DownloadItem) =
        playlist != null && playlist.id == other.playlist?.id && createdAt == other.createdAt
}

/** Which playlist a download came from, and where in it */
@Serializable
data class PlaylistRef(
    val id: String,
    val title: String,
    val index: Int,
    val count: Int,
    /** Saved in a folder with this name inside Movies/Squirrel, Music/Squirrel or the chosen folder */
    val folder: String? = null,
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
