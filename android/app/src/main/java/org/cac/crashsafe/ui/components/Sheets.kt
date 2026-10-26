package org.cac.crashsafe.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

/** A toolbar action: "Cancel", "Save", "Done"… */
data class BarAction(val title: String, val bold: Boolean = false, val enabled: Boolean = true, val icon: String? = null, val run: () -> Unit)

/** Title in the middle, actions either side (iOS's inline navigation bar). */
@Composable
fun TopBar(title: String, leading: BarAction? = null, trailing: BarAction? = null, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 8.dp)) {
        Text(title, style = Type.headline, color = Brand.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center, modifier = Modifier.align(Alignment.Center).padding(horizontal = 96.dp))
        leading?.let { BarButton(it, Modifier.align(Alignment.CenterStart)) }
        trailing?.let { BarButton(it, Modifier.align(Alignment.CenterEnd)) }
    }
}

@Composable
private fun BarButton(action: BarAction, modifier: Modifier) {
    if (action.icon != null && action.title.isEmpty()) {
        CircleIconButton(action.icon, action.title.ifEmpty { "Close" }, action.run, modifier, size = 40.dp)
    } else {
        LinkButton(action.title, action.run, modifier, enabled = action.enabled, icon = action.icon,
            style = if (action.bold) Type.body.semibold() else Type.body)
    }
}

/**
 * A full-screen sheet (iOS's `.sheet` / `.fullScreenCover`): its own back handling, an inline top bar, and
 * content that scrolls by default.
 */
@Composable
fun FullScreenSheet(
    onDismiss: () -> Unit,
    title: String = "",
    leading: BarAction? = null,
    trailing: BarAction? = null,
    scrolls: Boolean = true,
    showsBar: Boolean = true,
    bottomBar: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false, dismissOnClickOutside = false)) {
        BackHandler(onBack = onDismiss)
        Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().imePadding()) {
            if (showsBar) TopBar(title, leading, trailing)
            Column(Modifier
                .weight(1f)
                .fillMaxWidth()
                .then(if (scrolls) Modifier.verticalScroll(rememberScrollState()) else Modifier),
                content = content)
            bottomBar?.let { Box(Modifier.fillMaxWidth().background(Brand.background).navigationBarsPadding()) { it() } }
            if (bottomBar == null) Spacer(Modifier.navigationBarsPadding())
        }
    }
}

/** A pushed screen with a back button (iOS's navigation push). */
@Composable
fun PushedScreen(title: String, onBack: () -> Unit, trailing: BarAction? = null, scrolls: Boolean = true,
                 content: @Composable ColumnScope.() -> Unit) {
    BackHandler(onBack = onBack)
    Column(Modifier.fillMaxSize().background(Brand.background)) {
        TopBar(title, BarAction("", icon = "chevron.left", run = onBack), trailing)
        Column(Modifier.weight(1f).fillMaxWidth().then(if (scrolls) Modifier.verticalScroll(rememberScrollState()) else Modifier), content = content)
    }
}

/** Centers content to a readable width on tablets, with the standard side padding. */
@Composable
fun ReadableColumn(modifier: Modifier = Modifier, maxWidth: Dp = 680.dp, spacing: Dp = Space.md + 4.dp, horizontalPadding: Dp = Space.md,
                   content: @Composable ColumnScope.() -> Unit) {
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.widthIn(max = maxWidth).fillMaxWidth().padding(horizontal = horizontalPadding),
            verticalArrangement = Arrangement.spacedBy(spacing), content = content)
    }
}

/** iOS's confirmation dialog: a title, a message and one destructive choice. */
@Composable
fun ConfirmDialog(title: String, message: String, confirm: String, onConfirm: () -> Unit, onDismiss: () -> Unit, destructive: Boolean = true) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Brand.surfaceRaised,
        title = { Text(title, style = Type.headline, color = Brand.textPrimary) },
        text = { Text(message, style = Type.subheadline, color = Brand.textSecondary) },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirm, color = if (destructive) Brand.redInk else Brand.blueInk, style = Type.body.semibold())
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = Brand.blueInk, style = Type.body) } },
    )
}

/** A choice of actions (iOS's confirmationDialog with several buttons). */
@Composable
fun ActionDialog(title: String, actions: List<Pair<String, () -> Unit>>, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Brand.surfaceRaised,
        title = { Text(title, style = Type.headline, color = Brand.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                actions.forEach { (label, run) ->
                    TextButton(onClick = { onDismiss(); run() }, modifier = Modifier.fillMaxWidth()) {
                        Text(label, color = Brand.blueInk, style = Type.body)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = Brand.textSecondary) } },
    )
}

/** An item in a dropdown menu (iOS's Menu). */
data class MenuItem(val title: String, val icon: String? = null, val section: String? = null, val run: () -> Unit)

@Composable
fun ChoiceMenu(expanded: Boolean, onDismiss: () -> Unit, items: List<MenuItem>) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss, containerColor = Brand.surfaceRaised) {
        var lastSection: String? = null
        items.forEach { item ->
            if (item.section != null && item.section != lastSection) {
                lastSection = item.section
                Text(item.section, style = Type.caption.semibold(), color = Brand.textSecondary,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            }
            DropdownMenuItem(
                text = { Text(item.title, style = Type.subheadline, color = Brand.textPrimary) },
                leadingIcon = item.icon?.let { { Icon(sf(it), null, tint = Brand.blueInk) } },
                onClick = { onDismiss(); item.run() })
        }
    }
}

@Composable
fun Gap(height: Dp) = Spacer(Modifier.height(height))

/** Insets for content that should clear the status bar on screens without a top bar. */
fun Modifier.safeTop(): Modifier = statusBarsPadding()
