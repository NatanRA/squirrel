package com.natan.ytdlp

import com.natan.ytdlp.python.BridgeException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Kotlin face of shared/native/Remux.c (embedded FFmpeg, remux only). Merges
 * yt-dlp's separate video/audio downloads and rewraps single files into a
 * clean container with correct duration headers.
 */
object Remuxer {
    init {
        System.loadLibrary("ytdlremux")
    }

    /** FFmpeg muxer for each output extension the app writes. */
    private val muxers = mapOf(
        "mp4" to "mp4", "m4a" to "ipod", "mov" to "mov", "mkv" to "matroska", "webm" to "webm",
        "mp3" to "mp3", "ogg" to "ogg", "opus" to "ogg", "flac" to "flac",
    )

    fun canWrite(ext: String) = ext.lowercase() in muxers

    suspend fun write(inputs: List<File>, output: File, metadata: Map<String, String> = emptyMap()) =
        withContext(Dispatchers.IO) {
            val muxer = muxers[output.extension.lowercase()]
                ?: throw BridgeException("Can't write .${output.extension} files")
            val tags = metadata.filterValues { it.isNotEmpty() }.flatMap { listOf(it.key, it.value) }
            remux(inputs.map { it.path }.toTypedArray(), output.path, muxer, tags.toTypedArray())
                ?.let { throw BridgeException("Couldn't finish the file: $it") }
        }

    /** See android/app/src/main/cpp/jni_remux.c. Returns an error message, or null. */
    @JvmStatic
    private external fun remux(inputs: Array<String>, output: String, muxer: String, metadata: Array<String>): String?
}
