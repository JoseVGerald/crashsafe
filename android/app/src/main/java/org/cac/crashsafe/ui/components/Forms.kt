package org.cac.crashsafe.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import org.cac.crashsafe.core.util.Validation
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.semibold
import org.cac.crashsafe.ui.theme.sf

/** Labeled text field: soft fill, focus ring, inline error. */
@Composable
fun FormField(
    title: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    error: String? = null,
    placeholder: String? = null,
    isSecure: Boolean = false,
    icon: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    capitalization: KeyboardCapitalization = KeyboardCapitalization.Sentences,
    imeAction: ImeAction = ImeAction.Next,
    onImeAction: () -> Unit = {},
    focusRequester: FocusRequester? = null,
    onFocusLost: () -> Unit = {},
    singleLine: Boolean = true,
    minLines: Int = 1,
) {
    var focused by remember { mutableStateOf(false) }
    var revealed by remember { mutableStateOf(false) }
    var wasFocused by remember { mutableStateOf(false) }
    val border by animateColorAsState(if (error != null) Brand.redInk else if (focused) Brand.blueInk else Color.Transparent, label = "border")
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (title.isNotEmpty()) Text(title, style = Type.subheadline.copy(fontWeight = FontWeight.Medium), color = Brand.textSecondary)
        Row(Modifier
            .fillMaxWidth()
            .heightIn(min = 54.dp)
            .clip(RoundedCornerShape(Radius.field))
            .background(Brand.fieldFill)
            .border(if (focused || error != null) 2.dp else 0.dp, border, RoundedCornerShape(Radius.field))
            .padding(start = 14.dp, end = if (isSecure) 2.dp else 14.dp),
            verticalAlignment = if (singleLine) Alignment.CenterVertically else Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (icon != null) {
                Icon(sf(icon), null, tint = if (focused) Brand.blueInk else Brand.textSecondary,
                    modifier = Modifier.width(20.dp).size(18.dp).then(if (singleLine) Modifier else Modifier.padding(top = 16.dp)))
            }
            Box(Modifier.weight(1f).padding(vertical = if (singleLine) 0.dp else 14.dp)) {
                if (value.isEmpty()) {
                    Text(placeholder ?: title, style = Type.body, color = Brand.textSecondary.copy(alpha = 0.7f))
                }
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    singleLine = singleLine,
                    minLines = minLines,
                    textStyle = Type.body.copy(color = Brand.textPrimary),
                    cursorBrush = SolidColor(Brand.blueInk),
                    visualTransformation = if (isSecure && !revealed) PasswordVisualTransformation() else VisualTransformation.None,
                    keyboardOptions = KeyboardOptions(capitalization = capitalization, keyboardType = if (isSecure) KeyboardType.Password else keyboardType,
                        imeAction = imeAction, autoCorrectEnabled = !isSecure && keyboardType != KeyboardType.Email),
                    keyboardActions = KeyboardActions(onAny = { onImeAction() }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
                        .onFocusChanged {
                            if (wasFocused && !it.isFocused) onFocusLost()
                            wasFocused = it.isFocused
                            focused = it.isFocused
                        }
                        .semantics { contentDescription = title },
                )
            }
            if (isSecure) {
                Box(Modifier.size(44.dp).clip(CircleShape).clickable { revealed = !revealed }
                    .semantics { contentDescription = if (revealed) "Hide password" else "Show password" },
                    contentAlignment = Alignment.Center) {
                    Icon(sf(if (revealed) "eye.slash" else "eye.fill"), null, tint = Brand.textSecondary, modifier = Modifier.size(20.dp))
                }
            }
        }
        AnimatedVisibility(error != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(sf("exclamationmark.circle.fill"), null, tint = Brand.redInk, modifier = Modifier.size(15.dp))
                Text(error ?: "", style = Type.footnote.copy(fontWeight = FontWeight.Medium), color = Brand.redInk)
            }
        }
    }
}

/** Four-segment password strength meter. */
@Composable
fun PasswordStrengthMeter(password: String) {
    val score = Validation.passwordScore(password)
    val (label, color) = when (score) {
        0, 1 -> "Weak" to Brand.redInk
        2 -> "Okay" to Brand.amberInk
        3 -> "Good" to Brand.blueInk
        else -> "Strong" to Brand.greenInk
    }
    Row(Modifier.semantics(mergeDescendants = true) { contentDescription = "Password strength: $label" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        repeat(4) { index ->
            Box(Modifier.weight(1f).height(5.dp).clip(CircleShape).background(if (index < score) color else Brand.fieldFill))
        }
        Text(label, style = Type.caption.semibold(), color = color, modifier = Modifier.width(48.dp))
    }
}

/** iOS's segmented picker: equal segments, the chosen one raised. */
@Composable
fun <T> SegmentedControl(options: List<T>, selected: T, label: (T) -> String, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    Row(modifier
        .fillMaxWidth()
        .heightIn(min = 40.dp)
        .clip(RoundedCornerShape(10.dp))
        .background(Brand.fieldFill)
        .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        options.forEach { option ->
            val isSelected = option == selected
            Box(Modifier
                .weight(1f)
                .heightIn(min = 34.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(if (isSelected) Brand.surfaceRaised else Color.Transparent)
                .clickable(role = androidx.compose.ui.semantics.Role.Tab) { onSelect(option) }
                .semantics { contentDescription = label(option) + if (isSelected) ", selected" else "" },
                contentAlignment = Alignment.Center) {
                Text(label(option), style = Type.footnote.semibold(), color = if (isSelected) Brand.textPrimary else Brand.textSecondary, maxLines = 1)
            }
        }
    }
}

/** A switch in the brand's colors. */
@Composable
fun BrandSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    androidx.compose.material3.Switch(checked, onCheckedChange, modifier,
        colors = androidx.compose.material3.SwitchDefaults.colors(
            checkedTrackColor = Brand.blue, checkedThumbColor = Color.White, checkedBorderColor = Brand.blue,
            uncheckedTrackColor = Brand.fieldFill, uncheckedThumbColor = Brand.textSecondary, uncheckedBorderColor = Brand.stroke))
}
