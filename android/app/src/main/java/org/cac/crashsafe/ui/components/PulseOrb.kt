package org.cac.crashsafe.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.sf
import kotlin.math.PI
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** What Pulse is doing, shown by the orb on every AI control. */
enum class PulseOrbMood {
    idle, listening, thinking, speaking;

    /** Ring colour around the orb: blue at rest, red while the mic is open, green while Pulse talks. */
    val ringTint: Color
        get() = when (this) {
            listening -> Brand.redInk
            speaking -> Brand.greenInk
            idle, thinking -> Brand.blueInk
        }
}

private data class Dot(val x: Double, val y: Double, val z: Double)

/** Points spread evenly over a sphere (golden-angle spiral). */
private fun sphere(count: Int): List<Dot> {
    val golden = PI * (3 - sqrt(5.0))
    return (0 until count).map { i ->
        val y = 1 - 2 * (i + 0.5) / count
        val r = sqrt(1 - y * y)
        val theta = golden * i
        Dot(cos(theta) * r, y, sin(theta) * r)
    }
}

/**
 * Pulse's animated orb: a sphere of white dots that turns slowly at rest, ripples while listening, swirls
 * while thinking and breathes while speaking. Decorative: the control around it carries the label.
 */
@Composable
fun PulseOrb(mood: PulseOrbMood = PulseOrbMood.idle, size: Dp, animated: Boolean = true, modifier: Modifier = Modifier) {
    val dots = remember(size) { sphere(if (size >= 40.dp) 140 else 60) }
    val transition = rememberInfiniteTransition(label = "orb")
    val time by transition.animateFloat(0f, 1000f, infiniteRepeatable(tween(1_000_000, easing = LinearEasing), RepeatMode.Restart), label = "t")
    Canvas(modifier.size(size)) {
        val t = if (animated) time.toDouble() else 0.0
        val speed = when (mood) {
            PulseOrbMood.idle -> 0.25
            PulseOrbMood.listening -> 0.45
            PulseOrbMood.thinking -> 1.4
            PulseOrbMood.speaking -> 0.5
        }
        val breathe = when (mood) {
            PulseOrbMood.speaking -> 1 + 0.08 * sin(t * 4.2)
            PulseOrbMood.idle -> 1 + 0.02 * sin(t * 1.5)
            else -> 1.0
        }
        val radius = this.size.minDimension / 2 * 0.86 * breathe
        val center = Offset(this.size.width / 2, this.size.height / 2)
        val angle = t * speed
        val tilt = 0.45
        val dotRadius = (this.size.minDimension / 64).coerceAtLeast(0.8f)
        for (dot in dots) {
            // Rotate about y, then tilt toward the viewer.
            var x = dot.x * cos(angle) + dot.z * sin(angle)
            var z = -dot.x * sin(angle) + dot.z * cos(angle)
            var y = dot.y
            val y2 = y * cos(tilt) - z * sin(tilt)
            z = y * sin(tilt) + z * cos(tilt)
            y = y2
            var r = 1.0
            when (mood) {
                PulseOrbMood.listening -> r += 0.07 * sin(acos(y.coerceIn(-1.0, 1.0)) * 6 - t * 5)
                PulseOrbMood.thinking -> {
                    val swirl = 0.6 * sin(t * 2 + y * 3)
                    val sx = x * cos(swirl) - z * sin(swirl)
                    z = x * sin(swirl) + z * cos(swirl)
                    x = sx
                }
                else -> {}
            }
            val depth = ((z + 1) / 2).toFloat() // 0 back … 1 front
            drawCircle(Color.White.copy(alpha = 0.15f + 0.85f * depth * depth),
                radius = dotRadius * (0.6f + 0.6f * depth),
                center = Offset((center.x + x * radius * r).toFloat(), (center.y + y * radius * r).toFloat()))
        }
    }
}

/** The orb on a near-black disc with a thin coloured ring — the dots need a dark backdrop to read. */
@Composable
fun PulseOrbDisc(mood: PulseOrbMood = PulseOrbMood.idle, diameter: Dp, animated: Boolean = true, modifier: Modifier = Modifier) {
    val ring by animateColorAsState(mood.ringTint.copy(alpha = 0.75f), tween(200), label = "ring")
    Box(modifier
        .size(diameter)
        .clip(CircleShape)
        .background(Brand.navy)
        .border(max(1.5.dp, diameter * 0.03f), ring, CircleShape),
        contentAlignment = Alignment.Center) {
        PulseOrb(mood, diameter * 0.7f, animated)
    }
}

/** The face of a Pulse voice button: the orb disc plus a small mic badge so it still reads as "talk". */
@Composable
fun PulseVoiceFace(mood: PulseOrbMood, diameter: Dp, showsMicBadge: Boolean = true, badge: String = "mic.fill", modifier: Modifier = Modifier) {
    Box(modifier.size(diameter)) {
        PulseOrbDisc(mood, diameter)
        if (showsMicBadge && mood == PulseOrbMood.idle) {
            Box(Modifier
                .align(Alignment.BottomEnd)
                .offset(diameter * 0.04f, diameter * 0.04f)
                .size(diameter * 0.34f)
                .clip(CircleShape)
                .background(Brand.blue)
                .border(2.dp, Brand.background, CircleShape),
                contentAlignment = Alignment.Center) {
                Icon(sf(badge), null, tint = Color.White, modifier = Modifier.size(diameter * 0.17f))
            }
        }
    }
}

/** Pulse's avatar: the orb on a disc, with rings while it works. */
@Composable
fun PulseAvatar(size: Dp = 32.dp, active: Boolean = false, listening: Boolean = false, animated: Boolean = true) {
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        PulseRings(Brand.blue, count = 2, active = active, modifier = Modifier.size(size))
        PulseOrbDisc(if (listening) PulseOrbMood.listening else if (active) PulseOrbMood.thinking else PulseOrbMood.idle, size,
            animated = animated || active)
    }
}
