package app.squirrel

import android.app.Application
import app.squirrel.data.AppUpdater
import app.squirrel.data.CookieStore
import app.squirrel.data.DownloadRepository
import app.squirrel.data.UpdateManager
import app.squirrel.python.PythonBridge
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class App : Application() {
    /** Outlives screens, so downloads keep running when the UI goes away. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    lateinit var repository: DownloadRepository
    lateinit var updates: UpdateManager
    lateinit var cookies: CookieStore
    lateinit var appUpdater: AppUpdater

    override fun onCreate() {
        super.onCreate()
        instance = this
        PythonBridge.start(this)
        cookies = CookieStore(this)
        repository = DownloadRepository(this, scope)
        updates = UpdateManager(this, scope)
        appUpdater = AppUpdater(this, scope).also { it.check() }
        scope.launch {
            updates.refreshStatus()
            updates.autoUpdateIfDue()
        }
    }

    companion object {
        lateinit var instance: App
            private set
    }
}
