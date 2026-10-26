package org.cac.crashsafe.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.cac.crashsafe.R
import org.cac.crashsafe.ui.theme.BigTapTarget
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

// Buttons

/** Pill-shaped button kinds share one shape so screens have one visual language. */
enum class PillKind { primary, danger, safe, dark, secondary, ghost }

@Composable
fun PillButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: PillKind = PillKind.primary,
    height: Dp = BigTapTarget,
    icon: String? = null,
    enabled: Boolean = true,
    textStyle: TextStyle = Type.headline,
    foreground: Color? = null,
    leading: (@Composable () -> Unit)? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, spring(dampingRatio = 0.7f, stiffness = 600f), label = "press")
    val fg = foreground ?: when (kind) {
        PillKind.primary, PillKind.danger, PillKind.safe -> Color.White
        PillKind.dark -> Color.Black
        PillKind.secondary, PillKind.ghost -> Brand.blueInk
    }
    val bg = when (kind) {
        PillKind.primary -> Brand.blue
        PillKind.danger -> Brand.red
        PillKind.safe -> Brand.green
        PillKind.dark -> Color.White
        PillKind.secondary -> Brand.blueInk.copy(alpha = 0.08f)
        PillKind.ghost -> Color.Transparent
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = height)
            .scale(scale)
            .alpha(if (enabled) 1f else 0.45f)
            .clip(CircleShape)
            .background(bg)
            .then(if (kind == PillKind.secondary) Modifier.border(1.5.dp, Brand.blueInk.copy(alpha = 0.35f), CircleShape) else Modifier)
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = Space.lg),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) {
            leading()
            Spacer(Modifier.width(8.dp))
        } else if (icon != null) {
            Icon(sf(icon), contentDescription = null, tint = fg, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = textStyle, color = fg, maxLines = 1)
    }
}

/** Subtle press feedback for custom tappable rows and cards. */
fun Modifier.pressable(enabled: Boolean = true, onClick: () -> Unit): Modifier = composedPressable(enabled, onClick)

@Composable
private fun pressedScale(interaction: MutableInteractionSource): Float {
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.98f else 1f, spring(dampingRatio = 0.75f, stiffness = 600f), label = "pressable")
    return scale
}

private fun Modifier.composedPressable(enabled: Boolean, onClick: () -> Unit): Modifier = composed {
    val interaction = remember { MutableInteractionSource() }
    val scale = pressedScale(interaction)
    this
        .graphicsLayer { scaleX = scale; scaleY = scale; alpha = if (scale < 1f) 0.85f else 1f }
        .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
}

/** A text button in the brand's ink color (toolbar actions, inline links). */
@Composable
fun LinkButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = Brand.blueInk,
               style: TextStyle = Type.subheadline.semibold(), icon: String? = null, enabled: Boolean = true) {
    Row(modifier = modifier
        .defaultMinSize(minHeight = 44.dp)
        .alpha(if (enabled) 1f else 0.45f)
        .clip(RoundedCornerShape(8.dp))
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            Icon(sf(icon), null, tint = color, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(text, style = style, color = color)
    }
}

// Surfaces

fun Modifier.card(padding: Dp = Space.md): Modifier = this
    .fillMaxWidth()
    .clip(RoundedCornerShape(Radius.card))
    .background(Brand.surface)
    .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card))
    .padding(padding)

/** Rounded container used for dashboard cards. */
@Composable
fun Card(modifier: Modifier = Modifier, padding: Dp = Space.md, spacing: Dp = 12.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.card(padding), verticalArrangement = Arrangement.spacedBy(spacing), content = content)
}

/** Colored circle with an icon, used in lists. */
@Composable
fun IconBadge(icon: String, tint: Color = Brand.blue, size: Dp = 40.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(tint), contentAlignment = Alignment.Center) {
        Icon(sf(icon), contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.48f))
    }
}

/** Small capsule label for statuses. */
@Composable
fun StatusChip(text: String, icon: String? = null, tint: Color = Brand.blueInk, modifier: Modifier = Modifier) {
    Row(modifier
        .clip(CircleShape)
        .background(tint.copy(alpha = 0.12f))
        .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        if (icon != null) Icon(sf(icon), null, tint = tint, modifier = Modifier.size(13.dp))
        Text(text, style = Type.caption.semibold(), color = tint, maxLines = 1)
    }
}

@Composable
fun SectionHeader(title: String, actionTitle: String? = null, onAction: (() -> Unit)? = null, actionIcon: String? = null) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Space.xs), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Type.title3.semibold(), color = Brand.textPrimary, modifier = Modifier.weight(1f).semantics { heading() })
        if (actionTitle != null && onAction != null) LinkButton(actionTitle, onAction, icon = actionIcon)
    }
}

/** Label + value status row with a colored icon. */
@Composable
fun StatusRow(icon: String, title: String, value: String, tint: Color = Brand.textSecondary) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.semantics(mergeDescendants = true) {}) {
        Icon(sf(icon), null, tint = tint, modifier = Modifier.width(28.dp).size(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Type.subheadline, color = Brand.textSecondary)
            Text(value, style = Type.body.copy(fontWeight = FontWeight.Medium), color = Brand.textPrimary)
        }
    }
}

/** Inline error message shown under form fields and at the top of forms. */
@Composable
fun ErrorBanner(message: String) {
    Row(Modifier
        .fillMaxWidth()
        .clip(RoundedCornerShape(Radius.small))
        .background(Brand.redInk.copy(alpha = 0.1f))
        .padding(12.dp)
        .semantics { contentDescription = "Error: $message" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(sf("exclamationmark.triangle.fill"), null, tint = Brand.redInk, modifier = Modifier.size(18.dp))
        Text(message, style = Type.callout.copy(fontWeight = FontWeight.Medium), color = Brand.redInk)
    }
}

/** Friendly placeholder for an empty list: tinted icon, title, one line of help. */
@Composable
fun EmptyStateCard(icon: String, title: String, message: String, tint: Color = Brand.blue) {
    Column(Modifier
        .fillMaxWidth()
        .drawBehind {
            drawRoundRect(Brand.textSecondary.copy(alpha = 0.35f), cornerRadius = CornerRadius(Radius.card.toPx()),
                style = Stroke(width = 1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 5.dp.toPx()))))
        }
        .padding(vertical = Space.lg, horizontal = Space.md),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(tint.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
            Icon(sf(icon), null, tint = tint, modifier = Modifier.size(30.dp))
        }
        Text(title, style = Type.headline, color = Brand.textPrimary)
        Text(message, style = Type.subheadline, color = Brand.textSecondary, textAlign = TextAlign.Center)
    }
}

/** Safety disclaimer: CrashSafe helps, but it isn't an emergency service. */
@Composable
fun SafetyNotice(modifier: Modifier = Modifier) {
    Row(modifier.semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(sf("info.circle.fill"), null, tint = Brand.textSecondary, modifier = Modifier.size(18.dp).padding(top = 1.dp))
        Text("CrashSafe isn't an emergency service and doesn't replace 911 or your phone's own crash detection. Crash detection can miss crashes or trigger by mistake. Driving advice is general guidance, not a guarantee of safety.",
            style = Type.footnote, color = Brand.textSecondary)
    }
}

/** Settings-style row label with a fixed-width icon so rows line up. */
@Composable
fun RowScope.RowLabel(title: String, icon: String, tint: Color = Brand.textPrimary) {
    Icon(sf(icon), null, tint = tint, modifier = Modifier.width(28.dp).size(22.dp))
    Spacer(Modifier.width(8.dp))
    Text(title, style = Type.body, color = tint, modifier = Modifier.weight(1f))
}

/** A settings-style row that opens something. */
@Composable
fun NavRow(title: String, icon: String, tint: Color = Brand.textPrimary, enabled: Boolean = true, trailing: String = "chevron.right",
           onClick: () -> Unit) {
    Row(Modifier
        .fillMaxWidth()
        .heightIn(min = 48.dp)
        .alpha(if (enabled) 1f else 0.5f)
        .pressable(enabled, onClick),
        verticalAlignment = Alignment.CenterVertically) {
        RowLabel(title, icon, tint)
        Icon(sf(trailing), null, tint = Brand.textSecondary, modifier = Modifier.size(18.dp))
    }
}

@Composable
fun Hairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().heightIn(min = 1.dp, max = 1.dp).background(Brand.stroke))
}

// Brand

/** "〜 P U L S E" wordmark: heartbeat glyph plus letter-spaced name. */
@Composable
fun PulseWordmark(modifier: Modifier = Modifier) {
    Row(modifier.semantics(mergeDescendants = true) { contentDescription = "Pulse"; heading() },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(sf("waveform.path.ecg"), null, tint = Brand.blueInk, modifier = Modifier.size(22.dp))
        Text("PULSE", style = Type.title3.copy(fontWeight = FontWeight.Medium, letterSpacing = 6.sp), color = Brand.textPrimary)
    }
}

/** Brand photography: a dark SUV on a mountain highway at dusk. */
enum class BrandPhoto(val resource: Int) {
    /** Full scene — Home hero, sign-in, crash check-in. */
    roadHero(R.drawable.road_hero),
    /** Wide strip — Trips banner. */
    roadBanner(R.drawable.road_banner),
    /** The car, tightly framed — vehicle thumbnails. */
    carThumb(R.drawable.car_thumb),
}

/** Fills its frame with a brand photo, cropping (never stretching). */
@Composable
fun BrandPhotoView(photo: BrandPhoto, modifier: Modifier = Modifier, alignment: Alignment = Alignment.Center) {
    Image(painterResource(photo.resource), contentDescription = null, contentScale = ContentScale.Crop, alignment = alignment,
        modifier = modifier.clip(RoundedCornerShape(0.dp)))
}

@Composable
fun VehicleThumbnail(width: Dp = 100.dp, height: Dp = 70.dp) {
    BrandPhotoView(BrandPhoto.carThumb, Modifier.size(width, height).clip(RoundedCornerShape(Radius.small)))
}

// Motion

/** Fade-up entrance (20 dp rise, ease-out curve), staggered by `delay` seconds. */
fun Modifier.fadeUp(delay: Double = 0.0): Modifier = composed {
    val progress = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        progress.animateTo(1f, tween(durationMillis = 550, delayMillis = (delay * 1000).toInt(), easing = CubicBezierEasing(0.25f, 0.1f, 0.25f, 1f)))
    }
    graphicsLayer {
        alpha = progress.value
        translationY = (1 - progress.value) * 20.dp.toPx()
    }
}

/** Expanding rings behind an element (the "pulse" motif). */
@Composable
fun PulseRings(color: Color = Brand.blue, count: Int = 3, active: Boolean = true, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "rings")
    val phase by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(2200, easing = LinearEasing), RepeatMode.Restart), label = "phase")
    Canvas(modifier) {
        if (!active) return@Canvas
        val base = size.minDimension / 2
        for (i in 0 until count) {
            val p = (phase + i * (0.7f / 2.2f)) % 1f
            val eased = 1 - (1 - p) * (1 - p)
            drawCircle(color.copy(alpha = 0.5f * (1 - eased) * 1.6f.coerceAtMost(1f)), radius = base * (1 + 0.9f * eased),
                style = Stroke(width = 2.dp.toPx()))
        }
    }
}

/** Selectable tile with an icon (vehicle types, coaching styles…). */
@Composable
fun ChoiceTile(title: String, icon: String, isSelected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Column(modifier
        .heightIn(min = 68.dp)
        .clip(RoundedCornerShape(Radius.small))
        .background(if (isSelected) Brand.blue else Brand.fieldFill)
        .pressable(onClick = onClick)
        .padding(horizontal = 4.dp, vertical = 10.dp)
        .semantics { contentDescription = title + if (isSelected) ", selected" else "" },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically)) {
        val fg = if (isSelected) Color.White else Brand.textPrimary
        Icon(sf(icon), null, tint = fg, modifier = Modifier.size(22.dp))
        Text(title, style = Type.footnote.semibold(), color = fg, maxLines = 1, textAlign = TextAlign.Center)
    }
}

/** A circular icon button (toolbars, call controls). */
@Composable
fun CircleIconButton(icon: String, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 44.dp,
                     background: Color = Brand.surface, tint: Color = Brand.textPrimary, border: BorderStroke? = BorderStroke(1.dp, Brand.stroke)) {
    Box(modifier
        .size(size)
        .clip(CircleShape)
        .background(background)
        .then(if (border != null) Modifier.border(border, CircleShape) else Modifier)
        .clickable(role = Role.Button, onClick = onClick)
        .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center) {
        Icon(sf(icon), null, tint = tint, modifier = Modifier.size(size * 0.45f))
    }
}
