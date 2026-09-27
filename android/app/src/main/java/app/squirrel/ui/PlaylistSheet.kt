package app.squirrel.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.squirrel.App
import app.squirrel.data.DownloadRepository
import app.squirrel.data.DownloadTarget
import app.squirrel.data.PlaylistEntry
import app.squirrel.data.PlaylistInfo
import java.text.NumberFormat

/**
 * Choose which videos of a playlist, channel or multi-video post to download, and at what
 * quality. Videos already downloaded (or downloading) start unticked.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistSheet(
    playlist: PlaylistInfo,
    onDismiss: () -> Unit,
    onDownload: (List<PlaylistEntry>, DownloadTarget) -> Unit,
) {
    val repository = App.instance.repository
    var quality by remember {
        mutableStateOf(
            if (playlist.isMusic) DownloadTarget.AUDIO
            else DownloadTarget.ALL.firstOrNull { it.id == repository.playlistQuality } ?: DownloadTarget.BEST,
        )
    }
    val marks = remember(playlist) { marks(playlist, repository.library()) }
    var selected by remember(playlist) {
        mutableStateOf(playlist.entries.filter { marks[it.index] == null }.map { it.index }.toSet())
    }
    // Only this channel section (Videos, Shorts, Live); null shows everything
    var section by remember { mutableStateOf<String?>(null) }
    var sectionMenu by remember { mutableStateOf(false) }

    val visible = section?.let { name -> playlist.entries.filter { it.section == name } } ?: playlist.entries
    val chosen = playlist.entries.filter { it.index in selected }

    // Ticks or unticks what's shown, leaving out what can't be downloaded
    fun select(on: Boolean) {
        val shown = visible.filter { marks[it.index]?.selectable != false }.map { it.index }
        selected = if (on) selected + shown else selected - shown.toSet()
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.navigationBarsPadding()) {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.Top) {
                Thumbnail(playlist.entries.firstOrNull()?.thumbnail, isAudio = false, width = 128, height = 72)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        playlist.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        summary(playlist), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (playlist.truncated) {
                        Text(
                            playlist.count?.let { "Showing the first ${playlist.entries.size} of ${NumberFormat.getIntegerInstance().format(it)}." }
                                ?: "Showing the first ${playlist.entries.size}.",
                            style = MaterialTheme.typography.bodySmall, color = WarningColor,
                        )
                    }
                }
            }

            // For each video, the best version up to this size, or just its audio (as it is, or as MP3)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                DownloadTarget.ALL.forEachIndexed { index, target ->
                    SegmentedButton(
                        selected = quality == target,
                        onClick = { quality = target; repository.playlistQuality = target.id },
                        shape = SegmentedButtonDefaults.itemShape(index, DownloadTarget.ALL.size),
                        icon = {},
                    ) { Text(target.label, maxLines = 1) }
                }
            }

            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
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
                            DropdownMenuItem(text = { Text("Everything") }, onClick = { sectionMenu = false; section = null })
                            playlist.sections.forEach { name ->
                                DropdownMenuItem(text = { Text(name) }, onClick = { sectionMenu = false; section = name })
                            }
                        }
                    }
                }
            }

            HorizontalDivider()
            LazyColumn(Modifier.weight(1f, fill = false)) {
                items(visible, key = { it.index }) { entry ->
                    EntryRow(entry, marks[entry.index], entry.index in selected) { on ->
                        selected = if (on) selected + entry.index else selected - entry.index
                    }
                }
            }
            HorizontalDivider()

            Button(
                onClick = { onDownload(chosen, quality) }, enabled = chosen.isNotEmpty(),
                modifier = Modifier.fillMaxWidth().padding(16.dp),
            ) {
                Text(if (chosen.size == 1) "Download 1 Video" else "Download ${chosen.size} Videos")
            }
        }
    }
}

private enum class Mark(val label: String) {
    DOWNLOADED("Downloaded"),
    DOWNLOADING("In your downloads"),
    DUPLICATE("Listed twice"),
    UNAVAILABLE("Unavailable"),
    LIVE("Live");

    /** Unavailable and live videos can't be downloaded at all */
    val selectable get() = this != UNAVAILABLE && this != LIVE
}

@Composable
private fun EntryRow(entry: PlaylistEntry, mark: Mark?, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val enabled = mark?.selectable != false
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(checked, enabled = enabled, role = Role.Checkbox, onValueChange = onCheckedChange)
            .padding(start = 4.dp, end = 16.dp, top = 4.dp, bottom = 4.dp)
            .alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked, onCheckedChange = null, enabled = enabled, modifier = Modifier.padding(12.dp))
        Thumbnail(entry.thumbnail, isAudio = false, width = 64, height = 36)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(entry.title, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val caption = listOfNotNull(entry.duration?.let(::formatDuration), mark?.label).joinToString(" · ")
            if (caption.isNotEmpty()) {
                Text(
                    caption, style = MaterialTheme.typography.bodySmall,
                    color = when (mark) {
                        null -> MaterialTheme.colorScheme.onSurfaceVariant
                        Mark.DOWNLOADED -> DoneColor
                        else -> WarningColor
                    },
                )
            }
        }
    }
}

/** "Channel · 42 videos · 3:12:08" */
private fun summary(playlist: PlaylistInfo): String {
    val total = playlist.entries.mapNotNull { it.duration }.sum()
    val count = if (playlist.entries.size == 1) "1 video" else "${playlist.entries.size} videos"
    return listOfNotNull(playlist.uploader, count, total.takeIf { it > 0 }?.let(::formatDuration)).joinToString(" · ")
}

private fun marks(playlist: PlaylistInfo, library: DownloadRepository.Library): Map<Int, Mark> {
    val seen = mutableSetOf<String>()
    return playlist.entries.mapNotNull { entry ->
        // Videos of one post share its link, so only their ids tell them apart
        val ids = if (entry.pick == null) listOfNotNull(entry.key, entry.url) else listOfNotNull(entry.key)
        val identity = entry.key ?: "${entry.url}#${entry.pick ?: 0}"
        val mark = when {
            entry.unavailable -> Mark.UNAVAILABLE
            entry.live -> Mark.LIVE
            !seen.add(identity) -> Mark.DUPLICATE
            ids.any { it in library.downloaded } -> Mark.DOWNLOADED
            ids.any { it in library.active } -> Mark.DOWNLOADING
            else -> null
        }
        mark?.let { entry.index to it }
    }.toMap()
}
