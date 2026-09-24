package com.natan.ytdlp.ui

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.natan.ytdlp.App
import com.natan.ytdlp.data.DownloadItem
import com.natan.ytdlp.data.DownloadState
import com.natan.ytdlp.data.FormatChoice
import com.natan.ytdlp.data.LiveProgress
import com.natan.ytdlp.data.UpdateManager
import com.natan.ytdlp.data.VideoInfo
import com.natan.ytdlp.python.PythonBridge
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(sharedUrl: String?, onSharedUrlConsumed: () -> Unit, onOpenSettings: () -> Unit) {
    val context = LocalContext.current
    val repository = App.instance.repository
    val items by repository.items.collectAsStateWithLifecycle()
    val live by repository.live.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    var url by remember { mutableStateOf("") }
    var fetching by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf<VideoInfo?>(null) }
    var alert by remember { mutableStateOf<Pair<String, String>?>(null) }
    val version by produceState<String?>(null) { value = runCatching { PythonBridge.version() }.getOrNull() }

    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}

    fun fetch() {
        val link = url.trim()
        if (link.isEmpty() || fetching) return
        fetching = true
        scope.launch {
            try {
                info = repository.fetchInfo(link)
            } catch (e: Exception) {
                alert = "Couldn't Load Link" to (e.message ?: e.toString())
            } finally {
                fetching = false
            }
        }
    }

    LaunchedEffect(sharedUrl) {
        if (sharedUrl != null) {
            url = sharedUrl
            onSharedUrlConsumed()
            fetch()
        }
    }

    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text("yt-dlp") },
                actions = {
                    IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, "Settings") }
                },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp, top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item {
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Paste a link") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { fetch() }),
                    trailingIcon = {
                        if (url.isNotEmpty()) {
                            IconButton(onClick = { url = "" }) { Icon(Icons.Default.Close, "Clear") }
                        } else {
                            IconButton(onClick = { clipboardText(context)?.let { url = it; fetch() } }) {
                                Icon(Icons.Default.ContentPaste, "Paste")
                            }
                        }
                    },
                )
            }
            item {
                Button(onClick = ::fetch, enabled = url.isNotBlank() && !fetching, modifier = Modifier.fillMaxWidth()) {
                    if (fetching) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Fetching…")
                    } else {
                        Icon(Icons.Default.Download, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Download")
                    }
                }
            }
            item {
                Text(
                    (version?.let { "yt-dlp ${UpdateManager.display(it)} · " } ?: "Starting yt-dlp… · ") +
                        "Videos are saved to Movies/yt-dlp (Gallery), audio to Music/yt-dlp.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
            }

            if (items.isEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().padding(vertical = 64.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(Icons.Default.Download, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.outline)
                        Spacer(Modifier.height(12.dp))
                        Text("No Downloads", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Paste a link, or share one to yt-dlp from YouTube or any other app.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            } else {
                item {
                    Text(
                        "Downloads", style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(start = 4.dp, top = 12.dp),
                    )
                }
                items(items, key = { it.id }) { item ->
                    DownloadRow(item, live[item.id], onAlert = { alert = it })
                }
            }
        }
    }

    info?.let { current ->
        FormatSheet(current, onDismiss = { info = null }) { choice: FormatChoice ->
            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                    context, Manifest.permission.POST_NOTIFICATIONS,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                // For the progress notification; downloads work either way
                notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
            repository.download(current, choice)
            info = null
            url = ""
        }
    }

    alert?.let { (title, message) ->
        AlertDialog(
            onDismissRequest = { alert = null },
            confirmButton = { TextButton(onClick = { alert = null }) { Text("OK") } },
            title = { Text(title) },
            text = { Text(message) },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DownloadRow(item: DownloadItem, live: LiveProgress?, onAlert: (Pair<String, String>) -> Unit) {
    val context = LocalContext.current
    val repository = App.instance.repository
    var menu by remember { mutableStateOf(false) }

    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .combinedClickable(
                    onClick = {
                        when (item.state) {
                            DownloadState.FINISHED -> open(context, item)
                            DownloadState.FAILED -> onAlert("Download Failed" to (item.error ?: "Unknown error"))
                            else -> {}
                        }
                    },
                    onLongClick = { menu = true },
                )
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Thumbnail(item.thumbnail, item.choice.isAudio)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    item.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                StatusLine(item, live)
            }
        }

        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (item.state == DownloadState.FINISHED && item.contentUri != null) {
                DropdownMenuItem(text = { Text("Open") }, onClick = { menu = false; open(context, item) })
                DropdownMenuItem(text = { Text("Share") }, onClick = { menu = false; share(context, item) })
            }
            if (item.state.isActive) {
                DropdownMenuItem(text = { Text("Cancel") }, onClick = { menu = false; repository.cancel(item.id) })
            }
            if (item.state == DownloadState.FAILED || item.state == DownloadState.CANCELLED) {
                DropdownMenuItem(text = { Text("Retry") }, onClick = { menu = false; repository.retry(item.id) })
            }
            DropdownMenuItem(text = { Text("Copy Link") }, onClick = {
                menu = false
                context.getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("Link", item.sourceUrl))
            })
            DropdownMenuItem(
                text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                onClick = { menu = false; repository.delete(item.id) },
            )
        }
    }
}

@Composable
private fun StatusLine(item: DownloadItem, live: LiveProgress?) {
    val context = LocalContext.current
    val caption = @Composable { text: String ->
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    when (item.state) {
        DownloadState.QUEUED -> caption("Waiting…")
        DownloadState.EXTRACTING -> caption("Preparing…")
        DownloadState.DOWNLOADING -> Column {
            val fraction = live?.fraction
            if (fraction != null) LinearProgressIndicator(progress = { fraction }, Modifier.fillMaxWidth())
            else LinearProgressIndicator(Modifier.fillMaxWidth())
            Spacer(Modifier.height(4.dp))
            caption(live?.summary(context) ?: "Downloading…")
        }
        DownloadState.MERGING -> caption(if ((live?.parts ?: 1) > 1) "Merging audio and video…" else "Finishing…")
        DownloadState.FINISHED -> caption(
            listOf(
                if (item.choice.isAudio) "Audio" else item.choice.label,
                item.fileType ?: "",
                if (item.choice.isAudio) "Music" else "Gallery",
            ).filter { it.isNotEmpty() }.joinToString(" · "),
        )
        DownloadState.CANCELLED -> caption("Cancelled")
        DownloadState.FAILED -> Text(
            item.error ?: "Failed", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun Thumbnail(url: String?, isAudio: Boolean, width: Int = 96, height: Int = 54) {
    Box(
        Modifier
            .size(width.dp, height.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isAudio) Icons.Default.MusicNote else Icons.Default.Movie, null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (url != null) {
            AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
    }
}

private fun clipboardText(context: Context): String? =
    context.getSystemService(ClipboardManager::class.java).primaryClip
        ?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()?.trim()
        ?.ifEmpty { null }

private fun open(context: Context, item: DownloadItem) {
    val uri = item.contentUri ?: return
    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(uri), item.mimeType)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    runCatching { context.startActivity(intent) }
        .onFailure { runCatching { context.startActivity(Intent.createChooser(intent, "Open with")) } }
}

private fun share(context: Context, item: DownloadItem) {
    val uri = item.contentUri ?: return
    val intent = Intent(Intent.ACTION_SEND).setType(item.mimeType)
        .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(intent, item.title))
}
