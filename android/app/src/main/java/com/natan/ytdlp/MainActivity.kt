package com.natan.ytdlp

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.natan.ytdlp.data.AutoPaste
import com.natan.ytdlp.ui.AdvancedScreen
import com.natan.ytdlp.ui.LaunchSplash
import com.natan.ytdlp.ui.LoginSite
import com.natan.ytdlp.ui.MainScreen
import com.natan.ytdlp.ui.SettingsScreen
import com.natan.ytdlp.ui.SignInScreen
import com.natan.ytdlp.ui.SquirrelTheme

class MainActivity : ComponentActivity() {
    /** A link shared into the app (share sheet or squirrel://download?url=...). */
    private val sharedUrl = mutableStateOf<String?>(null)

    /** A newly copied link found when the app came to the front (Settings › Pasting). */
    private val pastedUrl = mutableStateOf<String?>(null)

    /** Set on each return to the app; the clipboard can only be read once the window has focus. */
    private var checkClipboard = false

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)
        // Off when the system's animations are turned off (Settings › Accessibility)
        val animate = Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) != 0f
        setContent {
            SquirrelTheme {
                // Saved, so it plays once per launch rather than on every rotation
                var splash by rememberSaveable { mutableStateOf(true) }
                Box {
                    SquirrelApp(
                        sharedUrl = sharedUrl.value, onSharedUrlConsumed = { sharedUrl.value = null },
                        pastedUrl = pastedUrl.value, onPastedUrlConsumed = { pastedUrl.value = null },
                    )
                    AnimatedVisibility(splash, enter = EnterTransition.None, exit = fadeOut(tween(250))) {
                        LaunchSplash(animate) { splash = false }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        checkClipboard = true
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Focus also returns when a dialog or sheet closes, so only check after onResume
        if (!hasFocus || !checkClipboard) return
        checkClipboard = false
        if (sharedUrl.value == null) AutoPaste.newLink(this)?.let { pastedUrl.value = it }
    }

    private fun handle(intent: Intent?) {
        val text = when (intent?.action) {
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            Intent.ACTION_VIEW -> intent.data?.let { uri ->
                // ytdlp:// is the scheme from before the rename
                if (uri.scheme == "squirrel" || uri.scheme == "ytdlp") uri.getQueryParameter("url") else uri.toString()
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
private fun SquirrelApp(
    sharedUrl: String?,
    onSharedUrlConsumed: () -> Unit,
    pastedUrl: String?,
    onPastedUrlConsumed: () -> Unit,
) {
    var screen by remember { mutableStateOf<Screen>(Screen.Main) }
    val app = App.instance

    BackHandler(enabled = screen != Screen.Main) {
        screen = if (screen == Screen.Settings) Screen.Main else Screen.Settings
    }

    when (val current = screen) {
        Screen.Main -> MainScreen(
            sharedUrl = sharedUrl,
            onSharedUrlConsumed = onSharedUrlConsumed,
            pastedUrl = pastedUrl,
            onPastedUrlConsumed = onPastedUrlConsumed,
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
