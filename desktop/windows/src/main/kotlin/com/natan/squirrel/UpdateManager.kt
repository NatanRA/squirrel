package com.natan.squirrel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Keeps the engine's yt-dlp current by installing newer releases from PyPI
 * (see ytdl_updater.py), like the other apps. At most once a day it checks,
 * downloads and stages an update; restarting the engine puts it to use.
 */
object UpdateManager {
    sealed interface Phase {
        data object Idle : Phase
        data object Checking : Phase
        data class Installing(val version: String) : Phase
        /** Installed on disk; used once the engine restarts. */
        data class Ready(val version: String) : Phase
        data class Failed(val message: String) : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Idle)
        private set
    var runningVersion by mutableStateOf<String?>(null)
        private set
    var bundledVersion by mutableStateOf<String?>(null)
        private set
    var isUsingUpdate by mutableStateOf(false)
        private set
    /** Set when an installed update failed to import and was disabled. */
    var loadError by mutableStateOf<String?>(null)
        private set
    /** Whether the last manual check found nothing newer. */
    var isUpToDate by mutableStateOf(false)
        private set

    val lastCheck: Long get() = Preferences[LAST_CHECK]?.toLongOrNull() ?: 0

    var nightly by mutableStateOf(Preferences[NIGHTLY] == "true")
        private set

    private const val NIGHTLY = "updates.nightly"
    private const val LAST_CHECK = "updates.lastCheck"
    /** A version the user reverted; not reinstalled automatically. */
    private const val SKIPPED = "updates.skippedVersion"

    private val isBusy get() = phase is Phase.Checking || phase is Phase.Installing

    suspend fun setNightly(value: Boolean) {
        nightly = value
        Preferences[NIGHTLY] = value.toString()
        // Switching channel should take effect without waiting a day
        Preferences[LAST_CHECK] = null
        autoUpdateIfDue()
    }

    suspend fun refreshStatus() {
        val status = runCatching { Engine.call("update_status") }.getOrNull() ?: return
        runningVersion = status.string("version")
        bundledVersion = status.string("bundled_version")
        isUsingUpdate = status.string("source") == "update"
        loadError = status.string("load_error")
        val pending = status.string("pending_version")
        if (pending != null && normalized(pending) != normalized(runningVersion)) {
            phase = Phase.Ready(pending)
        } else if (phase is Phase.Ready) {
            phase = Phase.Idle
        }
    }

    /** Checks at most once a day. */
    suspend fun autoUpdateIfDue() {
        if (isBusy || System.currentTimeMillis() - lastCheck < 24 * 3600 * 1000L) return
        update(manual = false)
    }

    suspend fun checkNow() {
        if (isBusy) return
        Preferences[SKIPPED] = null
        update(manual = true)
    }

    /** Starts a fresh engine so a staged update (or a revert) takes effect. */
    suspend fun restartEngine() {
        Engine.restart()
        refreshStatus()
    }

    suspend fun revertToBundled() {
        val reverted = (phase as? Phase.Ready)?.version ?: runningVersion.takeIf { isUsingUpdate }
        runCatching { Engine.call("remove_update") }
        reverted?.let { Preferences[SKIPPED] = normalized(it) }
        loadError = null
        isUpToDate = false
        phase = if (isUsingUpdate) Phase.Ready(bundledVersion ?: "built-in") else Phase.Idle
    }

    private suspend fun update(manual: Boolean) {
        val previous = phase
        phase = Phase.Checking
        isUpToDate = false
        try {
            val result = Engine.call("check_update", jsonOf("nightly" to nightly))
            val latest = result.string("latest")
            if (result.bool("available") != true || latest == null || (!manual && normalized(latest) == Preferences[SKIPPED])) {
                Preferences[LAST_CHECK] = System.currentTimeMillis().toString()
                isUpToDate = manual
                phase = if (previous == Phase.Checking) Phase.Idle else previous
                return
            }
            phase = Phase.Installing(latest)
            Engine.call("install_update", jsonOf("version" to latest))
            Preferences[LAST_CHECK] = System.currentTimeMillis().toString()
            phase = Phase.Ready(latest)
        } catch (e: Exception) {
            phase = if (manual) Phase.Failed(e.message ?: e.toString()) else previous
        }
    }

    /** "2026.9.16.232951.dev0" -> "2026.9.16 (nightly)" */
    fun display(version: String): String {
        val parts = version.split('.')
        return if (parts.size > 3) parts.take(3).joinToString(".") + " (nightly)" else version
    }

    /** yt-dlp's own version strings zero-pad ("2026.08.19"), PyPI's don't. */
    fun normalized(version: String?): String =
        version.orEmpty().split('.').mapNotNull { it.toIntOrNull() }.joinToString(".")
}
