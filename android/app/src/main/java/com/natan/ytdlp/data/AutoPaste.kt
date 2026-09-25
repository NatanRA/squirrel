package com.natan.ytdlp.data

import android.content.ClipboardManager
import android.content.Context

/**
 * Settings › Pasting › Auto-Paste Copied Links: opening the app with a newly
 * copied link pastes it and looks it up, so the format sheet is one tap from a download.
 */
object AutoPaste {
    private const val KEY_ENABLED = "enabled"
    private const val KEY_LAST_CLIP = "lastClip"

    private fun prefs(context: Context) = context.getSharedPreferences("paste", Context.MODE_PRIVATE)

    fun isEnabled(context: Context) = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    /**
     * The copied link, if the clipboard changed since the last check and holds one.
     * Android 10+ only shares the clipboard with the app in focus, so call this once the window has focus.
     */
    fun newLink(context: Context): String? {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return null
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        // Every copy gets a new timestamp, so each copied link is pasted once. Checking it doesn't
        // read the clip, which is what shows Android's "pasted from your clipboard" notice.
        val description = clipboard.primaryClipDescription ?: return null
        if (description.timestamp == prefs.getLong(KEY_LAST_CLIP, 0)) return null
        prefs.edit().putLong(KEY_LAST_CLIP, description.timestamp).apply()
        if (!description.hasMimeType("text/*")) return null
        val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context) ?: return null
        return Regex("https?://\\S+").find(text)?.value
    }

    /** Skips what's on the clipboard now, e.g. a link Squirrel copied itself. */
    fun markSeen(context: Context) {
        val description = context.getSystemService(ClipboardManager::class.java).primaryClipDescription ?: return
        prefs(context).edit().putLong(KEY_LAST_CLIP, description.timestamp).apply()
    }
}
