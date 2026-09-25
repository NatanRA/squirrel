package com.natan.squirrel

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.natan.squirrel.ui.MainScreen
import com.natan.squirrel.ui.SettingsScreen
import com.natan.squirrel.ui.SquirrelTheme
import javax.swing.UIManager

fun main() {
    // Native look for the folder picker
    runCatching { UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName()) }
    AppSettings.load()
    DownloadStore.load()
    NativeMessaging.register()

    // Set by the packaged app (jpackage); "dev" when run from Gradle
    val version = System.getProperty("jpackage.app-version") ?: "dev"

    application {
        Window(
            onCloseRequest = ::exitApplication,
            title = "Squirrel",
            icon = painterResource("icon.png"),
            state = rememberWindowState(size = DpSize(720.dp, 580.dp)),
        ) {
            window.minimumSize = java.awt.Dimension(520, 400)
            var settings by remember { mutableStateOf(false) }
            LaunchedEffect(Unit) {
                DownloadStore.start()
                UpdateManager.refreshStatus()
                UpdateManager.autoUpdateIfDue()
            }
            SquirrelTheme {
                if (settings) SettingsScreen(version, onBack = { settings = false })
                else MainScreen(onOpenSettings = { settings = true })
            }
        }
    }
}
