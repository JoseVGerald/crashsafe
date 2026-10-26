package org.cac.crashsafe.features.launch

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.sf

/** Short animated splash shown while the saved session is restored. */
@Composable
fun SplashScreen() {
    val appeared = remember { Animatable(0f) }
    LaunchedEffect(Unit) { appeared.animateTo(1f, spring(dampingRatio = 0.65f, stiffness = 120f)) }
    val pulse by rememberInfiniteTransition(label = "splash").animateFloat(0f, 1f,
        infiniteRepeatable(tween(1200, easing = LinearOutSlowInEasing), RepeatMode.Restart), label = "pulse")
    Box(Modifier.fillMaxSize().background(Brand.background).semantics(mergeDescendants = true) {
        contentDescription = "CrashSafe. Help for what happens next."
    }, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(200.dp)) {
                Canvas(Modifier.size(150.dp)) {
                    val scale = 0.9f + 0.45f * pulse
                    drawCircle(Brand.blueInk.copy(alpha = 0.4f * (1 - pulse)), radius = size.minDimension / 2 * scale, style = Stroke(3.dp.toPx()))
                }
                Icon(sf("checkmark.shield.fill"), null, tint = Brand.blueInk,
                    modifier = Modifier.size(96.dp).graphicsLayer { val s = 0.6f + 0.4f * appeared.value; scaleX = s; scaleY = s })
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.graphicsLayer { alpha = appeared.value.coerceIn(0f, 1f); translationY = (1 - appeared.value) * 12.dp.toPx() }) {
                Text("CrashSafe", style = Type.largeTitle.bold(), color = Brand.textPrimary)
                Text("Help for what happens next.", style = Type.headline, color = Brand.textSecondary)
            }
        }
    }
}
