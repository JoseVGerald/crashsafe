package org.cac.crashsafe.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.core.pulse.AssistantIncident
import org.cac.crashsafe.core.pulse.AssistantScenario
import org.cac.crashsafe.model.AuthUser
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.services.auth.AuthService

/** Auth state for the whole app. */
class SessionStore(val auth: AuthService) {
    sealed interface Phase {
        data object Launching : Phase
        data object SignedOut : Phase
        data class SignedIn(val user: AuthUser) : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Launching)
        private set

    val user: AuthUser? get() = (phase as? Phase.SignedIn)?.user

    /** Restores any saved session, keeping the splash up for at least `minimumSplashMillis`. */
    suspend fun restore(minimumSplashMillis: Long = 1400) {
        val started = System.currentTimeMillis()
        val user = auth.restoreSession()
        val left = minimumSplashMillis - (System.currentTimeMillis() - started)
        if (left > 0) delay(left)
        phase = user?.let { Phase.SignedIn(it) } ?: Phase.SignedOut
    }

    fun didAuthenticate(user: AuthUser) {
        phase = Phase.SignedIn(user)
    }

    fun signOut() {
        auth.signOut()
        phase = Phase.SignedOut
    }

    suspend fun deleteAccount() {
        auth.deleteAccount()
        phase = Phase.SignedOut
    }

    /** For previews/tests. */
    fun forceSignIn(user: AuthUser) {
        phase = Phase.SignedIn(user)
    }
}

/** Cross-screen navigation: selected tab, crash check-in, and how the assistant was opened. */
class AppRouter {
    enum class Tab { home, trips, pulseVoice, assistant, profile }

    var selectedTab by mutableStateOf(Tab.home)
    /** Non-null while the full-screen "Are you OK?" check-in is showing. */
    var activeCrash by mutableStateOf<CrashEvent?>(null)
        private set
    var assistantIncident by mutableStateOf<AssistantIncident?>(null)
    /** Set when the check-in hands off to the assistant; consumed by the assistant screen. */
    var pendingAssistantScenario by mutableStateOf<AssistantScenario?>(null)
    /** Full-screen CarPlay-style driving mode. */
    var showingCarPlay by mutableStateOf(false)
    /** Called whenever the check-in closes (the crash center forgets it). */
    var onCrashClosed: () -> Unit = {}

    fun showCrash(event: CrashEvent) {
        activeCrash = event
        assistantIncident = AssistantIncident.make(event)
    }

    fun closeCrash() {
        if (activeCrash == null) return
        activeCrash = null
        onCrashClosed()
    }

    fun openAssistant(after: CheckInOutcome) {
        pendingAssistantScenario = AssistantScenario.AfterCrash(after)
        closeCrash()
        selectedTab = Tab.assistant
    }

    fun openPulseVoice() {
        selectedTab = Tab.pulseVoice
    }
}
