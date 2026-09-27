package app.squirrel.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Settings › Advanced › Save Locations: folders picked with the system file picker that
 * replace Movies/Squirrel and Music/Squirrel.
 */
object SaveLocations {
    data class Folder(val tree: Uri, val name: String)

    private val subfolderLock = Mutex()
    /** Playlist folders found or made so far, by chosen folder and name */
    private val subfolders = mutableMapOf<Pair<Uri, String>, Uri>()

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

    /**
     * The chosen folder, or the folder named [subfolder] inside it (a playlist's own), made when
     * it isn't there yet. One at a time, so a playlist's parallel downloads share one rather
     * than each making its own ("Name (1)").
     */
    suspend fun destination(context: Context, tree: Uri, subfolder: String?): Uri {
        if (subfolder == null) return root(tree)
        val name = MediaStoreSaver.safeName(subfolder)
        return subfolderLock.withLock {
            withContext(Dispatchers.IO) {
                subfolders[tree to name]?.takeIf { exists(context, it) }
                    ?: (find(context, tree, name) ?: create(context, tree, name)).also { subfolders[tree to name] = it }
            }
        }
    }

    private fun root(tree: Uri) = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun find(context: Context, tree: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        context.contentResolver.query(children, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name && cursor.getString(2) == Document.MIME_TYPE_DIR) {
                    return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                }
            }
        }
        return null
    }

    private fun create(context: Context, tree: Uri, name: String): Uri =
        DocumentsContract.createDocument(context.contentResolver, root(tree), Document.MIME_TYPE_DIR, name)
            ?: error("Couldn't create the folder “$name”")

    /** False once it's deleted, e.g. in the Files app */
    private fun exists(context: Context, document: Uri): Boolean = runCatching {
        context.contentResolver.query(document, arrayOf(Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { it.count > 0 }
    }.getOrNull() == true

    private fun displayName(context: Context, tree: Uri): String =
        context.contentResolver.query(root(tree), arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Folder"
}
