package app.squirrel.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.squirrel.DownloadStore
import app.squirrel.DownloadTarget
import app.squirrel.PlaylistEntry
import app.squirrel.PlaylistInfo
import app.squirrel.Preferences

private const val QUALITY = "playlists.quality"

/** Why an item starts unticked */
private enum class Mark(val label: String) {
    Downloaded("Downloaded"),
    Downloading("In your downloads"),
    Duplicate("Listed twice"),
    Unavailable("Unavailable"),
    Live("Live");

    /** Unavailable and live videos can't be downloaded at all */
    val selectable get() = this != Unavailable && this != Live
}

/**
 * Choose which videos of a playlist, channel or multi-video post to download, and at what
 * quality. Videos already downloaded (or downloading) start unticked.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistDialog(
    playlist: PlaylistInfo,
    onDismiss: () -> Unit,
    onDownload: (List<PlaylistEntry>, DownloadTarget) -> Unit,
) {
    val marks = remember(playlist) { marks(playlist) }
    var selected by remember(playlist) {
        mutableStateOf(playlist.entries.filter { it.index !in marks }.map { it.index }.toSet())
    }
    var quality by remember(playlist) {
        mutableStateOf(
            if (playlist.isMusic) DownloadTarget.Audio
            else DownloadTarget.all.firstOrNull { it.id == Preferences[QUALITY] } ?: DownloadTarget.Best,
        )
    }
    // Only this channel section (Videos, Shorts, Live); null shows everything
    var section by remember(playlist) { mutableStateOf<String?>(null) }
    var sectionMenu by remember { mutableStateOf(false) }

    val visible = section?.let { shown -> playlist.entries.filter { it.section == shown } } ?: playlist.entries
    val chosen = playlist.entries.filter { it.index in selected }

    /** Ticks or unticks what's shown, leaving out what can't be downloaded. */
    fun select(on: Boolean) {
        val indexes = visible.filter { marks[it.index]?.selectable != false }.map { it.index }
        selected = if (on) selected + indexes else selected - indexes.toSet()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            Button(onClick = { onDownload(chosen, quality) }, enabled = chosen.isNotEmpty()) {
                Text(if (chosen.size == 1) "Download 1 Video" else "Download ${chosen.size} Videos")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        title = { Header(playlist) },
        text = {
            Column {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    DownloadTarget.all.forEachIndexed { i, target ->
                        SegmentedButton(
                            selected = quality == target,
                            onClick = { quality = target; Preferences[QUALITY] = target.id },
                            shape = SegmentedButtonDefaults.itemShape(i, DownloadTarget.all.size),
                            icon = {},
                        ) { Text(target.label, maxLines = 1) }
                    }
                }
                Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { select(true) }) { Text("Select All") }
                    TextButton(onClick = { select(false) }) { Text("Select None") }
                    Spacer(Modifier.weight(1f))
                    if (playlist.sections.size > 1) {
                        Box {
                            TextButton(onClick = { sectionMenu = true }) {
                                Text("Show: ${section ?: "Everything"}")
                                Icon(Icons.Default.ArrowDropDown, null)
                            }
                            DropdownMenu(expanded = sectionMenu, onDismissRequest = { sectionMenu = false }) {
                                (listOf(null) + playlist.sections).forEach { option ->
                                    DropdownMenuItem(
                                        text = { Text(option ?: "Everything") },
                                        onClick = { sectionMenu = false; section = option },
                                    )
                                }
                            }
                        }
                    }
                }
                LazyColumn(Modifier.weight(1f, fill = false).heightIn(max = 360.dp)) {
                    items(visible, key = { it.index }) { entry ->
                        Entry(entry, marks[entry.index], checked = entry.index in selected) { on ->
                            selected = if (on) selected + entry.index else selected - entry.index
                        }
                    }
                }
            }
        },
    )
}

@Composable
private fun Header(playlist: PlaylistInfo) {
    val count = playlist.entries.size
    val summary = remember(playlist) {
        val total = playlist.entries.mapNotNull { it.duration }.sum()
        listOfNotNull(
            playlist.uploader,
            if (count == 1) "1 video" else "$count videos",
            if (total > 0) formatDuration(total) else null,
        ).joinToString(" · ")
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Thumbnail(playlist.entries.firstOrNull()?.thumbnail, isAudio = false)
        Spacer(Modifier.width(12.dp))
        Column {
            Text(playlist.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (playlist.truncated) {
                Text(
                    playlist.count?.let { "Showing the first $count of ${"%,d".format(it)}." } ?: "Showing the first $count.",
                    style = MaterialTheme.typography.bodySmall, color = WarningColor,
                )
            }
        }
    }
}

@Composable
private fun Entry(entry: PlaylistEntry, mark: Mark?, checked: Boolean, onChange: (Boolean) -> Unit) {
    val enabled = mark?.selectable != false
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .toggleable(checked, enabled = enabled, role = Role.Checkbox, onValueChange = onChange)
            .padding(vertical = 4.dp)
            .alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked, onCheckedChange = null, enabled = enabled)
        Spacer(Modifier.width(8.dp))
        Thumbnail(entry.thumbnail, isAudio = false, width = 64, height = 36)
        Spacer(Modifier.width(10.dp))
        Column {
            Text(entry.title, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val caption = listOfNotNull(entry.duration?.let(::formatDuration), mark?.label).joinToString(" · ")
            if (caption.isNotEmpty()) {
                Text(
                    caption, style = MaterialTheme.typography.bodySmall,
                    color = when (mark) {
                        null -> MaterialTheme.colorScheme.onSurfaceVariant
                        Mark.Downloaded -> DoneColor
                        else -> WarningColor
                    },
                )
            }
        }
    }
}

/** Marks entries that start unticked: downloaded, in the list already, or not downloadable. */
private fun marks(playlist: PlaylistInfo): Map<Int, Mark> {
    val (downloaded, active) = DownloadStore.library()
    val seen = mutableSetOf<String>()
    return buildMap {
        for (entry in playlist.entries) {
            // Videos of one post share its link, so only their ids tell them apart
            val ids = if (entry.pick == null) listOfNotNull(entry.key, entry.url) else listOfNotNull(entry.key)
            val identity = entry.key ?: "${entry.url}#${entry.pick ?: 0}"
            val mark = when {
                entry.unavailable -> Mark.Unavailable
                entry.live -> Mark.Live
                !seen.add(identity) -> Mark.Duplicate
                ids.any { it in downloaded } -> Mark.Downloaded
                ids.any { it in active } -> Mark.Downloading
                else -> null
            }
            mark?.let { put(entry.index, it) }
        }
    }
}

/** "3:07", or "1:02:03" from an hour */
fun formatDuration(seconds: Double): String {
    val total = seconds.toInt()
    val (h, m, s) = Triple(total / 3600, total / 60 % 60, total % 60)
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
