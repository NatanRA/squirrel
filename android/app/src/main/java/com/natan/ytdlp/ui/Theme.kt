package com.natan.ytdlp.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/** Colour for formats the device's own players can't play (matches iOS's orange). */
val WarningColor = Color(0xFFE8710A)

@Composable
fun YtdlpTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    // Material You: follows the wallpaper colours (minSdk 29 < 31, so fall back below 12)
    val colors = when {
        android.os.Build.VERSION.SDK_INT >= 31 ->
            if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        isSystemInDarkTheme() -> androidx.compose.material3.darkColorScheme()
        else -> androidx.compose.material3.lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}
