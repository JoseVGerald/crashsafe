package org.cac.crashsafe.features.carplay

import android.app.Activity
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.cac.crashsafe.core.driving.CoachingMessage
import org.cac.crashsafe.core.driving.DriveScenario
import org.cac.crashsafe.core.driving.DrivingAdvice
import org.cac.crashsafe.core.driving.DrivingComparison
import org.cac.crashsafe.core.driving.RoadEnvironment
import org.cac.crashsafe.core.util.Formats
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.services.driving.DrivingMonitor
import org.cac.crashsafe.services.driving.SpeedLimitService
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.PulseAvatar
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

/**
 * Drive mode: a glanceable, landscape-friendly dashboard that keeps monitoring (accelerometer + GPS + time of
 * day) and coaches the driver in the style their profile asks for. The same data reaches a car screen through
 * Android Auto (`CrashSafeCarAppService`); this is the phone's own version (iOS's CarPlay mode).
 */
@Composable
fun DriveModeScreen(user: AuthUser, onClose: () -> Unit) {
    val env = LocalEnvironment.current
    val profile = env.store.profile(user.id)
    val driving = env.driving
    val snapshot = driving.snapshot
    val isNight = driving.scenario?.isNight ?: env.conditions.isNight
    val advice = DrivingAdvice.make(env.conditions.weather, isNight)
    val comparison = DrivingComparison.make(snapshot, advice, driving.isActive)
    val statusColor = when (comparison.status) {
        DrivingComparison.Status.noData, DrivingComparison.Status.onTrack -> Brand.go
        DrivingComparison.Status.caution -> Brand.amber
        DrivingComparison.Status.tooFast -> Brand.stop
    }
    val context = LocalContext.current

    BackHandler(onBack = onClose)
    DisposableEffect(Unit) {
        // Keep the screen on, and always use real data: GPS speed, the posted limit and live weather.
        // Demo drives only run if one was started from Profile → Testing.
        val window = (context as? Activity)?.window
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val startedLive = !driving.isActive
        if (startedLive) driving.startLive(background = profile?.autoDetectDrives ?: true)
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (startedLive) driving.stop()
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Brand.background)) {
        val wide = maxWidth > maxHeight
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            TopBar(onClose)
            ConditionsRow(isNight)
            if (wide) {
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    SpeedPanel(comparison, statusColor, Modifier.weight(1f).fillMaxHeight(), fitHeight = true)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        CoachPanel(profile?.coachingStyle)
                        SensorsPanel()
                    }
                }
            } else {
                SpeedPanel(comparison, statusColor, Modifier.fillMaxWidth())
                CoachPanel(profile?.coachingStyle)
                SensorsPanel()
                Spacer(Modifier.weight(1f))
                if (driving.scenario != null) ScenarioBar()
            }
        }
    }
}

@Composable
private fun TopBar(onClose: () -> Unit) {
    val env = LocalEnvironment.current
    val driving = env.driving
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RoundButton("xmark", "Exit drive mode", onClose)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Drive mode", style = Type.headline, color = Color.White)
            Text(driving.scenario?.let { "Demo · ${it.title}" } ?: if (driving.mode == DrivingMonitor.Mode.Live) liveStatus() else "Starting…",
                style = Type.caption, color = Color.White.copy(alpha = 0.65f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        RoundButton(if (env.coach.speaks) "speaker.wave.2.fill" else "speaker.slash.fill", if (env.coach.speaks) "Mute Pulse" else "Unmute Pulse") {
            env.coach.updateSpeaks(!env.coach.speaks)
        }
    }
}

/** Where the live data is coming from, in plain words. */
@Composable
private fun liveStatus(): String {
    val env = LocalEnvironment.current
    val snapshot = env.driving.snapshot
    snapshot.roadSegment?.let { segment ->
        val extras = snapshot.roadFeatures.labels.joinToString("") { " · $it" }
        return "Live · ${segment.title}" + (snapshot.roadName?.let { " · $it" } ?: "") + extras
    }
    snapshot.roadName?.let { return "Live · $it" }
    return if (env.sensors.hasMotionHardware) "Live · GPS + motion sensors" else "Live · GPS"
}

@Composable
private fun RoundButton(icon: String, description: String, onClick: () -> Unit) {
    Box(Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).pressable(onClick = onClick)
        .semantics { contentDescription = description }, contentAlignment = Alignment.Center) {
        Icon(sf(icon), null, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun ConditionsRow(isNight: Boolean) {
    val env = LocalEnvironment.current
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Chip(env.driving.scenario?.demoClock ?: Formats.time(nowSeconds()), if (isNight) "moon.fill" else "sun.max.fill")
        env.conditions.weather?.let { weather ->
            Chip("${weather.temperatureF.toInt()}° ${weather.condition.label}", weather.condition.systemImage(weather.isDay))
        }
    }
}

@Composable
private fun Chip(text: String, icon: String) {
    Row(Modifier.heightIn(min = 36.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(sf(icon), null, tint = Color.White, modifier = Modifier.size(16.dp))
        Text(text, style = Type.subheadline.semibold(), color = Color.White, maxLines = 1)
    }
}

@Composable
private fun SpeedPanel(comparison: DrivingComparison, statusColor: Color, modifier: Modifier, fitHeight: Boolean = false) {
    val env = LocalEnvironment.current
    val snapshot = env.driving.snapshot
    val fraction by animateFloatAsState((snapshot.speedMPH / 90).toFloat().coerceIn(0f, 1f), spring(dampingRatio = 0.8f, stiffness = 120f), label = "speed")
    Column(modifier.clip(RoundedCornerShape(28.dp)).background(Color.White.copy(alpha = 0.06f)).padding(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // Side by side (landscape) the gauge shrinks to the panel's height so the speed signs stay in view.
        Box(Modifier.then(if (fitHeight) Modifier.weight(1f, fill = false) else Modifier).widthIn(max = 260.dp).fillMaxWidth()
            .aspectRatio(1f, matchHeightConstraintsFirst = fitHeight)
            .clearAndSetSemantics { contentDescription = "${snapshot.speedMPH.toInt()} miles per hour" }, contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize().padding(9.dp)) {
                val stroke = Stroke(width = 18.dp.toPx(), cap = StrokeCap.Round)
                drawArc(Color.White.copy(alpha = 0.1f), 135f, 270f, false, style = stroke, topLeft = Offset.Zero, size = Size(size.width, size.height))
                if (fraction > 0f) drawArc(statusColor, 135f, 270f * fraction, false, style = stroke, size = Size(size.width, size.height))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                AnimatedContent(snapshot.speedMPH.toInt(), transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "mph") { mph ->
                    Text("$mph", style = TextStyle(fontSize = if (fitHeight) 64.sp else 84.sp, fontWeight = FontWeight.Bold), color = Color.White)
                }
                Text("mph", style = Type.title3.semibold(), color = Color.White.copy(alpha = 0.6f))
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val limit = snapshot.speedLimitMPH
            if (limit != null) {
                SpeedSign(limit.toInt(), if (snapshot.speedLimitIsPosted) "LIMIT" else "TYPICAL")
            } else if (env.driving.mode == DrivingMonitor.Mode.Live) {
                SpeedSign(null, when (env.driving.speedLimits?.status) {
                    SpeedLimitService.Status.loading -> "FINDING"
                    SpeedLimitService.Status.failed -> "NO DATA"
                    else -> "LIMIT"
                })
            }
            comparison.recommendedMaxMPH?.let { SpeedSign(it.toInt(), "SAFE NOW", statusColor) }
        }
    }
}

/** US-style speed sign; `value` is null while the limit is being looked up. */
@Composable
private fun SpeedSign(value: Int?, label: String, tint: Color = Color.White) {
    Box(Modifier.size(78.dp, 64.dp).clip(RoundedCornerShape(10.dp)).background(tint).padding(3.dp)
        .border(2.dp, Color.Black, RoundedCornerShape(8.dp)).semantics(mergeDescendants = true) {}, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(label, style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Black, letterSpacing = 0.5.sp), color = Color.Black)
            Text(value?.toString() ?: "–", style = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Black, lineHeight = 30.sp), color = Color.Black)
        }
    }
}

private fun severityColor(severity: CoachingMessage.Severity) = when (severity) {
    CoachingMessage.Severity.positive -> Brand.go
    CoachingMessage.Severity.caution -> Brand.amber
    CoachingMessage.Severity.warning -> Brand.stop
}

@Composable
private fun CoachPanel(style: CoachingStyle?) {
    val env = LocalEnvironment.current
    val current = env.coach.message ?: CoachingMessage("Pulse is riding along",
        "I'll speak up if your driving doesn't match the road, the weather or the time of day.", CoachingMessage.Severity.positive)
    AnimatedContent(env.coach.messageID to current, transitionSpec = {
        (slideInVertically { it / 3 } + fadeIn()) togetherWith fadeOut()
    }, label = "coach") { (_, message) ->
        val tint = severityColor(message.severity)
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(28.dp)).background(tint.copy(alpha = 0.22f))
            .border(1.dp, tint.copy(alpha = 0.5f), RoundedCornerShape(28.dp)).padding(18.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            PulseAvatar(46.dp, active = message.severity != CoachingMessage.Severity.positive)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(message.title, style = Type.title3.bold(), color = Color.White, modifier = Modifier.weight(1f))
                    StatusChip(if (style == CoachingStyle.emotional) "Heart" else "Facts", style?.systemImage, Color.White)
                }
                Text(message.body, style = Type.body, color = Color.White.copy(alpha = 0.85f))
            }
        }
    }
}

@Composable
private fun SensorsPanel() {
    val env = LocalEnvironment.current
    val snapshot = env.driving.snapshot
    Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SensorTile("waveform.path.ecg", "g-force", String.format(java.util.Locale.US, "%.2f g", snapshot.currentG)) {
            Sparkline(env.driving.gHistory, Modifier.fillMaxWidth().height(30.dp))
        }
        SensorTile("exclamationmark.octagon.fill", "Brakes", "${snapshot.hardBrakes}")
        SensorTile(environmentIcon(snapshot.environment), "Road", snapshot.roadSegment?.title
            ?: if (snapshot.environment == RoadEnvironment.forest) "Wooded" else snapshot.environment.label.replaceFirstChar { it.uppercase() })
    }
}

private fun environmentIcon(environment: RoadEnvironment) = when (environment) {
    RoadEnvironment.forest -> "tree.fill"
    RoadEnvironment.highway -> "road.lanes"
    RoadEnvironment.city -> "building.2.fill"
}

@Composable
private fun RowScope.SensorTile(icon: String, title: String, value: String, extra: (@Composable () -> Unit)? = null) {
    Column(Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.06f)).padding(14.dp)
        .semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Icon(sf(icon), null, tint = Color.White.copy(alpha = 0.65f), modifier = Modifier.size(13.dp))
            Text(title, style = Type.caption.semibold(), color = Color.White.copy(alpha = 0.65f), maxLines = 1)
        }
        Text(value, style = Type.title3.bold(), color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
        extra?.invoke()
    }
}

/** Recent accelerometer magnitudes as a line. */
@Composable
private fun Sparkline(values: List<Double>, modifier: Modifier) {
    Canvas(modifier) {
        if (values.size < 2) return@Canvas
        val maxValue = maxOf(values.max(), 0.6)
        val path = Path()
        values.forEachIndexed { index, value ->
            val x = size.width * index / (values.size - 1)
            val y = size.height - size.height * (value / maxValue).coerceAtMost(1.0).toFloat()
            if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, Brand.tealInk, style = Stroke(width = 2.5.dp.toPx(), join = StrokeJoin.Round))
    }
}

@Composable
private fun ScenarioBar() {
    val env = LocalEnvironment.current
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        DriveScenario.entries.forEach { scenario ->
            val selected = env.driving.scenario == scenario
            Row(Modifier.heightIn(min = 44.dp).clip(CircleShape).background(if (selected) Color.White else Color.White.copy(alpha = 0.1f))
                .pressable {
                    env.driving.startDemo(scenario)
                    env.conditions.override(scenario.weather)
                }.padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val fg = if (selected) Color.Black else Color.White
                Icon(sf(scenario.systemImage), null, tint = fg, modifier = Modifier.size(16.dp))
                Text(scenario.title, style = Type.subheadline.semibold(), color = fg)
            }
        }
    }
}
