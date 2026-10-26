package org.cac.crashsafe.features.checkin

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.services.alerts.AlertDelivery
import org.cac.crashsafe.services.alerts.AlertRecipient
import org.cac.crashsafe.services.alerts.CrashAlarm
import org.cac.crashsafe.services.alerts.CrashNotifying
import org.cac.crashsafe.services.alerts.EmergencyAlertService
import org.cac.crashsafe.services.alerts.EmergencyDialer
import org.cac.crashsafe.services.alerts.NoEmergencyDialer
import org.cac.crashsafe.services.alerts.SilentCrashAlarm

/** Drives the "Are you OK?" countdown and decides which path the driver takes. */
class CheckInViewModel(
    val event: CrashEvent,
    val recipients: List<AlertRecipient>,
    private val alerts: EmergencyAlertService,
    private val isOnline: () -> Boolean,
    private val scope: CoroutineScope,
    val duration: Int = 30,
    private val tickMillis: Long = 1000,
) {
    sealed interface Phase {
        data object Counting : Phase
        data class Resolved(val outcome: CheckInOutcome) : Phase
    }

    var secondsRemaining by mutableIntStateOf(duration)
        private set
    var phase by mutableStateOf<Phase>(Phase.Counting)
        private set
    var isAlerting by mutableStateOf(false)
        private set
    var alertDelivery by mutableStateOf<AlertDelivery?>(null)
        private set

    /** Called once, when the driver answers or the countdown runs out. */
    var onResolve: ((CheckInOutcome) -> Unit)? = null
    /** Called every second of the countdown with the seconds left (drives the spoken prompts). */
    var onTick: ((Int) -> Unit)? = null
    private var timer: Job? = null

    val progress: Double get() = if (duration == 0) 0.0 else secondsRemaining.toDouble() / duration

    fun start() {
        if (timer != null || phase != Phase.Counting) return
        timer = scope.launch {
            while (secondsRemaining > 0) {
                delay(tickMillis)
                if (!isActive) return@launch
                secondsRemaining--
                onTick?.invoke(secondsRemaining)
            }
            resolve(CheckInOutcome.noResponse)
        }
    }

    fun respond(outcome: CheckInOutcome) = resolve(outcome)

    fun stop() {
        timer?.cancel()
        timer = null
    }

    private fun resolve(outcome: CheckInOutcome) {
        if (phase != Phase.Counting) return
        stop()
        phase = Phase.Resolved(outcome)
        onResolve?.invoke(outcome)
        if (outcome != CheckInOutcome.ok && recipients.isNotEmpty()) {
            scope.launch {
                isAlerting = true
                alertDelivery = alerts.alertFamily(recipients, outcome, event, isOnline())
                isAlerting = false
            }
        }
    }
}

/**
 * Owns the "Are you OK?" check-in from the moment a crash is detected, independent of any screen.
 * The countdown starts immediately — with the phone locked in a pocket there may be no screen to
 * start it — and a lock-screen notification asks the driver to answer. The full-screen
 * `CheckInScreen` shows this same view model when the app is open.
 */
class CrashResponseCenter(
    private val alerts: EmergencyAlertService,
    private val notifier: CrashNotifying,
    private val isOnline: () -> Boolean,
    private val scope: CoroutineScope,
    private val alarm: CrashAlarm = SilentCrashAlarm(),
    private val dialer: EmergencyDialer = NoEmergencyDialer(),
    private val duration: Int = 30,
    private val tickMillis: Long = 1000,
) {
    var current by mutableStateOf<CheckInViewModel?>(null)
        private set
    /** The siren is sounding (no answer). The driver or a bystander can stop it. */
    var isSirenOn by mutableStateOf(false)
        private set
    /** A 911 call was started (Android shows the dialer to confirm). */
    var startedEmergencyCall by mutableStateOf(false)
        private set
    /** How many times the driver has been asked "Are you okay?" in this check-in. */
    var promptsSpoken by mutableIntStateOf(0)
        private set

    /** The driver's family contacts, read when a crash happens (owner ID → recipients). */
    var recipientsProvider: (String) -> List<AlertRecipient> = { emptyList() }
    /** Saves the outcome (owner ID, event, outcome). */
    var recordOutcome: (String, CrashEvent, CheckInOutcome) -> Unit = { _, _, _ -> }
    /** Keeps the process alive to finish the countdown and family alert; returns the call that releases it. */
    var keepAlive: (String) -> (() -> Unit) = { { } }

    val isCounting: Boolean get() = current?.phase == CheckInViewModel.Phase.Counting

    /** Starts the check-in for `event`. While one is still counting down, a second event is ignored. */
    fun begin(event: CrashEvent, ownerID: String): CheckInViewModel {
        current?.let { if (it.phase == CheckInViewModel.Phase.Counting) return it }
        val recipients = recipientsProvider(ownerID)
        val viewModel = CheckInViewModel(event, recipients, alerts, isOnline, scope, duration, tickMillis)
        val release = keepAlive("Crash check-in")
        isSirenOn = false
        startedEmergencyCall = false
        promptsSpoken = 0
        viewModel.onTick = { remaining -> prompt(remaining) }
        viewModel.onResolve = { outcome ->
            escalate(outcome, event)
            notifier.withdrawCheckIn(event)
            followUp(outcome, recipients)?.let { notifier.postFollowUp(it, event) }
            recordOutcome(ownerID, event, outcome)
            // Hold on until the family alert (if any) has gone out.
            scope.launch {
                delay(100)
                while (viewModel.isAlerting) delay(200)
                delay(2000)
                release()
            }
        }
        current = viewModel
        viewModel.start()
        notifier.postCheckIn(event, duration, summary(recipients))
        prompt(duration)
        return viewModel
    }

    /** "Are you okay?" every 5 seconds until the driver answers or time runs out. */
    private fun prompt(remaining: Int) {
        if (current?.phase != CheckInViewModel.Phase.Counting || remaining <= 0 || remaining % 5 != 0) return
        promptsSpoken++
        alarm.say(promptText(remaining))
    }

    /**
     * No answer: siren for anyone nearby, family alerted (by the check-in), and the 911 call started.
     * "I need help": the 911 call started and family alerted. Test crashes never start a 911 call.
     */
    private fun escalate(outcome: CheckInOutcome, event: CrashEvent) {
        alarm.stopAll()
        when (outcome) {
            CheckInOutcome.ok -> alarm.say(okLine)
            CheckInOutcome.needsHelp -> {
                alarm.say(helpLine)
                if (!event.isSimulated) {
                    dialer.call911()
                    startedEmergencyCall = true
                }
            }
            CheckInOutcome.noResponse -> {
                alarm.startSiren()
                isSirenOn = true
                if (!event.isSimulated) {
                    dialer.call911()
                    startedEmergencyCall = true
                }
            }
        }
    }

    fun stopSiren() {
        alarm.stopSiren()
        isSirenOn = false
    }

    fun startSiren() {
        alarm.startSiren()
        isSirenOn = true
    }

    /** An answer from the lock screen (or anywhere outside the check-in screen). */
    fun respond(outcome: CheckInOutcome) {
        current?.respond(outcome)
    }

    /** The driver closed the help hub; forget the finished check-in. */
    fun dismiss() {
        if (current?.phase == CheckInViewModel.Phase.Counting) return
        stopSiren()
        current = null
    }

    companion object {
        const val okLine = "Okay. I'm glad you're okay."
        const val helpLine = "Getting you help."

        fun promptText(remaining: Int): String = when {
            remaining == 10 -> "Are you okay? If you don't answer in 10 seconds, I'll sound an alarm and call for help."
            remaining <= 5 -> "Are you okay? $remaining seconds."
            else -> "Are you okay? Tap I'm OK if you're all right."
        }

        fun summary(recipients: List<AlertRecipient>): String? {
            val names = recipients.map { it.name }
            return when (names.size) {
                0 -> null
                1 -> names[0]
                2 -> "${names[0]} and ${names[1]}"
                else -> "your ${names.size} family contacts"
            }
        }

        /** What to tell a driver who may not be looking at the screen once the check-in resolves. */
        fun followUp(outcome: CheckInOutcome, recipients: List<AlertRecipient>): String? {
            if (outcome == CheckInOutcome.ok) return null
            val who = summary(recipients) ?: return "No family contacts saved. Call 911 if anyone is hurt."
            return if (outcome == CheckInOutcome.noResponse) "No answer, so we're alerting $who with your location."
            else "Alerting $who with your location. Call 911 if anyone is hurt."
        }
    }
}
