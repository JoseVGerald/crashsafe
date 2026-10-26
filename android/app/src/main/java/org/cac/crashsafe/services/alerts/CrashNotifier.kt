package org.cac.crashsafe.services.alerts

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.cac.crashsafe.CrashSafeApplication
import org.cac.crashsafe.MainActivity
import org.cac.crashsafe.R
import org.cac.crashsafe.core.crash.CrashEvent
import org.cac.crashsafe.model.CheckInOutcome

/**
 * Lock-screen side of the crash check-in. The countdown itself runs in `CrashResponseCenter`;
 * this only tells a driver who isn't looking at the app that it's waiting for an answer.
 */
interface CrashNotifying {
    fun postCheckIn(event: CrashEvent, secondsToRespond: Int, contactSummary: String?)
    fun withdrawCheckIn(event: CrashEvent)
    fun postFollowUp(text: String, event: CrashEvent)
}

/** Identifiers shared by the notifier, the action receiver and `MainActivity`. */
object CrashNotification {
    const val CHECK_IN_CHANNEL = "crash_checkin"
    const val FOLLOW_UP_CHANNEL = "crash_followup"
    const val DRIVE_CHANNEL = "drive_monitor"
    const val EXTRA_OUTCOME = "org.cac.crashsafe.checkInOutcome"
    const val EXTRA_OPEN_CHECK_IN = "org.cac.crashsafe.openCheckIn"
    const val ACTION_RESPOND = "org.cac.crashsafe.RESPOND_CHECK_IN"

    fun checkInID(event: CrashEvent) = event.id.hashCode()
    fun followUpID(event: CrashEvent) = event.id.hashCode() + 1

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val alarm = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
        manager.createNotificationChannel(NotificationChannel(CHECK_IN_CHANNEL, "Crash check-in", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Asks if you're okay after a possible crash."
            setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), alarm)
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 400, 200, 400)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        })
        manager.createNotificationChannel(NotificationChannel(FOLLOW_UP_CHANNEL, "After a check-in", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Who was alerted after a check-in."
        })
        manager.createNotificationChannel(NotificationChannel(DRIVE_CHANNEL, "Watching your drive", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shown while Pulse coaches you and watches for crashes."
        })
    }
}

/** Posts the check-in as a full-screen, alarm-style notification with "I'm OK" and "I need help". */
class LocalCrashNotifier(private val context: Context) : CrashNotifying {
    override fun postCheckIn(event: CrashEvent, secondsToRespond: Int, contactSummary: String?) {
        val body = contactSummary?.let { "Are you OK? If you don't answer in $secondsToRespond seconds, we'll alert $it with your location." }
            ?: "Are you OK? If you don't answer in $secondsToRespond seconds, we'll treat it as an emergency."
        val open = PendingIntent.getActivity(context, 1, Intent(context, MainActivity::class.java)
            .putExtra(CrashNotification.EXTRA_OPEN_CHECK_IN, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        // "I'm OK" works from the lock screen without unlocking; "I need help" opens the app to the help hub.
        val ok = PendingIntent.getBroadcast(context, 2, Intent(context, CheckInActionReceiver::class.java)
            .setAction(CrashNotification.ACTION_RESPOND)
            .putExtra(CrashNotification.EXTRA_OUTCOME, CheckInOutcome.ok.name), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val help = PendingIntent.getActivity(context, 3, Intent(context, MainActivity::class.java)
            .putExtra(CrashNotification.EXTRA_OUTCOME, CheckInOutcome.needsHelp.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(context, CrashNotification.CHECK_IN_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_pulse)
            .setContentTitle(if (event.isSimulated) "Test crash — are you OK?" else "Possible crash detected")
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(open)
            .setFullScreenIntent(open, true)
            .setTimeoutAfter((secondsToRespond + 10) * 1000L)
            .addAction(0, "I'm OK", ok)
            .addAction(0, "I need help", help)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(CrashNotification.checkInID(event), notification) }
    }

    override fun withdrawCheckIn(event: CrashEvent) {
        NotificationManagerCompat.from(context).cancel(CrashNotification.checkInID(event))
    }

    override fun postFollowUp(text: String, event: CrashEvent) {
        val open = PendingIntent.getActivity(context, 4, Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CrashNotification.FOLLOW_UP_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_pulse)
            .setContentTitle("CrashSafe")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(CrashNotification.followUpID(event), notification) }
    }
}

/** Receives "I'm OK" from the notification, so an answer from the lock screen reaches the running countdown. */
class CheckInActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CrashNotification.ACTION_RESPOND) return
        val outcome = intent.getStringExtra(CrashNotification.EXTRA_OUTCOME)?.let { runCatching { CheckInOutcome.valueOf(it) }.getOrNull() } ?: return
        (context.applicationContext as? CrashSafeApplication)?.environment?.crashCenter?.respond(outcome)
    }
}

/** For tests and previews. */
class NoCrashNotifier : CrashNotifying {
    override fun postCheckIn(event: CrashEvent, secondsToRespond: Int, contactSummary: String?) {}
    override fun withdrawCheckIn(event: CrashEvent) {}
    override fun postFollowUp(text: String, event: CrashEvent) {}
}
