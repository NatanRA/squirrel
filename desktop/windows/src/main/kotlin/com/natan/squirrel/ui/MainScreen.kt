package com.natan.squirrel.ui

import androidx.compose.foundation.ContextMenuArea
import androidx.compose.foundation.ContextMenuItem
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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.natan.squirrel.AppSettings
import com.natan.squirrel.DownloadItem
import com.natan.squirrel.DownloadState
import com.natan.squirrel.DownloadStore
import com.natan.squirrel.LiveProgress
import com.natan.squirrel.UpdateManager
import com.natan.squirrel.VideoInfo
import kotlinx.coroutines.launch
import java.awt.Desktop

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(onOpenSettings: () -> Unit) {
    val store = DownloadStore
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf("") }
    var fetching by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf<VideoInfo?>(null) }
    var alert by remember { mutableStateOf<Pair<String, String>?>(null) }
    val focus = remember { FocusRequester() }

    fun fetch() {
        val link = url.trim()
        if (link.isEmpty() || fetching) return
        fetching = true
        scope.launch {
            try {
                info = store.fetchInfo(link)
            } catch (e: Exception) {
                alert = "Couldn’t Load Link" to (e.message ?: e.toString())
            } finally {
                fetching = false
            }
        }
    }

    LaunchedEffect(Unit) {
        focus.requestFocus()
        // A link on the clipboard is most likely what the user opened the app for
        val text = clipboard.getText()?.text?.trim()
        if (url.isEmpty() && text != null && Regex("^https?://\\S+$").matches(text)) url = text
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Squirrel") },
            actions = { IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, "Settings") } },
        )
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    modifier = Modifier.weight(1f).focusRequester(focus),
                    placeholder = { Text("Paste a link") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { fetch() }),
                    trailingIcon = {
                        if (url.isNotEmpty()) {
                            IconButton(onClick = { url = "" }) { Icon(Icons.Default.Close, "Clear") }
                        } else {
                            IconButton(onClick = { clipboard.getText()?.text?.trim()?.let { url = it; fetch() } }) {
                                Icon(Icons.Default.ContentPaste, "Paste")
                            }
                        }
                    },
                )
                Spacer(Modifier.width(12.dp))
                Button(onClick = ::fetch, enabled = url.isNotBlank() && !fetching, modifier = Modifier.height(52.dp)) {
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
            Text(
                store.startupError ?: ((store.ytdlpVersion?.let { "yt-dlp ${UpdateManager.display(it)} · " } ?: "Starting yt-dlp… · ") +
                    "Saving to ${AppSettings.downloadFolder.path}"),
                style = MaterialTheme.typography.bodySmall,
                color = if (store.startupError != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )

            if (store.items.isEmpty()) {
                Column(
                    Modifier.fillMaxSize().padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(Icons.Default.Download, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.outline)
                    Spacer(Modifier.height(12.dp))
                    Text("No Downloads", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Paste a link from YouTube or any site yt-dlp supports.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(store.items, key = { it.id }) { item ->
                        DownloadRow(item, store.live[item.id], onAlert = { alert = it }, copy = {
                            clipboard.setText(AnnotatedString(item.sourceUrl))
                        })
                    }
                }
            }
        }
    }

    info?.let { current ->
        FormatDialog(current, onDismiss = { info = null }) { choice ->
            store.download(current, choice)
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
private fun DownloadRow(item: DownloadItem, live: LiveProgress?, onAlert: (Pair<String, String>) -> Unit, copy: () -> Unit) {
    val store = DownloadStore
    val finished = item.state == DownloadState.Finished && item.file != null
    ContextMenuArea(items = {
        buildList {
            if (finished) {
                add(ContextMenuItem("Open") { store.open(item) })
                add(ContextMenuItem("Show in Folder") { store.reveal(item) })
            }
            if (item.state.isActive) add(ContextMenuItem("Cancel") { store.cancel(item.id) })
            if (item.state == DownloadState.Failed || item.state == DownloadState.Cancelled) {
                add(ContextMenuItem("Retry") { store.retry(item.id) })
            }
            add(ContextMenuItem("Copy Link", copy))
            add(ContextMenuItem("Remove from List") { store.remove(item.id) })
            if (finished) add(ContextMenuItem("Delete File") { store.remove(item.id, deleteFile = true) })
            if (store.items.any { !it.state.isActive }) add(ContextMenuItem("Clear Finished") { store.clearFinished() })
        }
    }) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .combinedClickable(
                    onClick = {},
                    onDoubleClick = {
                        when (item.state) {
                            DownloadState.Finished -> store.open(item)
                            DownloadState.Failed -> onAlert("Download Failed" to (item.error ?: "Unknown error"))
                            else -> {}
                        }
                    },
                )
                .padding(6.dp),
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
    }
}

@Composable
private fun StatusLine(item: DownloadItem, live: LiveProgress?) {
    val caption = @Composable { text: String ->
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    when (item.state) {
        DownloadState.Queued -> caption("Waiting…")
        DownloadState.Extracting -> caption("Preparing…")
        DownloadState.Downloading -> Column {
            val fraction = live?.fraction
            if (fraction != null) LinearProgressIndicator(progress = { fraction }, Modifier.fillMaxWidth())
            else LinearProgressIndicator(Modifier.fillMaxWidth())
            Spacer(Modifier.height(4.dp))
            caption(live?.summary ?: "Downloading…")
        }
        DownloadState.Merging -> caption(if ((live?.parts ?: 1) > 1) "Merging audio and video…" else "Finishing…")
        DownloadState.Finished -> caption(
            listOf(
                if (item.choice.isAudio) "Audio" else item.choice.label,
                item.file?.extension?.uppercase().orEmpty(),
            ).filter { it.isNotEmpty() }.joinToString(" · "),
        )
        DownloadState.Cancelled -> caption("Cancelled")
        DownloadState.Failed -> Text(
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

fun openInBrowser(url: String) {
    runCatching { Desktop.getDesktop().browse(java.net.URI(url)) }
}
