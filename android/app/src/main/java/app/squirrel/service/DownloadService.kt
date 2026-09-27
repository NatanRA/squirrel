package app.squirrel.service

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.squirrel.App
import app.squirrel.MainActivity
import app.squirrel.R
import app.squirrel.data.DownloadItem
import app.squirrel.data.DownloadState
import app.squirrel.data.LiveProgress
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps the process alive while downloads run or wait their turn, so they continue when the
 * app is in the background, and shows their progress as a notification. The downloads
 * themselves run in DownloadRepository.
 */
class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var collector: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification("Starting download…", null),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (e: IllegalStateException) {
            // Android 15+ once today's time in the background is used up (see onTimeout): the
            // downloads still run while the app is open
            if (Build.VERSION.SDK_INT < 31 || e !is ForegroundServiceStartNotAllowedException) throw e
            stopSelf()
            return START_NOT_STICKY
        }
        val repository = App.instance.repository
        collector?.cancel()
        collector = scope.launch {
            combine(repository.items, repository.live, repository.paused) { items, live, paused ->
                Triple(items, live, paused)
            }.collect { (items, live, paused) ->
                val running = items.filter { it.state.isActive && it.state != DownloadState.QUEUED }
                val waiting = items.count { it.state == DownloadState.QUEUED }
                if (running.isEmpty() && (waiting == 0 || paused)) {
                    stop()
                    return@collect
                }
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(NOTIFICATION_ID, progress(items, running, waiting, live))
                // Android drops updates that come faster than a few a second, as several downloads' progress would
                delay(500)
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Android 15+ allows a data sync service 6 hours in the background a day. Once they're up,
     * running downloads go back in the queue, paused until the user opens the app and resumes.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        App.instance.repository.interrupt()
        stop()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun stop() {
        collector?.cancel()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * One download: its title and progress. A playlist: how far along it is ("Downloading 3 of 42").
     * Anything else: how many run and wait ("2 downloading · 5 waiting").
     */
    private fun progress(
        items: List<DownloadItem>, running: List<DownloadItem>, waiting: Int, live: Map<String, LiveProgress>,
    ): Notification {
        val first = running.firstOrNull() ?: return notification("Starting download…", null)
        val active = items.filter { it.state.isActive }
        val playlist = first.playlist
        if (playlist != null && active.all { it.isInBatch(first) }) {
            val batch = items.filter { it.isInBatch(first) }
            val done = batch.count { !it.state.isActive }
            val started = running.sumOf { (live[it.id]?.fraction ?: 0f).toDouble() }.toFloat()
            return notification(
                playlist.title, "Downloading ${minOf(done + running.size, batch.size)} of ${batch.size}",
                (done + started) / batch.size,
            )
        }
        if (active.size == 1) {
            val progress = live[first.id]
            return notification(first.title, status(first, progress), progress?.fraction)
        }
        val fractions = running.mapNotNull { live[it.id]?.fraction }
        return notification(
            "Downloading ${active.size} items",
            listOfNotNull("${running.size} downloading", "$waiting waiting".takeIf { waiting > 0 }).joinToString(" · "),
            if (fractions.size == running.size) fractions.sum() / fractions.size else null,
        )
    }

    private fun status(item: DownloadItem, progress: LiveProgress?) = when (item.state) {
        DownloadState.MERGING -> "Finishing…"
        DownloadState.DOWNLOADING -> progress?.summary(this) ?: "Downloading…"
        else -> "Preparing…"
    }

    private fun notification(title: String, text: String?, fraction: Float? = null) =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setProgress(1000, ((fraction ?: 0f) * 1000).toInt(), fraction == null)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 1

        /** Call only from what the user does in the app: Android 12+ refuses it from the background. */
        fun start(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW),
            )
            try {
                ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))
            } catch (e: IllegalStateException) {
                // E.g. the app went to the background just as the user tapped: the downloads
                // still run, only without the notification keeping them alive
                if (Build.VERSION.SDK_INT < 31 || e !is ForegroundServiceStartNotAllowedException) throw e
            }
        }
    }
}
