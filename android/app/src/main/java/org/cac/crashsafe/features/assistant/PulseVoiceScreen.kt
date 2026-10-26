package org.cac.crashsafe.features.assistant

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.cac.crashsafe.app.AppRouter
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.Hairline
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PulseOrbMood
import org.cac.crashsafe.ui.components.PulseRings
import org.cac.crashsafe.ui.components.PulseVoiceFace
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.TopBar
import org.cac.crashsafe.ui.components.card
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.medium
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

private data class Topic(val icon: String, val title: String, val prompt: String, val tint: Color)

private val topics = listOf(
    Topic("car.side.fill", "Crash Checklist", "What should I do right after an accident?", Brand.redInk),
    Topic("truck.box.fill", "Towing & Roadside", "Help me find a nearby tow truck and check rates.", Brand.blueInk),
    Topic("doc.text.fill", "Insurance & Evidence", "What photos and driver details do I need?", Brand.greenInk),
    Topic("steeringwheel", "Driving Coaching", "Review my recent driving habits and weather conditions.", Brand.amberInk),
)

/** The Pulse Voice tab: a hands-free conversational assistant for crash response, roadside help and coaching. */
@Composable
fun PulseVoiceScreen(user: AuthUser, viewModel: PulseCallViewModel) {
    val env = LocalEnvironment.current
    LaunchedEffect(Unit) {
        viewModel.contextProvider = {
            makeAssistantContext(user, env.store.profile(user.id), env.store.trips(user.id).firstOrNull { it.isActive },
                env.connectivity.isOnline, activity = env.intelligence.assistantActivity)
        }
        viewModel.prepare()
    }
    AnimatedContent(viewModel.inCall, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "pulseVoice") { inCall ->
        if (inCall) PulseCallScreen(viewModel) else IdleHub(viewModel)
    }
}

@Composable
private fun IdleHub(viewModel: PulseCallViewModel) {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val micGranted = env.permissions.microphoneGranted.also { env.permissions.version }
    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding()) {
        TopBar("Pulse Voice", trailing = BarAction("Chat", icon = "bubble.left.and.text.bubble.right") { env.router.selectedTab = AppRouter.Tab.assistant })
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            ReadableColumn(maxWidth = 640.dp, spacing = Space.lg, modifier = Modifier.padding(bottom = Space.xl)) {
                // Status
                Row(Modifier.padding(top = Space.xs), horizontalArrangement = Arrangement.spacedBy(Space.sm), verticalAlignment = Alignment.CenterVertically) {
                    Pill(if (env.connectivity.isOnline) "Online" else "Offline Mode", if (env.connectivity.isOnline) "wifi" else "wifi.slash",
                        if (env.connectivity.isOnline) Brand.greenInk else Brand.amberInk)
                    Pill(if (env.speaker.hasCorey) "Corey Voice" else "Phone Speech", "waveform", Brand.blueInk)
                    Spacer(Modifier.weight(1f))
                    (viewModel.phase as? PulseCallViewModel.Phase.Failed)?.let { Text(it.message, style = Type.caption2, color = Brand.redInk, maxLines = 1) }
                }
                // Hero orb
                Column(Modifier.fillMaxWidth().padding(vertical = Space.md), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Space.md)) {
                    Box(Modifier.size(160.dp).shadow(18.dp, CircleShape, ambientColor = Brand.blue, spotColor = Brand.blue).clip(CircleShape)
                        .background(Brand.surface).border(1.5.dp, Brand.stroke, CircleShape).pressable { viewModel.startCall() }
                        .semantics { contentDescription = "Start Pulse Voice Call" }, contentAlignment = Alignment.Center) {
                        PulseVoiceFace(PulseOrbMood.idle, 124.dp, badge = "waveform")
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("Pulse Voice Assistant", style = Type.title2.bold(), color = Brand.textPrimary)
                        Text("Tap the orb or the button below to start a hands-free voice call. Pulse listens when you speak and answers out loud.",
                            style = Type.subheadline, color = Brand.textSecondary, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = Space.sm))
                    }
                    PillButton("Start Voice Call", { viewModel.startCall() }, icon = "phone.fill", modifier = Modifier.padding(top = Space.xs))
                }
                if (!micGranted) {
                    Row(Modifier.card(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(sf("mic.slash.fill"), null, tint = Brand.amberInk, modifier = Modifier.size(24.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("Microphone Access", style = Type.subheadline.semibold(), color = Brand.textPrimary)
                            Text(if (env.permissions.microphoneDenied) "Enable microphone in Settings to speak with Pulse."
                            else "Pulse needs microphone access to hear your voice.", style = Type.caption, color = Brand.textSecondary)
                        }
                        Text(if (env.permissions.microphoneDenied) "Settings" else "Allow", style = Type.caption.semibold(), color = Color.White,
                            modifier = Modifier.clip(CircleShape).background(Brand.blue).pressable {
                                if (env.permissions.microphoneDenied) env.permissions.openSettings() else scope.launch { env.permissions.requestMicrophone() }
                            }.padding(horizontal = 14.dp, vertical = 8.dp))
                    }
                }
                // Suggested topics
                Column(verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                    Text("SUGGESTED TOPICS", style = Type.footnote.semibold(), color = Brand.textSecondary, modifier = Modifier.padding(horizontal = 4.dp))
                    topics.forEach { topic ->
                        Row(Modifier.card().pressable { viewModel.startCall(topic.title) }, verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            Box(Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(topic.tint.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                                Icon(sf(topic.icon), null, tint = topic.tint, modifier = Modifier.size(20.dp))
                            }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(topic.title, style = Type.subheadline.semibold(), color = Brand.textPrimary)
                                Text(topic.prompt, style = Type.caption, color = Brand.textSecondary, maxLines = 2)
                            }
                            Icon(sf("chevron.right"), null, tint = Brand.textSecondary, modifier = Modifier.size(14.dp))
                        }
                    }
                }
                // How it works
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(Modifier.padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(sf("sparkles"), null, tint = Brand.blueInk, modifier = Modifier.size(14.dp))
                        Text("HOW PULSE VOICE WORKS", style = Type.footnote.semibold(), color = Brand.textSecondary)
                    }
                    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        InfoRow("waveform.badge.mic", "Natural Conversational Turns", "Speak freely. Pulse pauses when you finish, thinks, and replies aloud in real-time.")
                        Hairline()
                        InfoRow("shield.lefthalf.filled", "Safety & Privacy Guardrails", "Deterministic sentence verification ensures safety compliance. Telemetry stays on your device.")
                        Hairline()
                        InfoRow("hand.tap.fill", "Interrupt Anytime", "Tap the animated orb at any point while Pulse is speaking to immediately cut in.")
                    }
                }
                // Alternate actions
                Row(horizontalArrangement = Arrangement.spacedBy(Space.md)) {
                    PillButton("Open Text Chat", { env.router.selectedTab = AppRouter.Tab.assistant }, Modifier.weight(1f), kind = PillKind.secondary,
                        height = 46.dp, icon = "bubble.left.and.text.bubble.right", textStyle = Type.subheadline.medium())
                    PillButton("Call 911", { Actions.call(context, "911") }, Modifier.weight(1f), kind = PillKind.danger, height = 46.dp,
                        icon = "phone.badge.plus", textStyle = Type.subheadline.medium())
                }
            }
        }
    }
}

@Composable
private fun Pill(text: String, icon: String, tint: Color) {
    Row(Modifier.clip(CircleShape).background(tint.copy(alpha = 0.12f)).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(sf(icon), null, tint = tint, modifier = Modifier.size(12.dp))
        Text(text, style = Type.caption2.medium(), color = tint)
    }
}

@Composable
private fun InfoRow(icon: String, title: String, description: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(sf(icon), null, tint = Brand.blueInk, modifier = Modifier.size(22.dp).padding(top = 2.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.subheadline.medium(), color = Brand.textPrimary)
            Text(description, style = Type.caption, color = Brand.textSecondary)
        }
    }
}

/**
 * The call, laid out like a phone's own call screen: who you're talking to and the call time at the top,
 * Pulse in the middle with live captions, and round Mute and End buttons at the bottom.
 */
@Composable
fun PulseCallScreen(viewModel: PulseCallViewModel) {
    val context = LocalContext.current
    BackHandler { viewModel.endCall() }
    val mood = when (val phase = viewModel.phase) {
        PulseCallViewModel.Phase.Idle, is PulseCallViewModel.Phase.Failed -> PulseOrbMood.idle
        PulseCallViewModel.Phase.Listening -> if (viewModel.isMuted) PulseOrbMood.idle else PulseOrbMood.listening
        PulseCallViewModel.Phase.Connecting, is PulseCallViewModel.Phase.Thinking -> PulseOrbMood.thinking
        is PulseCallViewModel.Phase.Speaking -> PulseOrbMood.speaking.also { phase.reply }
    }
    Column(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF292929), Color(0xFF0A0A0A)))).statusBarsPadding().navigationBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.padding(top = 56.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Pulse", style = Type.largeTitle.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.Normal), color = Color.White)
            CallStatus(viewModel)
        }
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(150.dp).pressable(onClick = viewModel::interrupt)
            .semantics { contentDescription = if (mood == PulseOrbMood.speaking) "Interrupt Pulse" else "Pulse" }, contentAlignment = Alignment.Center) {
            PulseRings(mood.ringTint, 3, mood == PulseOrbMood.listening || mood == PulseOrbMood.speaking, Modifier.size(150.dp))
            PulseVoiceFace(mood, 150.dp, showsMicBadge = false)
        }
        // The rings spread past the orb, so the captions start below them.
        Column(Modifier.padding(horizontal = 28.dp).padding(top = 56.dp).heightIn(max = 220.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(stateLine(viewModel).uppercase(), style = Type.subheadline.semibold(), color = if (viewModel.isMuted) Color(0xFFFF9500) else Color.White.copy(alpha = 0.6f))
            captionText(viewModel)?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = Type.title3, color = Color.White, textAlign = TextAlign.Center)
            }
        }
        Spacer(Modifier.weight(1f))
        // What Pulse asked the app to offer (the agent's tools): shown, never done for the person.
        Column(Modifier.padding(horizontal = 28.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            AnimatedVisibility(viewModel.offersEmergencyCall) {
                PillButton("Call 911", { Actions.call(context, "911") }, kind = PillKind.danger, height = 50.dp, icon = "phone.fill")
            }
            AnimatedVisibility(viewModel.offersTowSearch) {
                PillButton("Find a tow nearby", { Actions.mapSearch(context, "tow truck") }, kind = PillKind.secondary, height = 44.dp,
                    icon = "truck.box.fill", foreground = Color.White)
            }
        }
        Row(Modifier.padding(bottom = 48.dp), horizontalArrangement = Arrangement.spacedBy(72.dp)) {
            CallButton(if (viewModel.isMuted) "unmute" else "mute", "mic.slash.fill", viewModel.isMuted, null, viewModel::toggleMute)
            CallButton("end", "phone.down.fill", false, Color(0xFFFF3B30), viewModel::endCall)
        }
    }
}

@Composable
private fun CallStatus(viewModel: PulseCallViewModel) {
    val startedAt = viewModel.startedAt
    if (startedAt != null && viewModel.phase != PulseCallViewModel.Phase.Connecting) {
        var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
        LaunchedEffect(startedAt) {
            while (true) {
                now = System.currentTimeMillis()
                delay(1000)
            }
        }
        val seconds = ((now / 1000.0) - startedAt).toLong().coerceAtLeast(0)
        Text(String.format(java.util.Locale.US, "%d:%02d", seconds / 60, seconds % 60), style = Type.title3, color = Color.White.copy(alpha = 0.7f),
            modifier = Modifier.semantics { contentDescription = "Call time" })
    } else {
        Text("calling…", style = Type.title3, color = Color.White.copy(alpha = 0.7f))
    }
}

private fun stateLine(viewModel: PulseCallViewModel): String {
    if (viewModel.isMuted) return "Muted"
    return when (viewModel.phase) {
        PulseCallViewModel.Phase.Connecting -> "Connecting"
        PulseCallViewModel.Phase.Listening -> "Listening"
        is PulseCallViewModel.Phase.Thinking -> "Thinking"
        is PulseCallViewModel.Phase.Speaking -> "Pulse · tap to interrupt"
        PulseCallViewModel.Phase.Idle, is PulseCallViewModel.Phase.Failed -> ""
    }
}

private fun captionText(viewModel: PulseCallViewModel): String? = when (val phase = viewModel.phase) {
    PulseCallViewModel.Phase.Listening -> {
        val partial = viewModel.voice.partial
        if (viewModel.isMuted || partial.isEmpty()) viewModel.lastReply else "“$partial”"
    }
    is PulseCallViewModel.Phase.Thinking -> "“${phase.heard}”"
    is PulseCallViewModel.Phase.Speaking -> phase.reply
    else -> null
}

/** A round button like a phone call screen's: icon in a circle, label underneath. */
@Composable
private fun CallButton(title: String, icon: String, isOn: Boolean, tint: Color?, onClick: () -> Unit) {
    Column(Modifier.pressable(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = title.replaceFirstChar { it.uppercase() } },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(76.dp).clip(CircleShape).background(tint ?: if (isOn) Color.White else Color.White.copy(alpha = 0.18f)),
            contentAlignment = Alignment.Center) {
            Icon(sf(icon), null, tint = if (isOn) Color.Black else Color.White, modifier = Modifier.size(30.dp))
        }
        Text(title, style = Type.footnote, color = Color.White)
    }
}
