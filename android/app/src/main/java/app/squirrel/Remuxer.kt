package app.squirrel

import app.squirrel.python.BridgeException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Kotlin face of shared/native/Remux.c (embedded FFmpeg, plus LAME for MP3s). Merges
 * yt-dlp's separate video/audio downloads, adding any subtitles, and rewraps single files
 * into a clean container with correct duration headers. Also converts audio to MP3.
 */
object Remuxer {
    init {
        System.loadLibrary("ytdlremux")
    }

    /** A WebVTT or SubRip file to add as a track, as the bridge's `download` lists them. */
    data class Subtitle(val file: File, val language: String?, val name: String?)

    /** FFmpeg muxer for each output extension the app writes. */
    private val muxers = mapOf(
        "mp4" to "mp4", "m4a" to "ipod", "mov" to "mov", "mkv" to "matroska", "webm" to "webm",
        "mp3" to "mp3", "ogg" to "ogg", "opus" to "ogg", "flac" to "flac",
    )

    fun canWrite(ext: String) = ext.lowercase() in muxers

    /** [subtitles] only go with a video; one that can't be read is left out. */
    suspend fun write(
        inputs: List<File>, output: File, metadata: Map<String, String> = emptyMap(), subtitles: List<Subtitle> = emptyList(),
    ) = withContext(Dispatchers.IO) {
        val muxer = muxers[output.extension.lowercase()]
            ?: throw BridgeException("Can't write .${output.extension} files")
        remux(
            inputs.map { it.path }.toTypedArray(),
            subtitles.map { it.file.path }.toTypedArray(),
            subtitles.map { it.language }.toTypedArray(),
            subtitles.map { it.name }.toTypedArray(),
            output.path, muxer, tags(metadata),
        )?.let { throw BridgeException("Couldn't finish the file: $it") }
    }

    /** Re-encodes the first audio track of [input] as an MP3 at [output]. */
    suspend fun writeMp3(input: File, output: File, metadata: Map<String, String> = emptyMap()) =
        withContext(Dispatchers.IO) {
            convertToMp3(input.path, output.path, tags(metadata))
                ?.let { throw BridgeException("Couldn't make the MP3: $it") }
        }

    private fun tags(metadata: Map<String, String>) =
        metadata.filterValues { it.isNotEmpty() }.flatMap { listOf(it.key, it.value) }.toTypedArray()

    /** See android/app/src/main/cpp/jni_remux.c. Returns an error message, or null. */
    @JvmStatic
    private external fun remux(
        inputs: Array<String>, subtitles: Array<String>, languages: Array<String?>, titles: Array<String?>,
        output: String, muxer: String, metadata: Array<String>,
    ): String?

    @JvmStatic
    private external fun convertToMp3(input: String, output: String, metadata: Array<String>): String?
}
