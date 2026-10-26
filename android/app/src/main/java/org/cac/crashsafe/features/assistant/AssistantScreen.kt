package org.cac.crashsafe.features.assistant

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.core.pulse.AssistantScenario
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.ChatMessage
import org.cac.crashsafe.ui.Actions
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.ChoiceMenu
import org.cac.crashsafe.ui.components.ErrorBanner
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.MenuItem
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PulseAvatar
import org.cac.crashsafe.ui.components.PulseOrbMood
import org.cac.crashsafe.ui.components.PulseRings
import org.cac.crashsafe.ui.components.PulseVoiceFace
import org.cac.crashsafe.ui.components.StatusChip
import org.cac.crashsafe.ui.components.pressable
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

private val suggestions = listOf(
    "car.side.fill" to "I need a tow",
    "doc.text.fill" to "What do I tell insurance?",
    "camera.fill" to "What photos should I take?",
    "heart.fill" to "I'm shaking",
)

private val states = listOf("WA" to "Washington", "OR" to "Oregon", "CA" to "California")

@Composable
fun AssistantScreen(user: AuthUser, viewModel: AssistantViewModel) {
    val env = LocalEnvironment.current
    val context = LocalContext.current
    var jurisdiction by remember { mutableStateOf("UNKNOWN") }
    var assistanceStage by remember { mutableStateOf("active") }
    var stateMenu by remember { mutableStateOf(false) }

    fun makeContext() = makeAssistantContext(user, env.store.profile(user.id), env.store.trips(user.id).firstOrNull { it.isActive },
        env.connectivity.isOnline, viewModel.scenario, if (viewModel.isAfterCrash) env.router.assistantIncident else null,
        env.intelligence.assistantActivity).copy(jurisdiction = jurisdiction,
        assistanceStage = if (viewModel.isAfterCrash) assistanceStage else "followup")

    LaunchedEffect(Unit) {
        viewModel.contextProvider = ::makeContext
        viewModel.speaker = env.speaker
        viewModel.begin(AssistantScenario.General)
    }
    LaunchedEffect(env.router.pendingAssistantScenario) {
        val scenario = env.router.pendingAssistantScenario ?: return@LaunchedEffect
        env.router.pendingAssistantScenario = null
        viewModel.contextProvider = ::makeContext
        assistanceStage = "active"
        viewModel.begin(scenario)
    }
    LaunchedEffect(jurisdiction, assistanceStage) { viewModel.contextProvider = ::makeContext }

    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().imePadding()) {
        // Header
        Row(Modifier.padding(horizontal = Space.md, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            PulseAvatar(44.dp, active = viewModel.isThinking || viewModel.isListening, listening = viewModel.isListening)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text("Pulse", style = Type.title3.bold(), color = Brand.textPrimary)
                Text(if (viewModel.isThinking) "Thinking…" else if (env.connectivity.isOnline) "Online assistant" else "Offline · using your trip pack",
                    style = Type.footnote, color = Brand.textSecondary)
            }
            StatusChip(if (env.connectivity.isOnline) "Online" else "Offline", if (env.connectivity.isOnline) "cloud.fill" else "iphone",
                if (env.connectivity.isOnline) Brand.greenInk else Brand.amberInk)
        }
        AnimatedVisibility(viewModel.isAfterCrash) {
            PillButton("Anyone hurt? Call 911", { Actions.call(context, "911") }, kind = PillKind.danger, height = 50.dp, icon = "phone.fill",
                modifier = Modifier.padding(horizontal = Space.md).padding(bottom = 6.dp))
        }
        // Assistance controls
        Row(Modifier.padding(horizontal = Space.md, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                LinkButton("Crash location: " + (states.firstOrNull { it.first == jurisdiction }?.second ?: "Not specified"),
                    { stateMenu = true }, icon = "mappin.circle.fill", style = Type.caption)
                ChoiceMenu(stateMenu, { stateMenu = false },
                    states.map { (code, name) -> MenuItem(name) { jurisdiction = code } } + MenuItem("Other state or not specified") { jurisdiction = "UNKNOWN" })
            }
            Spacer(Modifier.weight(1f))
            if (viewModel.isAfterCrash) {
                LinkButton(if (assistanceStage == "active") "Show follow-up help" else "Back to immediate steps",
                    { assistanceStage = if (assistanceStage == "active") "followup" else "active" }, style = Type.caption)
            }
        }
        MessageList(viewModel, Modifier.weight(1f))
        InputBar(viewModel)
    }
}

@Composable
private fun MessageList(viewModel: AssistantViewModel, modifier: Modifier) {
    val listState = rememberLazyListState()
    val count = viewModel.messages.size + if (viewModel.isThinking) 1 else 0
    LaunchedEffect(count) { if (count > 0) listState.animateScrollToItem(maxOf(0, count - 1 + if (viewModel.messages.size <= 1) 1 else 0)) }
    LazyColumn(modifier.fillMaxWidth(), state = listState, contentPadding = androidx.compose.foundation.layout.PaddingValues(Space.md),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        items(viewModel.messages, key = { it.id }) { message -> MessageBubble(message) }
        if (viewModel.isThinking) item(key = "typing") { TypingIndicator() }
        viewModel.errorMessage?.let { error -> item(key = "error") { ErrorBanner(error) } }
        if (viewModel.messages.size <= 1) {
            item(key = "suggestions") {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 4.dp)) {
                    Text("Try asking", style = Type.footnote.semibold(), color = Brand.textSecondary)
                    suggestions.forEach { (icon, text) ->
                        Row(Modifier.heightIn(min = 44.dp).clip(CircleShape).background(Brand.surface)
                            .border(1.dp, Brand.blueInk.copy(alpha = 0.25f), CircleShape).pressable { viewModel.send(text) }
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(sf(icon), null, tint = Brand.blueInk, modifier = Modifier.size(18.dp))
                            Text(text, style = Type.callout.semibold(), color = Brand.blueInk)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun MessageBubble(message: ChatMessage) {
    val isUser = message.role == ChatMessage.Role.user
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = (if (isUser) "You: " else "Pulse: ") + message.text },
        verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (isUser) Spacer(Modifier.weight(1f)) else PulseAvatar(28.dp, animated = false)
        val shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp, bottomStart = if (isUser) 22.dp else 6.dp, bottomEnd = if (isUser) 6.dp else 22.dp)
        SelectionContainer(Modifier.widthIn(max = 300.dp)) {
            Text(message.text, style = Type.body, color = if (isUser) Color.White else Brand.textPrimary,
                modifier = Modifier.clip(shape).background(if (isUser) Brand.blue else Brand.surface)
                    .then(if (isUser) Modifier else Modifier.border(1.dp, Brand.stroke, shape))
                    .padding(horizontal = 16.dp, vertical = 12.dp))
        }
        if (!isUser) Spacer(Modifier.weight(1f, fill = false).widthIn(min = 32.dp))
    }
}

@Composable
private fun TypingIndicator() {
    val transition = rememberInfiniteTransition(label = "typing")
    Row(Modifier.semantics { contentDescription = "Pulse is typing" }, verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PulseAvatar(28.dp, active = true)
        Row(Modifier.clip(CircleShape).background(Brand.surface).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            repeat(3) { index ->
                val phase by transition.animateFloat(0.3f, 1f, infiniteRepeatable(tween(500, delayMillis = index * 150), RepeatMode.Reverse), label = "dot$index")
                Box(Modifier.size(8.dp).scale(phase).alpha(phase).clip(CircleShape).background(Brand.textSecondary))
            }
        }
    }
}

@Composable
private fun InputBar(viewModel: AssistantViewModel) {
    val focus = LocalFocusManager.current
    Row(Modifier.padding(horizontal = Space.md, vertical = 10.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(52.dp).pressable(enabled = !viewModel.isThinking) { focus.clearFocus(); viewModel.listen() }
            .semantics { contentDescription = if (viewModel.isListening) "Listening" else "Speak to Pulse" }, contentAlignment = Alignment.Center) {
            PulseRings(Brand.blue, count = 2, active = viewModel.isListening, modifier = Modifier.size(52.dp))
            PulseVoiceFace(if (viewModel.isListening) PulseOrbMood.listening else if (viewModel.isThinking) PulseOrbMood.thinking else PulseOrbMood.idle, 52.dp)
        }
        Box(Modifier.weight(1f).heightIn(min = 52.dp).clip(RoundedCornerShape(26.dp)).background(Brand.surface)
            .border(1.dp, Brand.stroke, RoundedCornerShape(26.dp)).padding(horizontal = 16.dp, vertical = 14.dp)) {
            if (viewModel.draft.isEmpty()) {
                Text(if (viewModel.isListening) "Listening…" else "Message Pulse", style = Type.body, color = Brand.textSecondary)
            }
            BasicTextField(viewModel.draft, { viewModel.draft = it }, textStyle = Type.body.copy(color = Brand.textPrimary), maxLines = 4,
                cursorBrush = SolidColor(Brand.blueInk),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { viewModel.send() }),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Message Pulse" })
        }
        AnimatedVisibility(viewModel.canSend, enter = scaleIn() + fadeIn(), exit = scaleOut()) {
            Box(Modifier.size(52.dp).clip(CircleShape).background(Brand.blue).pressable { viewModel.send() }
                .semantics { contentDescription = "Send" }, contentAlignment = Alignment.Center) {
                Icon(sf("arrow.up"), null, tint = Color.White)
            }
        }
    }
}
