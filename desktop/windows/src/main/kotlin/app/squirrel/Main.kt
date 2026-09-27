package app.squirrel

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import app.squirrel.ui.LaunchSplash
import app.squirrel.ui.MainScreen
import app.squirrel.ui.SettingsScreen
import app.squirrel.ui.SquirrelTheme
import javax.swing.UIManager
import kotlin.system.exitProcess

fun main() {
    // Already running, perhaps in the background: that copy shows its window instead
    if (!SingleInstance.claim()) exitProcess(0)
    // Native look for the folder picker
    runCatching { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()) }
    AppSettings.load()
    DownloadStore.load()
    NativeMessaging.register()

    // Set by the packaged app (jpackage); "dev" when run from Gradle
    val version = System.getProperty("jpackage.app-version") ?: "dev"

    application {
        val icon = painterResource("icon.png")
        val windowState = rememberWindowState(size = DpSize(720.dp, 580.dp))
        if (Background.keepRunning) {
            // In the notification area by the clock: click to open, right-click to quit
            Tray(
                icon = icon,
                tooltip = "Squirrel",
                onAction = Background::showWindow,
                menu = {
                    Item("Open Squirrel", onClick = Background::showWindow)
                    Item("Quit Squirrel", onClick = ::exitApplication)
                },
            )
        }
        Window(
            // Closing hides the window while Squirrel keeps running (Settings); downloads carry on
            onCloseRequest = { if (Background.keepRunning) Background.windowVisible = false else exitApplication() },
            visible = Background.windowVisible,
            title = "Squirrel",
            icon = icon,
            state = windowState,
        ) {
            window.minimumSize = java.awt.Dimension(520, 400)
            LaunchedEffect(Background.raiseRequests) {
                if (Background.raiseRequests > 0) {
                    windowState.isMinimized = false
                    window.toFront()
                    window.requestFocus()
                }
            }
            var settings by remember { mutableStateOf(false) }
            LaunchedEffect(Unit) {
                DownloadStore.start()
                AppUpdater.check()
                UpdateManager.refreshStatus()
                UpdateManager.autoUpdateIfDue()
            }
            var splash by remember { mutableStateOf(true) }
            SquirrelTheme {
                Box {
                    if (settings) SettingsScreen(version, onBack = { settings = false })
                    else MainScreen(onOpenSettings = { settings = true })
                    AnimatedVisibility(splash, enter = EnterTransition.None, exit = fadeOut(tween(250))) {
                        LaunchSplash(animate = true) { splash = false }
                    }
                }
            }
        }
    }
}
