package com.natan.ytdlp.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.natan.ytdlp.App
import com.natan.ytdlp.MainActivity
import com.natan.ytdlp.R
import com.natan.ytdlp.data.DownloadState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Keeps the process alive while downloads run, so they continue when the app
 * is in the background, and shows their progress as a notification. The
 * downloads themselves run in DownloadRepository.
 */
class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var collector: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, notification("Starting download…", null),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        val repository = App.instance.repository
        collector?.cancel()
        collector = scope.launch {
            combine(repository.items, repository.live) { items, live -> items to live }.collect { (items, live) ->
                val active = items.filter { it.state.isActive }
                if (active.isEmpty()) {
                    ServiceCompat.stopForeground(this@DownloadService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return@collect
                }
                val first = active.first()
                val progress = live[first.id]
                val status = when (first.state) {
                    DownloadState.MERGING -> "Finishing…"
                    DownloadState.DOWNLOADING -> progress?.summary(this@DownloadService) ?: "Downloading…"
                    else -> "Preparing…"
                }
                val title = if (active.size > 1) "Downloading ${active.size} items" else first.title
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(NOTIFICATION_ID, notification(title, status, progress?.fraction))
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
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

        fun start(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW),
            )
            ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))
        }
    }
}
