package com.natan.ytdlp.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

/**
 * The launch animation: the squirrel hops up, fluffs out its tail, tilts its head and gives a
 * little hop of joy, then the app appears. About a second; tap to skip. With [animate] off
 * (animations disabled) it shows the finished pose briefly instead. Mirrors LaunchSplash.swift.
 */
@Composable
fun LaunchSplash(animate: Boolean, onFinished: () -> Unit) {
    val dark = isSystemInDarkTheme()
    // Matches the window background (launch_background) so there's no flash
    val background = if (dark) Color(0xFF1E1712) else Color(0xFFFFF7F0)
    val wordmarkColor = if (dark) Color(0xFFF2976F) else Color(0xFFA8461F)
    val time = remember { Animatable(0f) }

    LaunchedEffect(Unit) {
        if (animate) {
            time.animateTo(SquirrelMotion.DURATION, tween((SquirrelMotion.DURATION * 1000).toInt(), easing = LinearEasing))
        } else {
            time.snapTo(SquirrelMotion.DURATION)
            delay(500)
        }
        onFinished()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(background)
            .clickable(remember { MutableInteractionSource() }, indication = null, onClick = onFinished),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            // Both read the time while drawing, so the animation redraws without recomposing
            Canvas(Modifier.size(190.dp)) { drawSquirrel(time.value, background) }
            Text(
                "Squirrel",
                color = wordmarkColor,
                fontSize = 34.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.graphicsLayer {
                    val shown = SquirrelMotion.wordmark(time.value)
                    alpha = shown
                    translationY = 10.dp.toPx() * (1 - shown)
                },
            )
        }
    }
}

/** The launch animation's timeline, in seconds: where each part of the squirrel is at time `t`. */
internal object SquirrelMotion {
    const val DURATION = 1.15f

    class Hop(val y: Float, val scaleX: Float, val scaleY: Float, val alpha: Float)
    class Tail(val scale: Float, val degrees: Float, val alpha: Float)

    /** Rises from below with a fade, overshoots, and lands with a squash. */
    fun hop(t: Float): Hop {
        val y = if (t < 0.3f) mix(70f, -12f, easeOut(progress(t, 0f, 0.3f))) else mix(-12f, 0f, easeIn(progress(t, 0.3f, 0.4f)))
        val squash = if (t < 0.48f) easeOut(progress(t, 0.4f, 0.48f)) else 1 - progress(t, 0.48f, 0.56f)
        return Hop(y, 1 + 0.06f * squash, 1 - 0.07f * squash, progress(t, 0f, 0.15f))
    }

    /** Grows out from its base while swinging up, overshoots, and settles. */
    fun tail(t: Float): Tail {
        val grow = easeOut(progress(t, 0.12f, 0.42f))
        val settle = progress(t, 0.42f, 0.52f)
        return Tail(mix(mix(0.2f, 1.08f, grow), 1f, settle), mix(mix(-35f, 6f, grow), 0f, settle), progress(t, 0.12f, 0.2f))
    }

    fun headDegrees(t: Float) = -8 * easeOut(progress(t, 0.6f, 0.72f)) + 8 * easeInOut(progress(t, 0.86f, 0.98f))

    /** Body and hands only, so the head stays put while it hops. */
    fun joy(t: Float) = -5 * easeOut(progress(t, 0.68f, 0.76f)) + 5 * easeIn(progress(t, 0.76f, 0.84f))

    fun earDegrees(t: Float) = when {
        t < 0.9f -> 14 * easeOut(progress(t, 0.86f, 0.9f))
        t < 0.95f -> mix(14f, -5f, progress(t, 0.9f, 0.95f))
        else -> mix(-5f, 0f, progress(t, 0.95f, 1f))
    }

    fun wordmark(t: Float) = easeOut(progress(t, 0.45f, 0.7f))

    private fun progress(t: Float, from: Float, to: Float) = ((t - from) / (to - from)).coerceIn(0f, 1f)
    private fun mix(a: Float, b: Float, x: Float) = a + (b - a) * x
    private fun easeOut(x: Float) = 1 - (1 - x) * (1 - x) * (1 - x)
    private fun easeIn(x: Float) = x * x * x
    private fun easeInOut(x: Float) = if (x < 0.5f) 4 * x * x * x else 1 - (-2 * x + 2).let { it * it * it } / 2
}

/** One filled or stroked shape of [SquirrelArt]. */
internal class SquirrelShape(d: String, fill: Long? = null, alpha: Float = 1f, stroke: Long? = null, val width: Float = 0f) {
    val path = svgPath(d)
    val fill = fill?.let { Color(it).copy(alpha = alpha) }
    val stroke = stroke?.let { Color(it) }
}

private fun svgPath(d: String): Path = PathParser().parsePathString(d).toPath()

private val bodyOutline by lazy { SquirrelArt.bodyOutline.map(::svgPath) }
private val headOutline by lazy { SquirrelArt.headOutline.map(::svgPath) }

/** The squirrel from [SquirrelArt], posed for time `t`; [background] also fills the outline between head, body and tail. */
private fun DrawScope.drawSquirrel(t: Float, background: Color) {
    val hop = SquirrelMotion.hop(t)
    val tail = SquirrelMotion.tail(t)
    scale(size.width / 240, size.height / 240, pivot = Offset.Zero) {
        translate(top = hop.y) {
            scale(hop.scaleX, hop.scaleY, pivot = SquirrelArt.allPivot) {
                withTransform({
                    rotate(tail.degrees, SquirrelArt.tailPivot)
                    scale(tail.scale, tail.scale, SquirrelArt.tailPivot)
                }) { shapes(SquirrelArt.tail, hop.alpha * tail.alpha) }

                translate(top = SquirrelMotion.joy(t)) {
                    outline(bodyOutline, background, hop.alpha)
                    shapes(SquirrelArt.body, hop.alpha)
                }
                rotate(SquirrelMotion.headDegrees(t), SquirrelArt.headPivot) {
                    outline(headOutline, background, hop.alpha)
                    rotate(SquirrelMotion.earDegrees(t), SquirrelArt.earPivot) { shapes(SquirrelArt.ear, hop.alpha) }
                    shapes(SquirrelArt.head, hop.alpha)
                }
                translate(top = SquirrelMotion.joy(t)) { shapes(SquirrelArt.hands, hop.alpha) }
            }
        }
    }
}

private fun DrawScope.shapes(shapes: List<SquirrelShape>, alpha: Float) {
    for (shape in shapes) {
        shape.fill?.let { drawPath(shape.path, it, alpha = alpha) }
        shape.stroke?.let { drawPath(shape.path, it, alpha = alpha, style = Stroke(shape.width, cap = StrokeCap.Round)) }
    }
}

private fun DrawScope.outline(paths: List<Path>, color: Color, alpha: Float) {
    for (path in paths) {
        drawPath(path, color, alpha = alpha)
        drawPath(path, color, alpha = alpha, style = Stroke(SquirrelArt.OUTLINE_WIDTH, join = StrokeJoin.Round))
    }
}
