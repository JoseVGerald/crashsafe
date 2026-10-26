package org.cac.crashsafe.services.carapp

import android.content.Intent
import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.CarContext
import androidx.car.app.CarToast
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarColor
import androidx.car.app.model.MessageTemplate
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Row
import androidx.car.app.model.Template
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.cac.crashsafe.CrashSafeApplication
import org.cac.crashsafe.R
import org.cac.crashsafe.app.AppEnvironment
import org.cac.crashsafe.core.driving.CoachingMessage
import org.cac.crashsafe.core.driving.DrivingAdvice
import org.cac.crashsafe.core.driving.DrivingComparison

/**
 * Android Auto (the iOS app's CarPlay scene). Car apps can only use the host's templates, so this shows an
 * information pane (speed, safe speed, conditions, Pulse's advice) and raises a toast when coaching turns
 * into a warning. Runs in the Desktop Head Unit with "Unknown sources" on; publishing to cars needs Google's
 * review for the IoT category (see README → Android Auto).
 */
class CrashSafeCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) HostValidator.ALLOW_ALL_HOSTS_VALIDATOR
        else HostValidator.Builder(applicationContext).addAllowedHosts(R.array.car_hosts_allowlist).build()

    override fun onCreateSession(): Session = object : Session() {
        override fun onCreateScreen(intent: Intent): Screen = DashboardScreen(carContext)
    }
}

/** The one screen: refreshed every 2 s while it is showing, like the CarPlay dashboard. */
class DashboardScreen(carContext: CarContext) : Screen(carContext) {
    private val env: AppEnvironment = (carContext.applicationContext as CrashSafeApplication).environment
    private var shownWarningID = 0

    init {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    invalidate()
                    showWarningIfNeeded()
                    delay(2000)
                }
            }
        }
    }

    override fun onGetTemplate(): Template {
        if (env.session.user == null) {
            return MessageTemplate.Builder("Open CrashSafe on your phone and sign in to start coaching.")
                .setTitle("CrashSafe")
                .setHeaderAction(Action.APP_ICON)
                .build()
        }
        val snapshot = env.driving.snapshot
        val isNight = env.coach.isNight
        val advice = DrivingAdvice.make(env.conditions.weather, isNight)
        val comparison = DrivingComparison.make(snapshot, advice, env.driving.isActive)

        // Hosts show at most four rows in a pane, so related numbers share a row.
        val limit = snapshot.speedLimitMPH?.let { "${it.toInt()} mph" + (snapshot.roadName?.let { name -> " · $name" } ?: "") } ?: "—"
        val pane = Pane.Builder()
            .addRow(Row.Builder()
                .setTitle("${snapshot.speedMPH.toInt()} mph")
                .addText((if (snapshot.speedLimitIsPosted) "Limit " else "Typical limit ") + limit)
                .build())
            .addRow(Row.Builder()
                .setTitle("Safe now: " + (comparison.recommendedMaxMPH?.let { "${it.toInt()} mph" } ?: "—"))
                .addText("Status: ${comparison.status.label}" + (snapshot.roadSegment?.let { " · ${it.title}" } ?: ""))
                .build())
            .addRow(Row.Builder()
                .setTitle("Conditions")
                .addText(env.conditions.weather?.let { "${it.temperatureF.toInt()}° ${it.condition.label}" + if (isNight) " · night" else "" }
                    ?: if (isNight) "Night" else "—")
                .build())
            .addRow(Row.Builder()
                .setTitle("Pulse")
                .addText(env.coach.message?.title ?: if (env.driving.isActive) "Riding along" else "Start a drive on your phone")
                .build())
            .addAction(Action.Builder()
                .setTitle(if (env.coach.speaks) "Mute Pulse" else "Unmute Pulse")
                .setOnClickListener {
                    env.coach.updateSpeaks(!env.coach.speaks)
                    invalidate()
                }
                .build())
            .addAction(Action.Builder()
                .setTitle("I need help")
                .setBackgroundColor(CarColor.RED)
                .setOnClickListener { env.crashDetector.simulateCrash() }
                .build())
            .build()
        return PaneTemplate.Builder(pane)
            .setTitle("CrashSafe")
            .setHeaderAction(Action.APP_ICON)
            .setActionStrip(ActionStrip.Builder().addAction(Action.Builder().setTitle(if (env.driving.isActive) "Live" else "Idle").build()).build())
            .build()
    }

    /** A glanceable toast when Pulse issues a new warning. */
    private fun showWarningIfNeeded() {
        val message = env.coach.message ?: return
        if (message.severity != CoachingMessage.Severity.warning || env.coach.messageID == shownWarningID) return
        shownWarningID = env.coach.messageID
        CarToast.makeText(carContext, message.title, CarToast.LENGTH_LONG).show()
    }
}
