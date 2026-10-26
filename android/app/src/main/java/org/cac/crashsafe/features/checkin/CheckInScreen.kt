package org.cac.crashsafe.features.checkin

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.crash.ImpactReport
import org.cac.crashsafe.core.util.roundToIntHalfAway
import org.cac.crashsafe.features.recovery.RecoveryBanner
import org.cac.crashsafe.features.recovery.RecoveryScreen
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.services.alerts.AlertDelivery
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BrandPhoto
import org.cac.crashsafe.ui.components.BrandPhotoView
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PulseWordmark
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf
import java.util.Locale

/**
 * Shows the check-in that `CrashResponseCenter` started the moment the crash was detected
 * (the countdown is already running, even if the phone was locked until now).
 */
@Composable
fun CheckInContainer(event: CrashEvent, user: AuthUser) {
    val env = LocalEnvironment.current
    val viewModel = env.crashCenter.current
    if (viewModel != null && viewModel.event.id == event.id) {
        CheckInScreen(user, viewModel)
    } else {
        // Opened without a running check-in (shouldn't happen): go straight to the help hub.
        RecoveryScreen(user, outcome = null, onClose = { env.router.closeCrash() })
    }
}

/**
 * Full-screen "Are you OK?" check-in. Built for one-handed use: every action sits in the bottom half of the
 * screen, and the safest answer is the biggest button. Once answered (or timed out), it becomes the help hub.
 */
@Composable
fun CheckInScreen(user: AuthUser, viewModel: CheckInViewModel) {
    val env = LocalEnvironment.current
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(Unit) { viewModel.start() } // Already running; start() is a no-op then.
    LaunchedEffect(viewModel.secondsRemaining) {
        if (viewModel.secondsRemaining in 1..10) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
    }
    BackHandler(enabled = viewModel.phase == CheckInViewModel.Phase.Counting) {}
    AnimatedContent(viewModel.phase, transitionSpec = {
        (slideInVertically { it } + fadeIn()) togetherWith fadeOut()
    }, contentKey = { it is CheckInViewModel.Phase.Counting }, label = "checkIn") { phase ->
        when (phase) {
            CheckInViewModel.Phase.Counting -> Countdown(viewModel)
            is CheckInViewModel.Phase.Resolved -> RecoveryScreen(user, phase.outcome, banner(phase.outcome, viewModel),
                onClose = { env.router.closeCrash() })
        }
    }
}

@Composable
private fun Countdown(viewModel: CheckInViewModel) {
    val env = LocalEnvironment.current
    val bump = remember { Animatable(1f) }
    LaunchedEffect(env.crashCenter.promptsSpoken) {
        bump.animateTo(1.06f, spring(dampingRatio = 0.5f, stiffness = 900f))
        bump.animateTo(1f, spring(dampingRatio = 0.5f, stiffness = 600f))
    }
    val progress by animateFloatAsState(viewModel.progress.toFloat(), tween(1000), label = "countdown")
    Column(Modifier.fillMaxSize().background(Brand.background)) {
        // Photo header: "Are you okay?" over the road at dusk.
        Box(Modifier.fillMaxWidth().height(380.dp)) {
            BrandPhotoView(BrandPhoto.roadHero, Modifier.fillMaxSize())
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)))
            Column(Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = Space.lg).padding(top = Space.sm, bottom = Space.lg),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PulseWordmark()
                    if (viewModel.event.isSimulated) {
                        Text("SIMULATED", style = Type.caption.copy(fontWeight = FontWeight.Black, letterSpacing = 1.sp), color = Color.White,
                            modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.16f)).padding(horizontal = 10.dp, vertical = 4.dp))
                    }
                }
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(84.dp).clip(CircleShape).background(Brand.navy.copy(alpha = 0.75f)).border(2.dp, Brand.amber.copy(alpha = 0.7f), CircleShape),
                    contentAlignment = Alignment.Center) {
                    Icon(sf("exclamationmark.triangle.fill"), null, tint = Brand.amber, modifier = Modifier.size(36.dp))
                }
                Text("Are you okay?", style = Type.largeTitle.copy(fontSize = 44.sp, lineHeight = 50.sp, fontWeight = FontWeight.Bold), color = Color.White,
                    modifier = Modifier.graphicsLayer { scaleX = bump.value; scaleY = bump.value })
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(sf("speaker.wave.2.fill"), null, tint = Color.White.copy(alpha = 0.75f), modifier = Modifier.size(14.dp))
                    Text("Asking out loud every 5 seconds", style = Type.footnote.semibold(), color = Color.White.copy(alpha = 0.75f))
                }
                Text("A sudden impact was detected.", style = Type.title3, color = Color.White.copy(alpha = 0.85f))
            }
        }

        Row(Modifier.padding(horizontal = 20.dp).padding(top = Space.md).card(Space.md), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.md)) {
            Box(Modifier.size(72.dp).semantics { contentDescription = "${viewModel.secondsRemaining} seconds to respond" }, contentAlignment = Alignment.Center) {
                Canvas(Modifier.fillMaxSize()) {
                    val stroke = 8.dp.toPx()
                    drawCircle(Color.White.copy(alpha = 0.1f), radius = size.minDimension / 2 - stroke / 2, style = Stroke(stroke))
                    drawArc(Brand.amber, startAngle = -90f, sweepAngle = 360f * progress, useCenter = false,
                        topLeft = Offset(stroke / 2, stroke / 2), size = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke),
                        style = Stroke(stroke, cap = StrokeCap.Round))
                }
                Text("${viewModel.secondsRemaining}", style = Type.title.copy(fontWeight = FontWeight.Bold), color = Brand.textPrimary)
            }
            Text(if (viewModel.recipients.isEmpty()) "If you don't answer, we'll treat it as an emergency."
            else "If you don't answer, we'll alert ${contactSummary(viewModel)}.", style = Type.body, color = Brand.textSecondary, modifier = Modifier.weight(1f))
        }
        viewModel.event.impact?.let { ImpactSummary(it, Modifier.padding(horizontal = 20.dp).padding(top = 10.dp)) }
        Spacer(Modifier.weight(1f))
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 12.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            PillButton("I'm okay", { viewModel.respond(CheckInOutcome.ok) }, height = 84.dp, icon = "checkmark", textStyle = Type.title2.semibold())
            Row(Modifier.fillMaxWidth().heightIn(min = 68.dp).clip(CircleShape).background(Brand.surface).border(1.dp, Brand.stroke, CircleShape)
                .pressable { viewModel.respond(CheckInOutcome.needsHelp) }, verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                Icon(sf("exclamationmark.triangle.fill"), null, tint = Brand.amberInk, modifier = Modifier.size(22.dp))
                Text("I need help", style = Type.title3.semibold(), color = Brand.amberInk)
            }
        }
    }
}

private fun contactSummary(viewModel: CheckInViewModel): String {
    val names = viewModel.recipients.map { it.name }
    return when (names.size) {
        1 -> names[0]
        2 -> "${names[0]} and ${names[1]}"
        else -> "your ${names.size} family contacts"
    }
}

private fun banner(outcome: CheckInOutcome, viewModel: CheckInViewModel): RecoveryBanner {
    if (outcome == CheckInOutcome.ok) {
        return RecoveryBanner("Glad you're OK. Take a slow breath — help is here if you need it.", "checkmark.circle.fill", Brand.greenInk)
    }
    if (viewModel.recipients.isEmpty()) {
        return RecoveryBanner("No family contacts saved. Call 911 if anyone is hurt.", "exclamationmark.triangle.fill", Brand.amberInk)
    }
    val who = contactSummary(viewModel)
    if (viewModel.isAlerting) return RecoveryBanner("Alerting $who…", "bell.badge.fill", Brand.amberInk)
    return when (viewModel.alertDelivery) {
        AlertDelivery.sent -> RecoveryBanner("We texted and called $who with your location.", "checkmark.message.fill", Brand.greenInk)
        AlertDelivery.dryRun -> RecoveryBanner(if (viewModel.event.isSimulated)
            "Test crash: $who would get a text and a call with your location. Nothing was sent."
        else "Texting and calling aren't set up on the CrashSafe server yet, so nothing was sent. Call $who yourself.",
            "exclamationmark.bubble.fill", Brand.amberInk)
        AlertDelivery.queued -> RecoveryBanner("Couldn't reach the CrashSafe server — call or text $who yourself if you can.",
            "clock.badge.exclamationmark", Brand.amberInk)
        null -> RecoveryBanner("Alerting $who…", "bell.badge.fill", Brand.amberInk)
    }
}

/** "How hard was the hit?" — measured from the rolling sensor history. */
@Composable
fun ImpactSummary(impact: ImpactReport, modifier: Modifier = Modifier) {
    val tint = when (impact.severity) {
        ImpactReport.Severity.minor -> Brand.greenInk
        ImpactReport.Severity.moderate -> Brand.amberInk
        ImpactReport.Severity.severe -> Brand.redInk
    }
    Row(modifier
        .fillMaxWidth()
        .clip(RoundedCornerShape(Radius.card))
        .background(Brand.surface)
        .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))
        .padding(Space.md)
        .semantics(mergeDescendants = true) {
            contentDescription = "${impact.severity.label} impact: ${impact.peakG.roundToIntHalfAway()} g peak, about " +
                "${impact.deltaVMPH.roundToIntHalfAway()} miles per hour speed change" + if (impact.isSimulated) ", simulated" else ""
        },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.md)) {
        Metric("${impact.peakG.roundToIntHalfAway()} g", "peak")
        Metric("${impact.deltaVMPH.roundToIntHalfAway()} mph", "speed change")
        Metric(impact.timeToStop?.let { String.format(Locale.US, "%.1f s", it) } ?: "—", "to stop")
        Spacer(Modifier.weight(1f))
        Text(impact.severity.label, style = Type.caption.copy(fontWeight = FontWeight.Bold), color = tint,
            modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).padding(horizontal = 10.dp, vertical = 5.dp))
    }
}

@Composable
private fun Metric(value: String, label: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(value, style = Type.headline, color = Brand.textPrimary)
        Text(label, style = Type.caption, color = Brand.textSecondary)
    }
}
