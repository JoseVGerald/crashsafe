package org.cac.crashsafe.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * CrashSafe "Pulse" brand palette: warm charcoal surfaces, a calm steel-blue accent, amber for caution.
 * The app renders in its dark, night-driving theme everywhere (as on iOS).
 * - Fills (`blue`, `red`, `green`) are dark enough for white text (≥ 4.5:1).
 * - Ink colors (`blueInk`, `redInk`, …) are for text and icons on the charcoal surfaces (≥ 4.5:1).
 */
object Brand {
    // Core
    /** Pulse steel blue — the one accent. Fill for primary actions (white text ≈ 5.4:1). */
    val blue = Color(0xFF4C6C93)
    /** Muted slate-teal secondary accent. */
    val teal = Color(0xFF3F6670)
    /** Deepest canvas, for full-screen alerts and glyphs on light chips. */
    val navy = Color(0xFF12110D)

    // Status fills (white text)
    val red = Color(0xFFC8322B)
    val green = Color(0xFF2E7D4F)
    /** Amber takes black text. */
    val amber = Color(0xFFE9A23B)

    // Ink (text/icon colors on the dark surfaces)
    val blueInk = Color(0xFF9DB8E0)
    val redInk = Color(0xFFFF8F85)
    val greenInk = Color(0xFF4FD68C)
    val amberInk = Color(0xFFF0B04E)
    val tealInk = Color(0xFF8CC3CC)

    // Surfaces
    /** Warm near-black (#1A1812) — every screen background. */
    val background = Color(0xFF1A1812)
    val surface = Color(0xFF25231C)
    val surfaceRaised = Color(0xFF2F2C24)
    val fieldFill = Color(0xFF332F27)
    val stroke = Color.White.copy(alpha = 0.07f)

    // Text
    val textPrimary = Color(0xFFF3F1EC)
    /** ≥ 4.5:1 on `surface`. */
    val textSecondary = Color(0xFFADA89C)

    // Drive mode status colors
    val go = Color(0xFF22C55E)
    val stop = Color(0xFFEF4444)
}

/** Spacing rhythm from the design system (4 / 8 / 16 / 24 / 48). */
object Space {
    val xs = 4.dp
    val sm = 8.dp
    val md = 16.dp
    val lg = 24.dp
    val xl = 48.dp
}

object Radius {
    val card = 20.dp
    val field = 14.dp
    val small = 12.dp
}

/** Minimum height for primary actions (well above the 48 dp touch target). */
val BigTapTarget = 56.dp

/** The iOS text styles the screens were designed with, in sp. */
object Type {
    val largeTitle = TextStyle(fontSize = 32.sp, lineHeight = 39.sp, fontWeight = FontWeight.SemiBold)
    val title = TextStyle(fontSize = 27.sp, lineHeight = 33.sp, fontWeight = FontWeight.Normal)
    val title2 = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Normal)
    val title3 = TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.Normal)
    val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
    val body = TextStyle(fontSize = 17.sp, lineHeight = 22.sp)
    val callout = TextStyle(fontSize = 16.sp, lineHeight = 21.sp)
    val subheadline = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)
    val footnote = TextStyle(fontSize = 13.sp, lineHeight = 18.sp)
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp)
    val caption2 = TextStyle(fontSize = 11.sp, lineHeight = 13.sp)
}

fun TextStyle.semibold() = copy(fontWeight = FontWeight.SemiBold)
fun TextStyle.bold() = copy(fontWeight = FontWeight.Bold)
fun TextStyle.medium() = copy(fontWeight = FontWeight.Medium)

@Composable
fun CrashSafeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Brand.blue,
            onPrimary = Color.White,
            secondary = Brand.teal,
            background = Brand.background,
            surface = Brand.surface,
            surfaceVariant = Brand.fieldFill,
            onBackground = Brand.textPrimary,
            onSurface = Brand.textPrimary,
            onSurfaceVariant = Brand.textSecondary,
            error = Brand.redInk,
            outline = Brand.stroke,
            surfaceContainer = Brand.surface,
            surfaceContainerHigh = Brand.surfaceRaised,
            surfaceContainerHighest = Brand.surfaceRaised,
            surfaceContainerLow = Brand.surface,
        ),
        typography = Typography(bodyLarge = Type.body, bodyMedium = Type.subheadline, labelLarge = Type.headline),
        content = content,
    )
}
