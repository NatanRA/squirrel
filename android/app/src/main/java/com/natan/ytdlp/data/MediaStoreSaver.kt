package com.natan.ytdlp.data

import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import java.io.File

/**
 * Publishes finished downloads to shared storage: videos to Movies/yt-dlp
 * (shown in the Gallery and Google Photos), audio to Music/yt-dlp (shown in
 * music players). No storage permission is needed for files the app creates.
 */
object MediaStoreSaver {
    data class Saved(val uri: String, val mimeType: String)

    fun save(context: Context, file: File, title: String, isAudio: Boolean): Saved {
        val ext = file.extension.lowercase()
        val mime = mimeType(ext, isAudio)
        val collection = if (isAudio) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "${safeName(title)}.$ext")
            put(MediaStore.MediaColumns.TITLE, title)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, if (isAudio) "Music/yt-dlp" else "Movies/yt-dlp")
            put(MediaStore.MediaColumns.IS_PENDING, 1)  // hidden until fully written
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(collection, values) ?: error("Couldn't create the file in shared storage")
        try {
            resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return Saved(uri.toString(), mime)
    }

    private fun mimeType(ext: String, isAudio: Boolean): String = when {
        isAudio && ext == "m4a" -> "audio/mp4"
        isAudio && ext == "webm" -> "audio/webm"
        isAudio && ext in setOf("ogg", "opus") -> "audio/ogg"
        !isAudio && ext == "mkv" -> "video/x-matroska"
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: if (isAudio) "audio/mp4" else "video/mp4"
    }

    /** Keeps names valid on every filesystem; MediaStore adds " (1)" on clashes. */
    private fun safeName(title: String): String =
        title.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ").trim().trim('.').take(120).ifEmpty { "Download" }
}
