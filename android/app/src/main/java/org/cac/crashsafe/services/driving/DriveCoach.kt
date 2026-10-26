package org.cac.crashsafe.services.driving

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.cac.crashsafe.core.driving.CoachingEngine
import org.cac.crashsafe.core.driving.CoachingMessage
import org.cac.crashsafe.core.driving.DrivingAdvice
import org.cac.crashsafe.core.util.nowSeconds
import org.cac.crashsafe.model.CoachingStyle
import org.cac.crashsafe.model.DrivingExperience
import org.cac.crashsafe.services.assistant.PulseSpeaker
import org.cac.crashsafe.services.weather.ConditionsStore

/**
 * Turns live driving data into spoken coaching, independent of which screen is open.
 * With the drive's foreground service it keeps working with the screen off.
 */
class DriveCoach(
    private val driving: DrivingMonitor,
    private val conditions: ConditionsStore,
    private val speaker: PulseSpeaker,
    private val scope: CoroutineScope,
) {
    data class ProfileInputs(val style: CoachingStyle, val experience: DrivingExperience, val lovedOne: String?)

    var message by mutableStateOf<CoachingMessage?>(null)
        private set
    var messageID by mutableIntStateOf(0)
        private set
    var speaks by mutableStateOf(true)
        private set

    /** Supplies the driver profile inputs each time the coach evaluates. */
    var profileProvider: () -> ProfileInputs = { ProfileInputs(CoachingStyle.logical, DrivingExperience.newDriver, null) }

    private var loop: Job? = null
    private val spokenAt = mutableMapOf<String, Double>()

    val isNight: Boolean get() = driving.scenario?.isNight ?: conditions.isNight

    fun updateSpeaks(on: Boolean) {
        speaks = on
        if (!on) speaker.stop()
    }

    fun start() {
        if (loop != null) return
        loop = scope.launch {
            while (isActive) {
                evaluate()
                delay(2000)
            }
        }
    }

    fun stop() {
        loop?.cancel()
        loop = null
        speaker.stop()
    }

    private fun evaluate() {
        if (!driving.isActive || !driving.snapshot.isMoving) return
        val profile = profileProvider()
        val next = CoachingEngine.message(CoachingEngine.Input(
            snapshot = driving.snapshot,
            advice = DrivingAdvice.make(conditions.weather, isNight),
            weather = conditions.weather,
            isNight = isNight,
            style = profile.style,
            experience = profile.experience,
            lovedOne = profile.lovedOne))
        if (next == message) return
        val isNewAdvice = next.title != message?.title
        message = next
        // Animate/speak only for new advice; numbers in the same advice just refresh.
        if (isNewAdvice) {
            messageID++
            speak(next)
        }
    }

    private fun speak(message: CoachingMessage) {
        // Only when over the speed limit or entering a careful area; other advice stays on screen.
        if (!speaks || !message.speaksAloud) return
        // Don't nag: the same warning at most once a minute.
        val last = spokenAt[message.title]
        if (last != null && nowSeconds() - last < message.repeatAfter) return
        spokenAt[message.title] = nowSeconds()
        speaker.speak("${message.title}. ${message.body}")
    }
}
