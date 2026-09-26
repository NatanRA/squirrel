package app.squirrel.data

import android.content.Context
import app.squirrel.python.PythonBridge
import app.squirrel.python.string
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Keeps the embedded yt-dlp current by installing newer releases from PyPI
 * (shared/pybridge/ytdl_updater.py). Same behaviour as the iOS app: at most
 * once a day it silently stages an update, used from the next launch.
 */
class UpdateManager(context: Context, private val scope: CoroutineScope) {
    sealed interface Phase {
        data object Idle : Phase
        data object Checking : Phase
        data class Installing(val version: String) : Phase
        /** Installed on disk; used from the next launch. */
        data class Ready(val version: String) : Phase
        data class Failed(val message: String) : Phase
    }

    data class Status(
        val running: String? = null,
        val bundled: String? = null,
        val usingUpdate: Boolean = false,
        val loadError: String? = null,
    )

    private val prefs = context.getSharedPreferences("updates", Context.MODE_PRIVATE)

    private val _phase = MutableStateFlow<Phase>(Phase.Idle)
    val phase: StateFlow<Phase> = _phase
    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status
    private val _upToDate = MutableStateFlow(false)
    val upToDate: StateFlow<Boolean> = _upToDate

    val lastCheck: Long get() = prefs.getLong(KEY_LAST_CHECK, 0)

    var nightly: Boolean
        get() = prefs.getBoolean(KEY_NIGHTLY, false)
        set(value) {
            // Switching channel takes effect without waiting a day
            prefs.edit().putBoolean(KEY_NIGHTLY, value).remove(KEY_LAST_CHECK).apply()
            scope.launch { autoUpdateIfDue() }
        }

    private val isBusy get() = _phase.value is Phase.Checking || _phase.value is Phase.Installing

    suspend fun refreshStatus() {
        val status = runCatching { PythonBridge.call("update_status") }.getOrNull() ?: return
        val running = status.string("version")
        _status.value = Status(
            running = running,
            bundled = status.string("bundled_version"),
            usingUpdate = status.string("source") == "update",
            loadError = status.string("load_error"),
        )
        val pending = status.string("pending_version")
        if (pending != null && normalized(pending) != normalized(running)) _phase.value = Phase.Ready(pending)
    }

    /** Checks at most once a day; safe to call on every launch and resume. */
    suspend fun autoUpdateIfDue() {
        if (isBusy || System.currentTimeMillis() - lastCheck < 24 * 3600 * 1000L) return
        update(manual = false)
    }

    suspend fun checkNow() {
        if (isBusy) return
        prefs.edit().remove(KEY_SKIPPED).apply()
        update(manual = true)
    }

    /** Removes any downloaded update; the built-in version is used from the next launch. */
    suspend fun revertToBundled() {
        val phase = _phase.value
        val reverted = if (phase is Phase.Ready) phase.version else _status.value.running.takeIf { _status.value.usingUpdate }
        runCatching { PythonBridge.call("remove_update") }
        // Otherwise the next automatic check would reinstall the same version
        reverted?.let { prefs.edit().putString(KEY_SKIPPED, normalized(it)).apply() }
        _status.value = _status.value.copy(loadError = null)
        _upToDate.value = false
        _phase.value = if (_status.value.usingUpdate) Phase.Ready(_status.value.bundled ?: "built-in") else Phase.Idle
    }

    private suspend fun update(manual: Boolean) {
        val previous = _phase.value
        _phase.value = Phase.Checking
        _upToDate.value = false
        try {
            val result = PythonBridge.call("check_update", JSONObject().put("nightly", nightly))
            val latest = result.string("latest")
            val skipped = prefs.getString(KEY_SKIPPED, null)
            if (!result.optBoolean("available") || latest == null || (!manual && normalized(latest) == skipped)) {
                prefs.edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis()).apply()
                _upToDate.value = manual
                _phase.value = if (previous is Phase.Checking) Phase.Idle else previous
                return
            }
            _phase.value = Phase.Installing(latest)
            PythonBridge.call("install_update", JSONObject().put("version", latest))
            // Recorded only once installed, so a failed download is retried next launch
            prefs.edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis()).apply()
            _phase.value = Phase.Ready(latest)
        } catch (e: Exception) {
            _phase.value = if (manual) Phase.Failed(e.message ?: "Update failed") else previous
        }
    }

    companion object {
        private const val KEY_NIGHTLY = "nightly"
        private const val KEY_LAST_CHECK = "lastCheck"
        private const val KEY_SKIPPED = "skippedVersion"

        /** "2026.9.16.232951.dev0" -> "2026.9.16 (nightly)" */
        fun display(version: String): String {
            val parts = version.split('.')
            return if (parts.size > 3) parts.take(3).joinToString(".") + " (nightly)" else version
        }

        /** yt-dlp's own version strings zero-pad ("2026.08.19"), PyPI's don't. */
        fun normalized(version: String?): String =
            version.orEmpty().split('.').mapNotNull { it.toIntOrNull()?.toString() }.joinToString(".")
    }
}
