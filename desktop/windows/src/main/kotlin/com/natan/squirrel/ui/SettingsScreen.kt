package com.natan.squirrel.ui

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
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
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
import androidx.compose.ui.unit.dp
import com.natan.squirrel.AppSettings
import com.natan.squirrel.CookieBrowser
import com.natan.squirrel.DownloadStore
import com.natan.squirrel.UpdateManager
import kotlinx.coroutines.launch
import java.io.File
import javax.swing.JFileChooser

private const val SOURCE_URL = "https://github.com/FormulaLatest/squirrel"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(appVersion: String, onBack: () -> Unit) {
    val updates = UpdateManager
    val scope = rememberCoroutineScope()
    var browserMenu by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { updates.refreshStatus() }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Settings") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { padding ->
        Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
            Header("Downloads")
            ListItem(
                modifier = Modifier.clickable { chooseFolder(AppSettings.downloadFolder)?.let(AppSettings::updateDownloadFolder) },
                headlineContent = { Text("Save to") },
                supportingContent = { Text(AppSettings.downloadFolder.path) },
                trailingContent = { Text("Change…", color = MaterialTheme.colorScheme.primary) },
            )

            HorizontalDivider()
            Header("Accounts")
            Box {
                ListItem(
                    modifier = Modifier.clickable { browserMenu = true },
                    headlineContent = { Text("Use cookies from") },
                    supportingContent = { Text(AppSettings.cookieBrowser.label) },
                    trailingContent = { Icon(Icons.Default.ArrowDropDown, null) },
                )
                DropdownMenu(expanded = browserMenu, onDismissRequest = { browserMenu = false }) {
                    CookieBrowser.entries.forEach { browser ->
                        DropdownMenuItem(
                            text = { Text(browser.label) },
                            onClick = { browserMenu = false; AppSettings.updateCookieBrowser(browser) },
                        )
                    }
                }
            }
            Footer(
                "Lets Squirrel download videos that need you to be signed in, using the browser you're signed in " +
                    "with. Firefox works best; recent Chrome versions lock their cookies while running. " +
                    "YouTube may flag accounts used this way.",
            )

            HorizontalDivider()
            Header("Browser Extension")
            ListItem(
                modifier = Modifier.clickable { openInBrowser("$SOURCE_URL/tree/main/extension") },
                headlineContent = { Text("Get the Extension") },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
            )
            Footer(
                "The Squirrel extension for Chrome, Edge, Brave and Firefox uses this app to download. " +
                    "Keep the app installed; it doesn't need to be open.",
            )

            HorizontalDivider()
            Header("Updates")
            ListItem(
                headlineContent = { Text("yt-dlp") },
                trailingContent = { Text(updates.runningVersion?.let(UpdateManager::display) ?: "…") },
            )
            UpdateStatusRow()
            ListItem(
                headlineContent = { Text("Nightly builds") },
                supportingContent = { Text("Get YouTube fixes days before a stable release, but can have new bugs.") },
                trailingContent = { Switch(updates.nightly, { scope.launch { updates.setNightly(it) } }) },
            )
            val busy = updates.phase is UpdateManager.Phase.Checking || updates.phase is UpdateManager.Phase.Installing
            ListItem(
                modifier = Modifier.clickable(enabled = !busy) { scope.launch { updates.checkNow() } },
                headlineContent = { Text("Check Now", color = MaterialTheme.colorScheme.primary) },
            )
            val pending = (updates.phase as? UpdateManager.Phase.Ready)?.version
                ?.takeIf { UpdateManager.normalized(it) != UpdateManager.normalized(updates.bundledVersion) }
            if (updates.isUsingUpdate || pending != null) {
                ListItem(
                    modifier = Modifier.clickable { scope.launch { updates.revertToBundled() } },
                    headlineContent = { Text("Revert to Built-in Version", color = MaterialTheme.colorScheme.error) },
                )
            }
            when (val phase = updates.phase) {
                is UpdateManager.Phase.Failed -> Footer(phase.message, isError = true)
                else -> Footer(
                    updates.loadError?.let { "An update failed to load, so the built-in version is in use. ($it)" }
                        ?: if (updates.isUpToDate) "You have the latest version."
                        else "yt-dlp updates itself automatically, which keeps downloads working when sites change.",
                    isError = updates.loadError != null,
                )
            }

            HorizontalDivider()
            Header("About")
            ListItem(
                headlineContent = { Text("Squirrel") },
                supportingContent = { Text("Powered by yt-dlp and FFmpeg") },
                trailingContent = { Text(appVersion) },
            )
            ListItem(
                modifier = Modifier.clickable { openInBrowser("$SOURCE_URL/blob/main/THIRD_PARTY_NOTICES.md") },
                headlineContent = { Text("Open-Source Licenses") },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
            )
            ListItem(
                modifier = Modifier.clickable { openInBrowser(SOURCE_URL) },
                headlineContent = { Text("Source Code") },
                trailingContent = { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null) },
            )
            Footer(
                "Squirrel is free software under the GPL 3.0, built on yt-dlp (public domain), FFmpeg (LGPL 2.1) " +
                    "and Python. It isn't affiliated with YouTube or any site it downloads from.",
            )
        }
    }
}

/** One line describing what the automatic updater is doing. */
@Composable
private fun UpdateStatusRow() {
    val scope = rememberCoroutineScope()
    ListItem(headlineContent = {
        when (val p = UpdateManager.phase) {
            UpdateManager.Phase.Checking -> Progress("Checking for updates…")
            is UpdateManager.Phase.Installing -> Progress("Downloading ${UpdateManager.display(p.version)}…")
            is UpdateManager.Phase.Ready -> Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${UpdateManager.display(p.version)} is ready.", Modifier.weight(1f))
                TextButton(
                    onClick = { scope.launch { UpdateManager.restartEngine() } },
                    enabled = !DownloadStore.hasActiveDownloads,
                ) { Text("Use Now") }
            }
            else -> {
                val last = UpdateManager.lastCheck
                Text(
                    if (last == 0L) "Not checked yet" else "Up to date · checked ${ago(last)}",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    })
}

private fun ago(millis: Long): String {
    val minutes = (System.currentTimeMillis() - millis) / 60_000
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "$minutes min ago"
        minutes < 48 * 60 -> "${minutes / 60} h ago"
        else -> "${minutes / (24 * 60)} days ago"
    }
}

private fun chooseFolder(current: File): File? {
    val chooser = JFileChooser(current).apply {
        fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
        dialogTitle = "Save Downloads To"
    }
    return if (chooser.showDialog(null, "Choose") == JFileChooser.APPROVE_OPTION) chooser.selectedFile else null
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
