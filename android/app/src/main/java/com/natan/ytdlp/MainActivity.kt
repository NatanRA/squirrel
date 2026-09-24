package com.natan.ytdlp

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.natan.ytdlp.ui.AdvancedScreen
import com.natan.ytdlp.ui.LoginSite
import com.natan.ytdlp.ui.MainScreen
import com.natan.ytdlp.ui.SettingsScreen
import com.natan.ytdlp.ui.SignInScreen
import com.natan.ytdlp.ui.YtdlpTheme

class MainActivity : ComponentActivity() {
    /** A link shared into the app (share sheet or ytdlp://download?url=...). */
    private val sharedUrl = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)
        setContent {
            YtdlpTheme {
                YtdlpApp(sharedUrl.value) { sharedUrl.value = null }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        val text = when (intent?.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_VIEW -> intent.data?.let { uri ->
                if (uri.scheme == "ytdlp") uri.getQueryParameter("url") else uri.toString()
            }
            else -> null
        } ?: return
        // Shared text often wraps the link, e.g. "Check this out https://youtu.be/…"
        Regex("https?://\\S+").find(text)?.value?.let { sharedUrl.value = it }
    }
}

private sealed interface Screen {
    data object Main : Screen
    data object Settings : Screen
    data object Advanced : Screen
    data class SignIn(val site: LoginSite) : Screen
}

@Composable
private fun YtdlpApp(sharedUrl: String?, onSharedUrlConsumed: () -> Unit) {
    var screen by remember { mutableStateOf<Screen>(Screen.Main) }
    val app = App.instance

    BackHandler(enabled = screen != Screen.Main) {
        screen = if (screen == Screen.Settings) Screen.Main else Screen.Settings
    }

    when (val current = screen) {
        Screen.Main -> MainScreen(
            sharedUrl = sharedUrl,
            onSharedUrlConsumed = onSharedUrlConsumed,
            onOpenSettings = { screen = Screen.Settings },
        )
        Screen.Settings -> SettingsScreen(
            onBack = { screen = Screen.Main },
            onAdvanced = { screen = Screen.Advanced },
            onSignIn = { screen = Screen.SignIn(it) },
        )
        Screen.Advanced -> AdvancedScreen(onBack = { screen = Screen.Settings })
        is Screen.SignIn -> SignInScreen(current.site) { visitedHosts ->
            app.cookies.captureBrowserCookies(visitedHosts)
            screen = Screen.Settings
        }
    }
}

/** Restarts the process so a newly installed yt-dlp is loaded. */
fun restartApp(context: Context) {
    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
    context.startActivity(Intent.makeRestartActivityTask(launch.component))
    Runtime.getRuntime().exit(0)
}
