package org.cac.crashsafe.features.sensorlab

import android.os.SystemClock
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.invisibleToUser
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.core.crash.CrashAssessment
import org.cac.crashsafe.core.crash.CrashDataIssue
import org.cac.crashsafe.core.crash.CrashDecision
import org.cac.crashsafe.core.crash.CrashEvaluationConfiguration
import org.cac.crashsafe.core.crash.RealCrashPulse
import org.cac.crashsafe.core.crash.CrashEvidence
import org.cac.crashsafe.core.crash.SensorScenario
import org.cac.crashsafe.core.intelligence.TransportClass
import org.cac.crashsafe.core.intelligence.TransportFeatures
import org.cac.crashsafe.core.roads.RoadMatcher
import org.cac.crashsafe.core.sensors.Jolt
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorLabMath
import org.cac.crashsafe.core.sensors.SensorState
import org.cac.crashsafe.core.sensors.SensorVector
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.BrandSwitch
import org.cac.crashsafe.ui.components.ChoiceMenu
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.MenuItem
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.TopBar
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Profile → Testing → Sensor lab: everything the phone's motion sensors and GPS measure, live — how it's tilted,
 * how hard it's shaken or turned, quick jolts, speed — plus what the crash detector would make of it,
 * recordings to share, and replays of real crashes and everyday motion.
 */
@Composable
fun SensorLabScreen(onClose: () -> Unit) {
    val env = LocalEnvironment.current
    val lab = env.sensorLab
    DisposableEffect(Unit) {
        lab.start()
        onDispose { lab.stop() }
    }
    // High-rate values (the motion ring, peaks) aren't snapshot state: cards that show them take the frame
    // counter, which changes as readings arrive (at most 20 times a second), and redraw with it.
    val frame = lab.frame
    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding()) {
        TopBar("Sensor lab", leading = BarAction("Reset", icon = "arrow.counterclockwise") { lab.resetPeaks() },
            trailing = BarAction("Done", bold = true, run = onClose))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            ReadableColumn(spacing = Space.md, modifier = Modifier.padding(bottom = Space.lg)) {
                Status(lab)
                ReplayCard(lab)
                TiltCard(lab, frame)
                MotionCard(lab, frame)
                RotationCard(lab, frame)
                JoltsCard(lab, frame)
                CrashCheckCard(lab)
                SpeedCard(lab, frame)
                RecordCard(lab, frame)
                Text("Bundled clips: real walking and jogging from MotionSense (MIT license, Malekzadeh et al.); the real crash is NHTSA crash test 7605 (public domain). Generated events use simple physics with random speeds, mounts and noise.",
                    style = Type.caption, color = Brand.textSecondary, modifier = Modifier.padding(horizontal = Space.xs))
            }
        }
    }
}

// Status

@Composable
private fun Status(lab: SensorLabModel) {
    val env = LocalEnvironment.current
    val health = env.sensors.health
    val (text, icon, tint) = if (lab.isReplaying) Triple("Replaying", "play.circle.fill", Brand.amberInk) else when (health.state) {
        SensorState.active -> Triple("Live", "dot.radiowaves.left.and.right", Brand.greenInk)
        SensorState.unavailable -> Triple("No motion sensor here", "iphone.slash", Brand.textSecondary)
        SensorState.permissionDenied -> Triple("Motion access off", "hand.raised.fill", Brand.redInk)
        SensorState.starting -> Triple("Starting…", "hourglass", Brand.textSecondary)
        else -> Triple("Paused", "pause.circle", Brand.amberInk)
    }
    Column(Modifier.padding(top = Space.sm), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusChip(text, icon, tint)
            Box(Modifier.weight(1f))
            Text("${health.requestedHz.toInt()} Hz asked · ${fmt(health.measuredHz, 1)} Hz measured", style = Type.caption, color = Brand.textSecondary)
        }
        Text("Gaps ${health.motionGaps} · rejected ${health.rejectedMotionSamples} motion, ${health.rejectedLocationSamples} GPS",
            style = Type.caption, color = Brand.textSecondary)
        env.intelligence.current?.let { current ->
            val best = current.probabilities.indices.maxByOrNull { current.probabilities[it] }
            val mode = best?.let { TransportClass.entries.getOrNull(it) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(sf(mode?.systemImage ?: "questionmark.circle"), null, tint = Brand.textPrimary, modifier = Modifier.size(16.dp))
                Text("Moving like: ${mode?.title ?: "–"} ${(current.probability * 100).roundToInt()}%" +
                    if (current.transportClass == null) " (not sure yet)" else "", style = Type.footnote.semibold(), color = Brand.textPrimary)
            }
        }
        if (health.state == SensorState.unavailable && !lab.isReplaying) {
            Text("This device has no motion sensor (the emulator's are virtual). Replay a clip below to feed the app real or generated motion.",
                style = Type.footnote, color = Brand.textSecondary)
        }
    }
}

// Replay

@Composable
private fun ReplayCard(lab: SensorLabModel) {
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Replay", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            if (lab.isReplaying) LinkButton("Stop", { lab.stopReplay() }, color = Brand.redInk, icon = "stop.fill")
        }
        Text(lab.replayTitle ?: "Feeds motion into the app as if the phone sensed it: through the same pipeline, in real time.",
            style = Type.footnote, color = Brand.textSecondary)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Also run the real check-in", style = Type.subheadline.medium(), color = Brand.textPrimary)
                Text(if (lab.replayTriggersCheckIn)
                    "During a watched drive, a replayed crash starts the real “Are you okay?” flow, and contacts are alerted if no one answers."
                else "Off: replays only show here and never start a check-in or alert anyone.",
                    style = Type.caption, color = if (lab.replayTriggersCheckIn) Brand.amberInk else Brand.textSecondary)
            }
            BrandSwitch(lab.replayTriggersCheckIn, { lab.replayTriggersCheckIn = it }, Modifier.semantics { contentDescription = "Also run the real check-in" })
        }
        Box {
            LinkButton("Choose a clip", { menu = true }, icon = "play.circle")
            val items = buildList {
                add(MenuItem(RealCrashPulse.title, "car.side.rear.and.collision.and.car.side.front", "Real data") { lab.play(SensorLabModel.Source.RealCrash) })
                SensorLabModel.bundledClips.forEach { (name, title) ->
                    add(MenuItem(title, if ("jog" in name) "figure.run" else "figure.walk", "Real data") { lab.play(SensorLabModel.Source.Bundled(name)) })
                }
                SensorScenario.Kind.entries.filter { it.isCrash }.forEach { kind ->
                    add(MenuItem(kind.title, section = "Generated crashes") { lab.play(SensorLabModel.Source.Generated(kind)) })
                }
                SensorScenario.Kind.entries.filter { !it.isCrash }.forEach { kind ->
                    add(MenuItem(kind.title, section = "Generated look-alikes") { lab.play(SensorLabModel.Source.Generated(kind)) })
                }
                lab.recordings.forEach { file ->
                    add(MenuItem(file.nameWithoutExtension, "waveform.path", "Your recordings") { lab.play(SensorLabModel.Source.Recorded(file)) })
                }
            }
            ChoiceMenu(menu, { menu = false }, items)
        }
    }
}

// Tilt

@Composable
private fun TiltCard(lab: SensorLabModel, frame: Long) {
    val tilt = remember(frame) { lab.tilt }
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Tilt", style = Type.headline, color = Brand.textPrimary)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.lg)) {
            TiltDial(tilt, Modifier.size(132.dp))
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Metric("Forward / back", tilt?.let { angle(it.pitch, "top up", "top down") })
                Metric("Side to side", tilt?.let { angle(it.roll, "right down", "left down") })
                Metric("From flat", tilt?.let { "${it.fromFlat.roundToInt()}°" + if (it.fromFlat > 150) " · face down" else "" })
            }
        }
        Text("The bubble floats to the raised edge; the arrow points down. From the gravity vector Android separates from your own movement.",
            style = Type.caption, color = Brand.textSecondary)
    }
}

private fun angle(degrees: Double, positive: String, negative: String): String {
    val d = degrees.roundToInt()
    return if (d == 0) "0° level" else "${abs(d)}° ${if (d > 0) positive else negative}"
}

/** Bubble level plus a "down" arrow, from the gravity vector projected onto the screen. */
@Composable
private fun TiltDial(tilt: SensorLabMath.Tilt?, modifier: Modifier) {
    val (bx, by) = tilt?.bubble ?: (0.0 to 0.0)
    val level = abs(bx) < 0.05 && abs(by) < 0.05
    Canvas(modifier.clearAndSetSemantics {
        contentDescription = tilt?.let { "Tilt: ${it.pitch.roundToInt()} degrees forward, ${it.roll.roundToInt()} degrees sideways" } ?: "Tilt unknown"
    }) {
        val r = size.minDimension / 2
        val c = Offset(r, r)
        drawCircle(Brand.fieldFill, r, c)
        drawCircle(Brand.stroke, r - 0.5.dp.toPx(), c, style = Stroke(1.dp.toPx()))
        drawCircle(Brand.textSecondary.copy(alpha = 0.4f), r * 0.25f, c, style = Stroke(1.dp.toPx()))
        val guide = Brand.textSecondary.copy(alpha = 0.25f)
        drawLine(guide, Offset(r, r * 0.15f), Offset(r, r * 1.85f), 1.dp.toPx())
        drawLine(guide, Offset(r * 0.15f, r), Offset(r * 1.85f, r), 1.dp.toPx())
        // Down arrow: opposite the bubble.
        drawLine(Brand.textSecondary, c, Offset((r - bx * r * 0.85).toFloat(), (r - by * r * 0.85).toFloat()), 2.dp.toPx(), StrokeCap.Round)
        drawCircle(if (level) Brand.green else Brand.blue, r * 0.21f, Offset((r + bx * r * 0.75).toFloat(), (r + by * r * 0.75).toFloat()))
    }
}

// Motion

@Composable
private fun MotionCard(lab: SensorLabModel, frame: Long) {
    val samples = remember(frame) { lab.motion.values }
    val latest = samples.lastOrNull()
    val split = latest?.let { SensorLabMath.split(it.accelerationG, it.gravityG) }
    val threshold = CrashEvaluationConfiguration().candidateG
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        CardTitle("Acceleration", "g, gravity removed · last 5 s")
        AxisGraph(samples, { it.accelerationG }, minimumRange = 1.0, guides = listOf(1.0, threshold), Modifier.fillMaxWidth().height(140.dp))
        AxisLegend()
        MetricRow {
            Metric("Now", latest?.let { g(it.accelerationG.magnitude) }, Modifier.weight(1f))
            Metric("Peak", g(lab.peakG), Modifier.weight(1f))
            Metric("Jerk", "${lab.tracker.jerk.roundToInt()} g/s", Modifier.weight(1f))
        }
        MetricRow {
            Metric("Sideways", split?.let { g(it.first) }, Modifier.weight(1f))
            Metric("Up / down", split?.let { g(it.second) }, Modifier.weight(1f))
            Metric("Total", latest?.let { g(it.totalAccelerationG.magnitude) }, Modifier.weight(1f))
        }
        Text("Sideways is braking, speeding up and turning, whichever way the phone sits; up/down is bumps and drops. A crash check starts at ${threshold.toInt()} g (dashed line). Total reads ~1 g at rest and ~0 in free fall.",
            style = Type.caption, color = Brand.textSecondary)
    }
}

@Composable
private fun RotationCard(lab: SensorLabModel, frame: Long) {
    val samples = remember(frame) { lab.motion.values }
    val rotation = samples.lastOrNull()?.rotationRate
    val threshold = CrashEvaluationConfiguration().rotationRadPerSecond
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        CardTitle("Rotation (gyroscope)", "°/s · last 5 s")
        AxisGraph(samples, { it.rotationRate * (180 / PI) }, minimumRange = 90.0, guides = listOf(threshold * 180 / PI),
            Modifier.fillMaxWidth().height(120.dp))
        AxisLegend(listOf("tilt fwd/back", "tilt side", "turn"))
        MetricRow {
            Metric("Now", rotation?.let { degreesPerSecond(it.magnitude) }, Modifier.weight(1f))
            Metric("Peak", degreesPerSecond(lab.peakRotation), Modifier.weight(1f))
            Metric("Turning", rotation?.let { degreesPerSecond(abs(it.z)) }, Modifier.weight(1f))
        }
        Text("Spinning faster than ${(threshold * 180 / PI).toInt()}°/s (dashed) counts as rapid rotation in a crash check.",
            style = Type.caption, color = Brand.textSecondary)
    }
}

private val axisColors = listOf(Brand.red, Brand.green, Brand.blue)

/** Three axes over the last 5 s, scaled to fit, with dashed guide lines at ±each guide value. */
@Composable
private fun AxisGraph(samples: List<MotionSample>, value: (MotionSample) -> SensorVector, minimumRange: Double, guides: List<Double>, modifier: Modifier) {
    val measurer = rememberTextMeasurer()
    Canvas(modifier.clip(RoundedCornerShape(Radius.small)).background(Brand.fieldFill.copy(alpha = 0.5f)).semantics { invisibleToUser() }) {
        val last = samples.lastOrNull()?.uptime ?: return@Canvas
        val window = 5.0
        val visible = samples.filter { it.uptime >= last - window }
        val values = visible.map(value)
        val peak = values.maxOfOrNull { maxOf(abs(it.x), abs(it.y), abs(it.z)) } ?: 0.0
        val range = max(minimumRange, peak * 1.15)
        fun y(v: Double) = (size.height / 2 - (v / range) * size.height / 2).toFloat()
        fun x(t: Double) = ((t - (last - window)) / window * size.width).toFloat()
        drawLine(Brand.textSecondary.copy(alpha = 0.3f), Offset(0f, size.height / 2), Offset(size.width, size.height / 2), 1.dp.toPx())
        val dash = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))
        guides.filter { it < range }.forEach { guide ->
            listOf(guide, -guide).forEach { v ->
                drawLine(Brand.textSecondary.copy(alpha = 0.45f), Offset(0f, y(v)), Offset(size.width, y(v)), 1.dp.toPx(), pathEffect = dash)
            }
        }
        // Thin out to about one point per pixel.
        val step = max(1, visible.size / max(size.width.toInt(), 1))
        axisColors.forEachIndexed { axis, color ->
            val path = Path()
            var i = 0
            while (i < visible.size) {
                val v = values[i]
                val component = when (axis) { 0 -> v.x; 1 -> v.y; else -> v.z }
                if (i == 0) path.moveTo(x(visible[i].uptime), y(component)) else path.lineTo(x(visible[i].uptime), y(component))
                i += step
            }
            drawPath(path, color, style = Stroke(1.5.dp.toPx()))
        }
        drawText(measurer, "±" + fmt(range, if (range < 10) 1 else 0), Offset(4.dp.toPx(), 2.dp.toPx()),
            Type.caption2.copy(color = Brand.textSecondary))
    }
}

@Composable
private fun AxisLegend(names: List<String> = listOf("x · right", "y · top", "z · out of screen")) {
    Row(horizontalArrangement = Arrangement.spacedBy(Space.md)) {
        names.forEachIndexed { i, name ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.size(12.dp, 3.dp).clip(CircleShape).background(axisColors[i]))
                Text(name, style = Type.caption2, color = Brand.textSecondary)
            }
        }
    }
}

// Jolts and crash check

@Composable
private fun JoltsCard(lab: SensorLabModel, frame: Long) {
    val now = remember(frame) { lab.latest?.uptime ?: 0.0 }
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Quick changes", style = Type.headline, color = Brand.textPrimary)
        if (lab.jolts.isEmpty()) {
            Text("Tap the phone, shake it, or drop it on a bed: each jolt over 0.5 g shows up here.", style = Type.footnote, color = Brand.textSecondary)
        }
        lab.jolts.forEach { jolt ->
            Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(sf(joltIcon(jolt.kind)), null, tint = joltTint(jolt.kind), modifier = Modifier.width(24.dp).size(20.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(jolt.kind.title, style = Type.subheadline.semibold(), color = Brand.textPrimary)
                    Text("${g(jolt.peakG)} · ${(jolt.duration * 1000).roundToInt()} ms · ${degreesPerSecond(jolt.peakRotation)}",
                        style = Type.caption, color = Brand.textSecondary)
                }
                Text("${max(0.0, now - jolt.uptime).roundToInt()} s ago", style = Type.caption, color = Brand.textSecondary)
            }
        }
    }
}

private fun joltIcon(kind: Jolt.Kind) = when (kind) {
    Jolt.Kind.crashLevel -> "exclamationmark.triangle.fill"
    Jolt.Kind.drop -> "arrow.down.to.line"
    Jolt.Kind.hard -> "bolt.fill"
    Jolt.Kind.bump -> "waveform.path"
}

private fun joltTint(kind: Jolt.Kind) = when (kind) {
    Jolt.Kind.crashLevel -> Brand.redInk
    Jolt.Kind.drop, Jolt.Kind.hard -> Brand.amberInk
    Jolt.Kind.bump -> Brand.blueInk
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CrashCheckCard(lab: SensorLabModel) {
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Crash check", style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
            Text("${lab.assessmentsSeen} examined", style = Type.caption, color = Brand.textSecondary)
        }
        val a: CrashAssessment? = lab.lastAssessment
        if (a != null) {
            val (label, tint) = when (a.decision) {
                CrashDecision.suspectedCrash -> "Would start a check-in" to Brand.redInk
                CrashDecision.inconclusive -> "Not sure: no check-in" to Brand.amberInk
                CrashDecision.rejected -> "Not a crash" to Brand.greenInk
            }
            StatusChip(label, if (a.decision == CrashDecision.suspectedCrash) "exclamationmark.triangle.fill" else "checkmark.circle", tint)
            MetricRow {
                Metric("Peak", g(a.peakG), Modifier.weight(1f))
                Metric("Speed change", a.impactDeltaVMPS?.let { "${(it * 2.23694).roundToInt()} mph" }, Modifier.weight(1f))
                Metric("Spin", degreesPerSecond(a.peakRotationRadPerSecond), Modifier.weight(1f))
            }
            MetricRow {
                Metric("Hit lasted", "${(a.impactDuration * 1000).roundToInt()} ms", Modifier.weight(1f))
                Metric("GPS speed drop", a.speedDropMPS?.let { "${(it * 2.23694).roundToInt()} mph" } ?: "no GPS", Modifier.weight(1f))
                Metric("After", a.postImpactRMSG?.let { if (it <= 0.15) "still" else "moving" }, Modifier.weight(1f))
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                (a.evidence.map(::evidenceTitle) + a.issues.map(::issueTitle)).forEach { item ->
                    Text(item, style = Type.caption.semibold(), color = Brand.textPrimary,
                        modifier = Modifier.clip(CircleShape).background(Brand.fieldFill).padding(horizontal = 8.dp, vertical = 4.dp))
                }
            }
        } else {
            Text("Anything over ${CrashEvaluationConfiguration().candidateG.toInt()} g is examined here exactly as during a drive, 3.5 s later. This copy never alerts anyone.",
                style = Type.footnote, color = Brand.textSecondary)
        }
    }
}

internal fun evidenceTitle(e: CrashEvidence) = when (e) {
    CrashEvidence.sustainedImpact -> "Hit lasted"
    CrashEvidence.strongImpact -> "Strong hit"
    CrashEvidence.rapidRotation -> "Spun"
    CrashEvidence.speedLoss -> "GPS speed dropped"
    CrashEvidence.settledAfterImpact -> "Still afterward"
    CrashEvidence.possiblePhoneDrop -> "Fell first (drop?)"
    CrashEvidence.continuedTravel -> "Kept driving"
    CrashEvidence.largeImpactDeltaV -> "Crash-sized speed change"
}

internal fun issueTitle(i: CrashDataIssue) = when (i) {
    CrashDataIssue.insufficientBaseline -> "Too little before"
    CrashDataIssue.insufficientPostImpact -> "Too little after"
    CrashDataIssue.motionGap -> "Gap in motion"
    CrashDataIssue.missingReliableGPS -> "No reliable GPS"
}

// Speed

@Composable
private fun SpeedCard(lab: SensorLabModel, frame: Long) {
    val env = LocalEnvironment.current
    val fix = remember(frame) { lab.latestFix }
    val limit = env.driving.speedLimits?.current
    val fixes = remember(frame) { lab.fixes.values }
    val heading = if (fixes.size >= 2) {
        val a = fixes[fixes.size - 2]
        val b = fixes[fixes.size - 1]
        if (TransportFeatures.haversine(a.latitude, a.longitude, b.latitude, b.longitude) >= 3)
            RoadMatcher.bearing(a.latitude, a.longitude, b.latitude, b.longitude) else null
    } else null
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Speed (GPS)", style = Type.headline, color = Brand.textPrimary)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(fix?.let { if (it.speedMPS >= 0) "${(it.speedMPS * 2.23694).roundToInt()}" else "–" } ?: "–",
                style = Type.largeTitle.copy(fontSize = androidx.compose.ui.unit.TextUnit(52f, androidx.compose.ui.unit.TextUnitType.Sp),
                    lineHeight = androidx.compose.ui.unit.TextUnit(56f, androidx.compose.ui.unit.TextUnitType.Sp)), color = Brand.textPrimary)
            Text("mph", style = Type.title3, color = Brand.textSecondary, modifier = Modifier.padding(bottom = 8.dp))
            Box(Modifier.weight(1f))
            if (limit != null) {
                Column(Modifier.clip(RoundedCornerShape(6.dp)).background(Color.White).border(2.dp, Color.Black, RoundedCornerShape(6.dp))
                    .padding(horizontal = 10.dp, vertical = 4.dp)
                    .clearAndSetSemantics { contentDescription = "Speed limit ${limit.mph.toInt()} miles per hour" },
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(if (limit.isPosted) "LIMIT" else "TYPICAL", style = Type.caption2.bold(), color = Color.Black)
                    Text("${limit.mph.toInt()}", style = Type.title2.bold(), color = Color.Black)
                }
            }
        }
        MetricRow {
            Metric("Speed ±", fix?.let { if (it.speedAccuracy >= 0) "${fmt(it.speedAccuracy * 2.23694, 1)} mph" else "unknown" }, Modifier.weight(1f))
            Metric("Position ±", fix?.let { if (it.horizontalAccuracy >= 0) "${it.horizontalAccuracy.roundToInt()} m" else "unknown" }, Modifier.weight(1f))
            Metric("Heading", heading?.let { "${SensorLabMath.compass(it)} ${it.roundToInt()}°" }, Modifier.weight(1f))
        }
        MetricRow {
            Metric("Speeding up", lab.gpsLongitudinalG?.let { g(it, signed = true) }, Modifier.weight(1f))
            Metric("Road", limit?.roadName ?: if (limit == null) null else "unnamed", Modifier.weight(1f))
            Metric("Fix age", fix?.let { "${max(0.0, SystemClock.elapsedRealtimeNanos() / 1e9 - it.uptime).roundToInt()} s" }, Modifier.weight(1f))
        }
        Text("GPS speed comes from the Doppler shift of satellite signals, about once a second. Speeding up/slowing down in g is the change between the last two fixes. Limits come from TomTom or OpenStreetMap.",
            style = Type.caption, color = Brand.textSecondary)
    }
}

// Record

@Composable
private fun RecordCard(lab: SensorLabModel, frame: Long) {
    val context = LocalContext.current
    val latestUptime = remember(frame) { lab.latest?.uptime }
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Record", style = Type.headline, color = Brand.textPrimary)
        when (val recording = lab.recording) {
            is SensorLabModel.Recording.Active -> {
                val left = max(0.0, recording.until - (latestUptime ?: recording.until))
                Text("Recording… ${ceil(left).toInt()} s left", style = Type.subheadline, color = Brand.textPrimary)
                LinearProgressIndicator(progress = { ((SensorLabModel.RECORD_SECONDS - left) / SensorLabModel.RECORD_SECONDS).toFloat() },
                    modifier = Modifier.fillMaxWidth(), color = Brand.red, trackColor = Brand.fieldFill)
                LinkButton("Stop now", { lab.finishRecording() }, color = Brand.redInk)
            }
            is SensorLabModel.Recording.Saved -> {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(sf("checkmark.circle.fill"), null, tint = Brand.greenInk, modifier = Modifier.size(16.dp))
                    Text(recording.file.name, style = Type.footnote, color = Brand.greenInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(Space.sm)) {
                    LinkButton("Share CSV", { Actions.shareFile(context, recording.file, "text/csv") }, icon = "square.and.arrow.up")
                    LinkButton("Replay", { lab.play(SensorLabModel.Source.Recorded(recording.file)) }, icon = "play.fill")
                    LinkButton("Again", { lab.startRecording() }, icon = "record.circle")
                }
            }
            SensorLabModel.Recording.Idle -> {
                LinkButton("Record ${SensorLabModel.RECORD_SECONDS.toInt()} s", { lab.startRecording() }, color = Brand.redInk,
                    icon = "record.circle", enabled = lab.isRunning)
            }
        }
        Text("Saves 100 Hz motion and GPS speed as CSV (no location), to share with your computer or replay here. CSVs pushed into the app's files/Recordings folder (adb push) show up under Replay too.",
            style = Type.caption, color = Brand.textSecondary)
    }
}

// Helpers

@Composable
private fun CardTitle(title: String, detail: String) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(title, style = Type.headline, color = Brand.textPrimary, modifier = Modifier.weight(1f))
        Text(detail, style = Type.caption, color = Brand.textSecondary)
    }
}

@Composable
private fun MetricRow(content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Space.md), content = content)
}

@Composable
private fun Metric(title: String, value: String?, modifier: Modifier = Modifier) {
    Column(modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = Type.caption, color = Brand.textSecondary, maxLines = 1)
        Text(value ?: "–", style = Type.subheadline.semibold(), color = Brand.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun fmt(value: Double, digits: Int) = String.format(Locale.US, "%.${digits}f", value)

private fun g(value: Double, signed: Boolean = false) = (if (signed && value > 0) "+" else "") + fmt(value, 2) + " g"

private fun degreesPerSecond(radians: Double) = "${(radians * 180 / PI).roundToInt()}°/s"
