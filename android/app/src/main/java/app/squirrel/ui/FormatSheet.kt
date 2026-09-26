package app.squirrel.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.squirrel.data.FormatChoice
import app.squirrel.data.VideoInfo

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FormatSheet(info: VideoInfo, onDismiss: () -> Unit, onPick: (FormatChoice) -> Unit) {
    val video = info.choices.filterNot { it.isAudio }
    val audio = info.choices.filter { it.isAudio }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState()) {
        LazyColumn(contentPadding = PaddingValues(bottom = 16.dp), modifier = Modifier.navigationBarsPadding()) {
            item {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.Top) {
                    Thumbnail(info.thumbnail, video.isEmpty(), width = 128, height = 72)
                    Spacer(Modifier.width(12.dp))
                    Column {
                        Text(
                            info.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                            maxLines = 3, overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            listOfNotNull(info.uploader, info.duration?.let(::formatDuration)).joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            if (video.isNotEmpty()) {
                item { SectionHeader("Video") }
                items(video, key = { it.id }) { ChoiceRow(it, onPick) }
            }
            if (audio.isNotEmpty()) {
                item { SectionHeader("Audio Only") }
                items(audio, key = { it.id }) { ChoiceRow(it, onPick) }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun ChoiceRow(choice: FormatChoice, onPick: (FormatChoice) -> Unit) {
    ListItem(
        modifier = Modifier.clickable { onPick(choice) },
        leadingContent = {
            Icon(if (choice.isAudio) Icons.Default.MusicNote else Icons.Default.PlayCircleOutline, null)
        },
        headlineContent = { Text(choice.label) },
        supportingContent = {
            Text(
                choice.detail,
                color = if (choice.playable == false) WarningColor else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        trailingContent = { Icon(Icons.Outlined.Download, "Download", tint = MaterialTheme.colorScheme.primary) },
    )
}

private fun formatDuration(seconds: Double): String {
    val total = seconds.toInt()
    val (h, m, s) = Triple(total / 3600, total / 60 % 60, total % 60)
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
