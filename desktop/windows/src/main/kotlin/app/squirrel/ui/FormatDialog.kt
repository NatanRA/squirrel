package app.squirrel.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.squirrel.AppSettings
import app.squirrel.DownloadItem
import app.squirrel.DownloadStore
import app.squirrel.FormatChoice
import app.squirrel.VideoInfo
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The video's download choices. [downloaded] is an earlier download of it whose file is still
 * there; [onWholePlaylist] opens the playlist the link also names.
 */
@Composable
fun FormatDialog(
    info: VideoInfo,
    downloaded: DownloadItem?,
    onDismiss: () -> Unit,
    onWholePlaylist: (String) -> Unit,
    onPick: (FormatChoice) -> Unit,
) {
    val video = info.choices.filter { !it.isAudio }
    val audio = info.choices.filter { it.isAudio }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = {
            Row {
                info.playlistUrl?.let { url ->
                    TextButton(onClick = { onWholePlaylist(url) }) { Text("Whole Playlist…") }
                }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Thumbnail(info.thumbnail, video.isEmpty(), width = 112, height = 63)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(info.title, style = MaterialTheme.typography.titleMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    val meta = listOfNotNull(info.uploader, info.duration?.let(::formatDuration)).joinToString(" · ")
                    if (meta.isNotEmpty()) {
                        Text(meta, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    subtitleNote(info, hasVideo = video.isNotEmpty())?.let { note ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Subtitles, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(Modifier.width(4.dp))
                            Text(note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        },
        text = {
            Column {
                downloaded?.let { DownloadedNotice(it) }
                LazyColumn(Modifier.heightIn(max = 360.dp)) {
                    if (video.isNotEmpty()) {
                        item { SectionTitle("Video") }
                        items(video) { Choice(it, onPick) }
                    }
                    if (audio.isNotEmpty()) {
                        item { SectionTitle("Audio Only") }
                        items(audio) { Choice(it, onPick) }
                    }
                }
            }
        },
    )
}

/** "With English subtitles": what Settings adds to a video download of this one */
private fun subtitleNote(info: VideoInfo, hasVideo: Boolean): String? {
    if (!AppSettings.subtitles || !hasVideo) return null
    val languages = AppSettings.subtitleLanguages.filter {
        it in info.subtitleLanguages || AppSettings.autoCaptions && it in info.captionLanguages
    }
    return if (languages.isEmpty()) null else "With ${languageNames(languages)} subtitles"
}

/** "Downloaded Sep 27, 2026": downloading it again is still allowed. */
@Composable
private fun DownloadedNotice(item: DownloadItem) {
    val date = Instant.ofEpochMilli(item.createdAt).atZone(ZoneId.systemDefault())
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.CheckCircle, null, Modifier.size(18.dp), tint = DoneColor)
        Spacer(Modifier.width(6.dp))
        Text(
            "Downloaded ${DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).format(date)}",
            style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f),
        )
        TextButton(onClick = { DownloadStore.reveal(item) }) { Text("Show in Folder") }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
    )
}

@Composable
private fun Choice(choice: FormatChoice, onPick: (FormatChoice) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { onPick(choice) }.padding(vertical = 8.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (choice.isAudio) Icons.Default.MusicNote else Icons.Default.PlayCircleOutline, null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.width(12.dp))
        Column {
            Text(choice.label, fontWeight = FontWeight.Medium)
            Text(
                choice.detail, style = MaterialTheme.typography.bodySmall,
                color = if (choice.playable == false) WarningColor else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
