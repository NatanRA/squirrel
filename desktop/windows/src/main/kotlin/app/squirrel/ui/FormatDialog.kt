package app.squirrel.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
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
import app.squirrel.FormatChoice
import app.squirrel.VideoInfo

@Composable
fun FormatDialog(info: VideoInfo, onDismiss: () -> Unit, onPick: (FormatChoice) -> Unit) {
    val video = info.choices.filter { !it.isAudio }
    val audio = info.choices.filter { it.isAudio }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Thumbnail(info.thumbnail, video.isEmpty(), width = 112, height = 63)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(info.title, style = MaterialTheme.typography.titleMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    val meta = listOfNotNull(info.uploader, info.duration?.let(::duration)).joinToString(" · ")
                    if (meta.isNotEmpty()) {
                        Text(meta, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        },
        text = {
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
        },
    )
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

private fun duration(seconds: Double): String {
    val total = seconds.toInt()
    val (h, m, s) = Triple(total / 3600, total / 60 % 60, total % 60)
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
