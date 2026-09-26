package app.squirrel.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Colour for formats the device's own players can't play (matches iOS's orange). */
val WarningColor = Color(0xFFE8710A)

// Material 3 "fidelity" schemes generated from Squirrel's brand colour #B8532A
// (see branding/README.md), so the app looks the same on every phone.
private val LightColors = lightColorScheme(
    primary = Color(0xFF983C14),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFB8532A),
    onPrimaryContainer = Color(0xFFFFF5F2),
    secondary = Color(0xFF85513E),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFFDBAA1),
    onSecondaryContainer = Color(0xFF794835),
    tertiary = Color(0xFF006178),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFF007C98),
    onTertiaryContainer = Color(0xFFEEF9FF),
    background = Color(0xFFFFF8F6),
    onBackground = Color(0xFF231916),
    surface = Color(0xFFFFF8F6),
    onSurface = Color(0xFF231916),
    surfaceVariant = Color(0xFFFADCD2),
    onSurfaceVariant = Color(0xFF56423B),
    outline = Color(0xFF8A726A),
    outlineVariant = Color(0xFFDDC0B7),
    inverseSurface = Color(0xFF392E2A),
    inverseOnSurface = Color(0xFFFFEDE7),
    inversePrimary = Color(0xFFFFB59A),
    surfaceDim = Color(0xFFE9D6D0),
    surfaceBright = Color(0xFFFFF8F6),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFFFF1EC),
    surfaceContainer = Color(0xFFFEEAE3),
    surfaceContainerHigh = Color(0xFFF8E4DE),
    surfaceContainerHighest = Color(0xFFF2DED8),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFFFB59A),
    onPrimary = Color(0xFF5B1B00),
    primaryContainer = Color(0xFFB8532A),
    onPrimaryContainer = Color(0xFFFFF5F2),
    secondary = Color(0xFFFAB79F),
    onSecondary = Color(0xFF4E2515),
    secondaryContainer = Color(0xFF693A29),
    onSecondaryContainer = Color(0xFFE7A68E),
    tertiary = Color(0xFF79D2F1),
    onTertiary = Color(0xFF003543),
    tertiaryContainer = Color(0xFF007C98),
    onTertiaryContainer = Color(0xFFEEF9FF),
    background = Color(0xFF1B110E),
    onBackground = Color(0xFFF2DED8),
    surface = Color(0xFF1B110E),
    onSurface = Color(0xFFF2DED8),
    surfaceVariant = Color(0xFF56423B),
    onSurfaceVariant = Color(0xFFDDC0B7),
    outline = Color(0xFFA58B83),
    outlineVariant = Color(0xFF56423B),
    inverseSurface = Color(0xFFF2DED8),
    inverseOnSurface = Color(0xFF392E2A),
    inversePrimary = Color(0xFF9F4119),
    surfaceDim = Color(0xFF1B110E),
    surfaceBright = Color(0xFF433632),
    surfaceContainerLowest = Color(0xFF150C09),
    surfaceContainerLow = Color(0xFF231916),
    surfaceContainer = Color(0xFF281D1A),
    surfaceContainerHigh = Color(0xFF332724),
    surfaceContainerHighest = Color(0xFF3E322E),
)

@Composable
fun SquirrelTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}
