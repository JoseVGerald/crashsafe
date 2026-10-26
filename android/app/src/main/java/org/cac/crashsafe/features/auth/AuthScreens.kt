package org.cac.crashsafe.features.auth

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.cac.crashsafe.ui.LocalEnvironment
import org.cac.crashsafe.ui.components.BarAction
import org.cac.crashsafe.ui.components.BrandPhoto
import org.cac.crashsafe.ui.components.BrandPhotoView
import org.cac.crashsafe.ui.components.ErrorBanner
import org.cac.crashsafe.ui.components.FormField
import org.cac.crashsafe.ui.components.FullScreenSheet
import org.cac.crashsafe.ui.components.IconBadge
import org.cac.crashsafe.ui.components.LinkButton
import org.cac.crashsafe.ui.components.PasswordStrengthMeter
import org.cac.crashsafe.ui.components.PillButton
import org.cac.crashsafe.ui.components.PillKind
import org.cac.crashsafe.ui.components.PulseWordmark
import org.cac.crashsafe.ui.components.ReadableColumn
import org.cac.crashsafe.ui.components.TopBar
import org.cac.crashsafe.ui.components.fadeUp
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.Radius
import org.cac.crashsafe.ui.theme.Space
import org.cac.crashsafe.ui.theme.Type
import org.cac.crashsafe.ui.theme.bold
import org.cac.crashsafe.ui.theme.sf

private enum class AuthRoute { landing, signUp, signIn }

/** Root of the signed-out flow: brand moment + one clear primary action. */
@Composable
fun AuthFlow() {
    var route by remember { mutableStateOf(AuthRoute.landing) }
    BackHandler(enabled = route != AuthRoute.landing) { route = AuthRoute.landing }
    AnimatedContent(route, transitionSpec = {
        val forward = targetState != AuthRoute.landing
        (slideInHorizontally { if (forward) it else -it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { if (forward) -it / 3 else it } + fadeOut())
    }, label = "auth") { current ->
        when (current) {
            AuthRoute.landing -> AuthLanding(onSignUp = { route = AuthRoute.signUp }, onSignIn = { route = AuthRoute.signIn })
            AuthRoute.signUp -> SignUpScreen(onBack = { route = AuthRoute.landing })
            AuthRoute.signIn -> SignInScreen(onBack = { route = AuthRoute.landing })
        }
    }
}

@Composable
private fun AuthLanding(onSignUp: () -> Unit, onSignIn: () -> Unit) {
    val env = LocalEnvironment.current
    val scope = rememberCoroutineScope()
    val google = remember { SignInViewModel(env.session) }
    val features = listOf(
        Triple("waveform.path.ecg", "Checks on you after a crash", "If you don't answer, your family is alerted."),
        Triple("mic.fill", "Pulse talks you through it", "Calm, step-by-step help — by voice."),
        Triple("antenna.radiowaves.left.and.right.slash", "Works with no signal", "Tow, hospitals and guides saved for your route."),
    )
    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState())) {
        ReadableColumn(horizontalPadding = Space.lg) {
            PulseWordmark(Modifier.padding(top = Space.sm).fadeUp())
            BrandPhotoView(BrandPhoto.roadHero, Modifier.fillMaxWidth().height(176.dp).clip(RoundedCornerShape(Radius.card))
                .border(1.dp, Brand.stroke, RoundedCornerShape(Radius.card)).fadeUp(0.04))
            Column(Modifier.fadeUp(0.08), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Stay safe on every drive.", style = Type.largeTitle, color = Brand.textPrimary)
                Text("CrashSafe watches for crashes, checks on you, and gets help to the right place.", style = Type.body, color = Brand.textSecondary)
            }
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                features.forEachIndexed { index, (icon, title, detail) ->
                    Row(Modifier.fadeUp(0.12 + index * 0.05), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(Modifier.size(40.dp).clip(CircleShape).background(Brand.surface).border(1.dp, Brand.stroke, CircleShape), contentAlignment = Alignment.Center) {
                            Icon(sf(icon), null, tint = Brand.blueInk, modifier = Modifier.size(20.dp))
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(title, style = Type.headline, color = Brand.textPrimary)
                            Text(detail, style = Type.subheadline, color = Brand.textSecondary)
                        }
                    }
                }
            }
            Column(Modifier.fadeUp(0.3), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                PillButton("Create account", onSignUp)
                GoogleButton(enabled = !google.isLoading) { scope.launch { google.signInWithGoogle() } }
                google.errorMessage?.let { ErrorBanner(it) }
                PillButton("I already have an account", onSignIn, kind = PillKind.ghost, height = 48.dp)
            }
            Spacer(Modifier.height(Space.md))
        }
    }
}

/** "Continue with Google" (the iOS app's Sign in with Apple); the mock auth signs in a demo user. */
@Composable
fun GoogleButton(enabled: Boolean = true, onClick: () -> Unit) {
    PillButton("Continue with Google", onClick, kind = PillKind.dark, enabled = enabled,
        leading = {
            Box(Modifier.size(22.dp).clip(CircleShape).background(Color.White).border(1.dp, Color(0x22000000), CircleShape), contentAlignment = Alignment.Center) {
                Text("G", style = Type.headline.bold(), color = Color(0xFF4285F4))
            }
        })
}

@Composable
private fun SignUpScreen(onBack: () -> Unit) {
    val env = LocalEnvironment.current
    val scope = rememberCoroutineScope()
    val viewModel = remember { SignUpViewModel(env.session) }
    val focus = LocalFocusManager.current
    val requesters = remember { SignUpViewModel.Field.entries.associateWith { FocusRequester() } }
    fun leave(field: SignUpViewModel.Field) { viewModel.touched = viewModel.touched + field }
    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().imePadding()) {
        TopBar("", leading = BarAction("", icon = "chevron.left", run = onBack))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg) {
                Column(Modifier.fadeUp(), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                    PulseWordmark(Modifier.padding(bottom = Space.sm))
                    Text("Create your account", style = Type.largeTitle.bold(), color = Brand.textPrimary)
                    Text("Takes a minute. Next, a few quick questions to set up your safety profile.", style = Type.body, color = Brand.textSecondary)
                }
                AnimatedVisibility(viewModel.errorMessage != null) { ErrorBanner(viewModel.errorMessage ?: "") }
                Column(Modifier.fadeUp(0.08), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    FormField("Full name", viewModel.name, { viewModel.name = it }, error = viewModel.error(SignUpViewModel.Field.fullName),
                        placeholder = "Jane Doe", icon = "person.fill", capitalization = KeyboardCapitalization.Words,
                        focusRequester = requesters[SignUpViewModel.Field.fullName], onFocusLost = { leave(SignUpViewModel.Field.fullName) },
                        onImeAction = { requesters[SignUpViewModel.Field.email]?.requestFocus() })
                    FormField("Email", viewModel.email, { viewModel.email = it }, error = viewModel.error(SignUpViewModel.Field.email),
                        placeholder = "you@example.com", icon = "envelope.fill", keyboardType = KeyboardType.Email,
                        capitalization = KeyboardCapitalization.None, focusRequester = requesters[SignUpViewModel.Field.email],
                        onFocusLost = { leave(SignUpViewModel.Field.email) }, onImeAction = { requesters[SignUpViewModel.Field.password]?.requestFocus() })
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        FormField("Password", viewModel.password, { viewModel.password = it }, error = viewModel.error(SignUpViewModel.Field.password),
                            placeholder = "At least 8 characters", isSecure = true, icon = "lock.fill",
                            focusRequester = requesters[SignUpViewModel.Field.password], onFocusLost = { leave(SignUpViewModel.Field.password) },
                            onImeAction = { requesters[SignUpViewModel.Field.confirm]?.requestFocus() })
                        AnimatedVisibility(viewModel.password.isNotEmpty()) { PasswordStrengthMeter(viewModel.password) }
                    }
                    FormField("Confirm password", viewModel.confirmPassword, { viewModel.confirmPassword = it },
                        error = viewModel.error(SignUpViewModel.Field.confirm), placeholder = "Type it again", isSecure = true, icon = "lock.rotation",
                        imeAction = ImeAction.Done, focusRequester = requesters[SignUpViewModel.Field.confirm],
                        onFocusLost = { leave(SignUpViewModel.Field.confirm) },
                        onImeAction = { focus.clearFocus(); scope.launch { viewModel.submit() } })
                }
                Column(Modifier.fadeUp(0.16), verticalArrangement = Arrangement.spacedBy(Space.md), horizontalAlignment = Alignment.CenterHorizontally) {
                    LoadingPill("Create account", viewModel.isLoading) { focus.clearFocus(); scope.launch { viewModel.submit() } }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(sf("lock.shield.fill"), null, tint = Brand.textSecondary, modifier = Modifier.size(14.dp))
                        Text("Your profile, trips and medical notes stay on this phone.", style = Type.footnote, color = Brand.textSecondary)
                    }
                }
                Spacer(Modifier.height(Space.md))
            }
        }
    }
}

@Composable
private fun SignInScreen(onBack: () -> Unit) {
    val env = LocalEnvironment.current
    val scope = rememberCoroutineScope()
    val viewModel = remember { SignInViewModel(env.session) }
    val focus = LocalFocusManager.current
    val passwordFocus = remember { FocusRequester() }
    var showingForgot by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(Brand.background).statusBarsPadding().imePadding()) {
        TopBar("", leading = BarAction("", icon = "chevron.left", run = onBack))
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg) {
                Column(Modifier.fadeUp(), verticalArrangement = Arrangement.spacedBy(Space.sm)) {
                    PulseWordmark(Modifier.padding(bottom = Space.sm))
                    Text("Welcome back", style = Type.largeTitle.bold(), color = Brand.textPrimary)
                    Text("Sign in to pick up where you left off.", style = Type.body, color = Brand.textSecondary)
                }
                AnimatedVisibility(viewModel.errorMessage != null) { ErrorBanner(viewModel.errorMessage ?: "") }
                Column(Modifier.fadeUp(0.08), verticalArrangement = Arrangement.spacedBy(18.dp), horizontalAlignment = Alignment.End) {
                    FormField("Email", viewModel.email, { viewModel.email = it }, error = viewModel.emailError, placeholder = "you@example.com",
                        icon = "envelope.fill", keyboardType = KeyboardType.Email, capitalization = KeyboardCapitalization.None,
                        onImeAction = { passwordFocus.requestFocus() })
                    FormField("Password", viewModel.password, { viewModel.password = it }, error = viewModel.passwordError, isSecure = true,
                        icon = "lock.fill", imeAction = ImeAction.Go, focusRequester = passwordFocus,
                        onImeAction = { focus.clearFocus(); scope.launch { viewModel.signIn() } })
                    LinkButton("Forgot password?", { showingForgot = true })
                }
                Column(Modifier.fadeUp(0.16), verticalArrangement = Arrangement.spacedBy(Space.md)) {
                    LoadingPill("Sign in", viewModel.isLoading) { focus.clearFocus(); scope.launch { viewModel.signIn() } }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.weight(1f).height(1.dp).background(Brand.stroke))
                        Text("or", style = Type.footnote, color = Brand.textSecondary)
                        Box(Modifier.weight(1f).height(1.dp).background(Brand.stroke))
                    }
                    GoogleButton(enabled = !viewModel.isLoading) { focus.clearFocus(); scope.launch { viewModel.signInWithGoogle() } }
                }
            }
        }
    }
    if (showingForgot) ForgotPasswordSheet(viewModel.email) { showingForgot = false }
}

@Composable
private fun ForgotPasswordSheet(email: String, onDismiss: () -> Unit) {
    val env = LocalEnvironment.current
    val scope = rememberCoroutineScope()
    val viewModel = remember { ForgotPasswordViewModel(env.session.auth, email) }
    FullScreenSheet(onDismiss, title = "Reset password", leading = BarAction("Cancel", run = onDismiss)) {
        ReadableColumn(horizontalPadding = Space.lg, spacing = Space.lg, modifier = Modifier.padding(top = Space.md)) {
            if (viewModel.sent) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.md)) {
                    IconBadge("envelope.badge.fill", Brand.blue, 64.dp)
                    Text("Check your email", style = Type.title2.bold(), color = Brand.textPrimary)
                    Text("If an account exists for ${viewModel.email}, we sent a link to reset your password.",
                        style = Type.body, color = Brand.textSecondary, textAlign = TextAlign.Center)
                }
                PillButton("Done", onDismiss)
            } else {
                Text("Enter the email you signed up with and we'll send you a reset link.", style = Type.body, color = Brand.textSecondary)
                FormField("Email", viewModel.email, { viewModel.email = it }, error = viewModel.errorMessage, icon = "envelope.fill",
                    keyboardType = KeyboardType.Email, capitalization = KeyboardCapitalization.None, imeAction = ImeAction.Send,
                    onImeAction = { scope.launch { viewModel.send() } })
                LoadingPill("Send reset link", viewModel.isLoading) { scope.launch { viewModel.send() } }
            }
        }
    }
}

@Composable
fun LoadingPill(title: String, loading: Boolean, onClick: () -> Unit) {
    if (loading) {
        Box(Modifier.fillMaxWidth().height(56.dp).clip(CircleShape).background(Brand.blue), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.5.dp, modifier = Modifier.size(24.dp))
        }
    } else {
        PillButton(title, onClick)
    }
}
