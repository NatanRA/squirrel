package app.squirrel.ui

import android.icu.text.ListFormatter
import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.NoteAdd
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.squirrel.App
import app.squirrel.data.AutoPaste
import app.squirrel.data.DownloadRepository
import app.squirrel.data.SaveLocations
import app.squirrel.data.UpdateManager
import app.squirrel.restartApp
import kotlinx.coroutines.launch

data class LoginSite(val name: String, val url: String) {
    companion object {
        val presets = listOf(
            LoginSite("YouTube", "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F"),
            LoginSite("Vimeo", "https://vimeo.com/log_in"),
            LoginSite("Instagram", "https://www.instagram.com/accounts/login/"),
            LoginSite("X (Twitter)", "https://x.com/i/flow/login"),
            LoginSite("TikTok", "https://www.tiktok.com/login"),
            LoginSite("Facebook", "https://m.facebook.com/login/"),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit, onAdvanced: () -> Unit, onSignIn: (LoginSite) -> Unit) {
    val app = App.instance
    val status by app.updates.status.collectAsStateWithLifecycle()
    val sites by app.cookies.sites.collectAsStateWithLifecycle()
    var siteMenu by remember { mutableStateOf(false) }
    var customSite by remember { mutableStateOf<String?>(null) }
    var confirmSignOutAll by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var autoPaste by remember { mutableStateOf(AutoPaste.isEnabled(app)) }
    var limit by remember { mutableIntStateOf(app.repository.limit) }
    var limitMenu by remember { mutableStateOf(false) }
    var playlistFolders by remember { mutableStateOf(app.repository.playlistFolders) }
    var subtitles by remember { mutableStateOf(app.repository.subtitles) }
    var autoCaptions by remember { mutableStateOf(app.repository.autoCaptions) }
    // "English and Portuguese": the languages subtitles are fetched in
    val languageNames = remember {
        ListFormatter.getInstance().format(DownloadRepository.subtitleLanguages.map(DownloadRepository::languageName))
    }

    LaunchedEffect(Unit) { app.updates.refreshStatus() }

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) runCatching { app.cookies.importFile(uri) }.onFailure { error = it.message }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Settings") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            Header("Downloads")
            ListItem(
                modifier = Modifier.clickable { limitMenu = true },
                headlineContent = { Text("Downloads at once") },
                trailingContent = {
                    Box {
                        Text("$limit")
                        DropdownMenu(expanded = limitMenu, onDismissRequest = { limitMenu = false }) {
                            for (n in 1..DownloadRepository.MAX_LIMIT) {
                                DropdownMenuItem(text = { Text("$n") }, onClick = {
                                    limitMenu = false
                                    limit = n
                                    app.repository.limit = n
                                })
                            }
                        }
                    }
                },
            )
            ListItem(
                headlineContent = { Text("Save each playlist in its own folder") },
                trailingContent = {
                    Switch(playlistFolders, { playlistFolders = it; app.repository.playlistFolders = it })
                },
            )

            HorizontalDivider()
            Header("Subtitles")
            ListItem(
                headlineContent = { Text("Add Subtitles to Videos") },
                trailingContent = { Switch(subtitles, { subtitles = it; app.repository.subtitles = it }) },
            )
            ListItem(
                headlineContent = {
                    Text(
                        "Include Automatic Captions",
                        color = if (subtitles) Color.Unspecified else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
                    )
                },
                trailingContent = {
                    Switch(autoCaptions, { autoCaptions = it; app.repository.autoCaptions = it }, enabled = subtitles)
                },
            )
            Footer(
                "In $languageNames, when a video has them. Automatic captions are the site's own, in the video's " +
                    "language. The subtitles show in players with a subtitle menu, like VLC.",
            )

            HorizontalDivider()
            Header("Pasting")
            ListItem(
                headlineContent = { Text("Auto-Paste Copied Links") },
                supportingContent = { Text("Open Squirrel after copying a link and it's pasted for you, ready to pick a format.") },
                trailingContent = { Switch(autoPaste, { autoPaste = it; AutoPaste.setEnabled(app, it) }) },
            )

            HorizontalDivider()
            Header("Updates")
            ListItem(
                headlineContent = { Text("yt-dlp") },
                trailingContent = { Text(status.running?.let(UpdateManager::display) ?: "…") },
            )
            UpdateStatusRow()
            Footer(
                status.loadError?.let { "An update failed to load, so the built-in version is in use. ($it)" }
                    ?: "yt-dlp updates itself automatically, which keeps downloads working when sites change.",
                isError = status.loadError != null,
            )

            HorizontalDivider()
            Header("Accounts")
            sites.forEach { site ->
                ListItem(
                    headlineContent = { Text(site.domain) },
                    supportingContent = { Text(if (site.imported) "Imported" else "${site.count} cookies") },
                    trailingContent = {
                        IconButton(onClick = { app.cookies.remove(site) }) {
                            Icon(Icons.Default.Logout, "Sign out of ${site.domain}")
                        }
                    },
                )
            }
            Box {
                ListItem(
                    modifier = Modifier.clickable { siteMenu = true },
                    leadingContent = { Icon(Icons.Default.PersonAdd, null) },
                    headlineContent = { Text("Sign In to a Site") },
                )
                DropdownMenu(expanded = siteMenu, onDismissRequest = { siteMenu = false }) {
                    LoginSite.presets.forEach { site ->
                        DropdownMenuItem(text = { Text(site.name) }, onClick = { siteMenu = false; onSignIn(site) })
                    }
                    DropdownMenuItem(text = { Text("Other Site…") }, onClick = { siteMenu = false; customSite = "" })
                }
            }
            ListItem(
                modifier = Modifier.clickable { importer.launch(arrayOf("text/plain", "application/octet-stream", "*/*")) },
                leadingContent = { Icon(Icons.Default.NoteAdd, null) },
                headlineContent = { Text("Import cookies.txt") },
            )
            if (sites.isNotEmpty()) {
                ListItem(
                    modifier = Modifier.clickable { confirmSignOutAll = true },
                    headlineContent = { Text("Sign Out of All Sites", color = MaterialTheme.colorScheme.error) },
                )
            }
            Footer(
                "Signing in lets Squirrel download videos that need an account. YouTube may flag accounts used " +
                    "this way, so consider a spare account for YouTube.",
            )

            HorizontalDivider()
            ListItem(
                modifier = Modifier.clickable(onClick = onAdvanced),
                headlineContent = { Text("Advanced") },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
            )

            HorizontalDivider()
            AboutSection()
        }
    }

    customSite?.let { text ->
        AlertDialog(
            onDismissRequest = { customSite = null },
            title = { Text("Sign In to Another Site") },
            text = {
                OutlinedTextField(text, { customSite = it }, placeholder = { Text("https://example.com/login") }, singleLine = true)
            },
            confirmButton = {
                TextButton(onClick = {
                    val url = text.trim().let { if ("://" in it) it else "https://$it" }
                    customSite = null
                    if (android.net.Uri.parse(url).host != null) onSignIn(LoginSite(android.net.Uri.parse(url).host!!, url))
                }) { Text("Open") }
            },
            dismissButton = { TextButton(onClick = { customSite = null }) { Text("Cancel") } },
        )
    }
    if (confirmSignOutAll) {
        AlertDialog(
            onDismissRequest = { confirmSignOutAll = false },
            title = { Text("Sign out of all sites?") },
            confirmButton = {
                TextButton(onClick = { confirmSignOutAll = false; app.cookies.removeAll() }) {
                    Text("Sign Out of All", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmSignOutAll = false }) { Text("Cancel") } },
        )
    }
    error?.let {
        AlertDialog(
            onDismissRequest = { error = null },
            title = { Text("Couldn't Import Cookies") },
            text = { Text(it) },
            confirmButton = { TextButton(onClick = { error = null }) { Text("OK") } },
        )
    }
}

/** Where to find the source and the licenses of what Squirrel is built on. */
private const val SOURCE_URL = "https://github.com/NatanRA/squirrel"

@Composable
private fun AboutSection() {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    val version = remember {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull()
    }
    Header("About")
    ListItem(
        headlineContent = { Text("Squirrel") },
        supportingContent = { Text("Powered by yt-dlp and FFmpeg") },
        trailingContent = { version?.let { Text(it) } },
    )
    ListItem(
        modifier = Modifier.clickable { uriHandler.openUri("$SOURCE_URL/blob/main/THIRD_PARTY_NOTICES.md") },
        headlineContent = { Text("Open-Source Licenses") },
        trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
    )
    ListItem(
        modifier = Modifier.clickable { uriHandler.openUri(SOURCE_URL) },
        headlineContent = { Text("Source Code") },
        trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
    )
    Footer(
        "Squirrel is free software under the GPL 3.0, built on yt-dlp (public domain), FFmpeg (LGPL 2.1), " +
            "LAME (LGPL 2.0) and Python. It isn't affiliated with YouTube or any site it downloads from.",
    )
}

/** One line describing what the automatic updater is doing. */
@Composable
private fun UpdateStatusRow() {
    val app = App.instance
    val context = LocalContext.current
    val phase by app.updates.phase.collectAsStateWithLifecycle()
    ListItem(headlineContent = {
        when (val p = phase) {
            UpdateManager.Phase.Checking -> Progress("Checking for updates…")
            is UpdateManager.Phase.Installing -> Progress("Downloading ${UpdateManager.display(p.version)}…")
            is UpdateManager.Phase.Ready -> Column {
                Text("${UpdateManager.display(p.version)} will be used next time the app opens.")
                TextButton(onClick = { restartApp(context) }, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
                    Text("Restart Now")
                }
            }
            else -> {
                val last = app.updates.lastCheck
                Text(
                    if (last == 0L) "Not checked yet"
                    else "Up to date · checked ${DateUtils.getRelativeTimeSpanString(last)}".replace("checked In", "checked in"),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedScreen(onBack: () -> Unit) {
    val updates = App.instance.updates
    val status by updates.status.collectAsStateWithLifecycle()
    val phase by updates.phase.collectAsStateWithLifecycle()
    val upToDate by updates.upToDate.collectAsStateWithLifecycle()
    var nightly by remember { mutableStateOf(updates.nightly) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var videoFolder by remember { mutableStateOf(SaveLocations.folder(context, isAudio = false)?.name) }
    var audioFolder by remember { mutableStateOf(SaveLocations.folder(context, isAudio = true)?.name) }
    var pickingAudioFolder by rememberSaveable { mutableStateOf(false) }
    val folderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { tree ->
        if (tree == null) return@rememberLauncherForActivityResult
        runCatching { SaveLocations.set(context, pickingAudioFolder, tree) }
        val name = SaveLocations.folder(context, pickingAudioFolder)?.name
        if (pickingAudioFolder) audioFolder = name else videoFolder = name
    }
    val busy = phase is UpdateManager.Phase.Checking || phase is UpdateManager.Phase.Installing
    val pending = (phase as? UpdateManager.Phase.Ready)?.version
        ?.takeIf { UpdateManager.normalized(it) != UpdateManager.normalized(status.bundled) }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Advanced") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            Header("Save Locations")
            SaveLocationRow("Videos", videoFolder, default = "Movies/Squirrel (Gallery)",
                onChoose = { pickingAudioFolder = false; folderPicker.launch(null) },
                onReset = { SaveLocations.set(context, isAudio = false, tree = null); videoFolder = null },
            )
            SaveLocationRow("Audio", audioFolder, default = "Music/Squirrel",
                onChoose = { pickingAudioFolder = true; folderPicker.launch(null) },
                onReset = { SaveLocations.set(context, isAudio = true, tree = null); audioFolder = null },
            )
            Footer("Choose any folder, like one your music or video app uses. New downloads go there.")

            HorizontalDivider()
            Header("yt-dlp")
            ListItem(headlineContent = { Text("Running") }, trailingContent = { Text(status.running?.let(UpdateManager::display) ?: "…") })
            ListItem(headlineContent = { Text("Built-in") }, trailingContent = { Text(status.bundled?.let(UpdateManager::display) ?: "…") })
            UpdateStatusRow()
            ListItem(
                modifier = Modifier.clickable(enabled = !busy) { scope.launch { updates.checkNow() } },
                headlineContent = { Text("Check Now", color = MaterialTheme.colorScheme.primary) },
            )
            when {
                phase is UpdateManager.Phase.Failed -> Footer((phase as UpdateManager.Phase.Failed).message, isError = true)
                upToDate -> Footer("You have the latest version.")
            }

            HorizontalDivider()
            ListItem(
                headlineContent = { Text("Nightly Builds") },
                supportingContent = { Text("Get YouTube fixes days before a stable release, but can have new bugs.") },
                trailingContent = { Switch(nightly, { nightly = it; updates.nightly = it }) },
            )

            if (status.usingUpdate || pending != null) {
                HorizontalDivider()
                ListItem(
                    modifier = Modifier.clickable { scope.launch { updates.revertToBundled() } },
                    headlineContent = { Text("Revert to Built-in Version", color = MaterialTheme.colorScheme.error) },
                    supportingContent = {
                        Text("Removes the downloaded update if it causes problems. That version won't be installed again automatically.")
                    },
                )
            }
        }
    }
}

@Composable
private fun SaveLocationRow(title: String, folder: String?, default: String, onChoose: () -> Unit, onReset: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onChoose),
        headlineContent = { Text(title) },
        supportingContent = { Text(folder ?: default) },
        trailingContent = {
            if (folder != null) IconButton(onClick = onReset) { Icon(Icons.Default.Close, "Use $default") }
        },
    )
}

@Composable
private fun Progress(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        Spacer(Modifier.width(8.dp))
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Header(title: String) {
    Text(
        title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun Footer(text: String, isError: Boolean = false) {
    Text(
        text, style = MaterialTheme.typography.bodySmall,
        color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
    )
}
