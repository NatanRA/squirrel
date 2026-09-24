package com.natan.ytdlp.ui

import android.graphics.Bitmap
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/**
 * In-app browser for signing into a site. On Done, the cookies of every host
 * visited are handed to CookieStore for yt-dlp.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SignInScreen(site: LoginSite, onDone: (Set<String>) -> Unit) {
    var title by remember { mutableStateOf(site.name) }
    var loading by remember { mutableStateOf(true) }
    val visitedHosts = remember { mutableSetOf<String>() }
    var webView by remember { mutableStateOf<WebView?>(null) }

    BackHandler {
        val view = webView
        if (view != null && view.canGoBack()) view.goBack() else onDone(visitedHosts)
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = {
                if (loading) CircularProgressIndicator(Modifier.padding(16.dp).size(20.dp), strokeWidth = 2.dp)
            },
            actions = { TextButton(onClick = { onDone(visitedHosts) }) { Text("Done") } },
        )
    }) { padding ->
        AndroidView(
            modifier = Modifier.padding(padding).fillMaxSize(),
            factory = { context ->
                WebView(context).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    // Google refuses sign-in from user agents that identify as a WebView
                    settings.userAgentString = settings.userAgentString
                        .replace("; wv", "").replace(Regex("Version/\\S+ "), "")
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                    webViewClient = object : WebViewClient() {
                        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                            loading = true
                            android.net.Uri.parse(url ?: "").host?.let(visitedHosts::add)
                        }

                        override fun onPageFinished(view: WebView, url: String?) {
                            loading = false
                            android.net.Uri.parse(url ?: "").host?.let(visitedHosts::add)
                            view.title?.takeIf { it.isNotBlank() }?.let { title = it }
                        }
                    }
                    loadUrl(site.url)
                    webView = this
                }
            },
        )
    }
}
