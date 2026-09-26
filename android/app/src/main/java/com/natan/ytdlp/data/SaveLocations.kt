package com.natan.ytdlp.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract

/**
 * Settings › Advanced › Save Locations: folders picked with the system file picker that
 * replace Movies/Squirrel and Music/Squirrel.
 */
object SaveLocations {
    data class Folder(val tree: Uri, val name: String)

    private fun prefs(context: Context) = context.getSharedPreferences("save", Context.MODE_PRIVATE)

    private fun key(isAudio: Boolean) = if (isAudio) "audioFolder" else "videoFolder"

    /** Null means the default: Movies/Squirrel for videos, Music/Squirrel for audio. */
    fun folder(context: Context, isAudio: Boolean): Folder? {
        val prefs = prefs(context)
        val tree = prefs.getString(key(isAudio), null) ?: return null
        return Folder(Uri.parse(tree), prefs.getString(key(isAudio) + ".name", null) ?: "Folder")
    }

    /** Remembers a folder from the picker, or goes back to the default with null. */
    fun set(context: Context, isAudio: Boolean, tree: Uri?) {
        val key = key(isAudio)
        if (tree == null) {
            prefs(context).edit().remove(key).remove("$key.name").apply()
            return
        }
        // Keeps access after restarts. It's never released: downloads saved there still need it.
        context.contentResolver.takePersistableUriPermission(
            tree, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        prefs(context).edit().putString(key, tree.toString()).putString("$key.name", displayName(context, tree)).apply()
    }

    private fun displayName(context: Context, tree: Uri): String {
        val folder = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return context.contentResolver.query(folder, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Folder"
    }
}
