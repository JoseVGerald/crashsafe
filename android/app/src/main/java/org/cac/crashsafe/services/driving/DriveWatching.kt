package org.cac.crashsafe.services.driving

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.cac.crashsafe.CrashSafeApplication
import org.cac.crashsafe.MainActivity
import org.cac.crashsafe.R
import org.cac.crashsafe.model.CarType
import org.cac.crashsafe.services.alerts.CrashNotification
import org.cac.crashsafe.services.crash.CrashDetector
import org.cac.crashsafe.services.location.DriveWakeupSource

/**
 * Starts live monitoring automatically when Android's activity recognition says the phone is in a moving vehicle
 * (iOS: Core Motion's automotive activity). Needs the physical-activity permission and Google Play services.
 */
class DriveAutoDetector(private val context: Context) {
    var isDriving by mutableStateOf(false)
        private set
    var onDriveStarted: (() -> Unit)? = null
    var onDriveEnded: (() -> Unit)? = null

    private val pendingIntent: PendingIntent by lazy {
        PendingIntent.getBroadcast(context, 10, Intent(context, ActivityTransitionReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
    }

    val isAvailable: Boolean
        get() = Build.VERSION.SDK_INT < 29 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    fun start() {
        if (!isAvailable) return
        val transitions = listOf(
            transition(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
            transition(DetectedActivity.IN_VEHICLE, ActivityTransition.ACTIVITY_TRANSITION_EXIT),
            transition(DetectedActivity.STILL, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
            transition(DetectedActivity.WALKING, ActivityTransition.ACTIVITY_TRANSITION_ENTER),
        )
        runCatching {
            ActivityRecognition.getClient(context).requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), pendingIntent)
                .addOnFailureListener { Log.w(TAG, "activity transitions unavailable", it) }
        }.onFailure { Log.w(TAG, "activity recognition unavailable", it) }
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        runCatching { ActivityRecognition.getClient(context).removeActivityTransitionUpdates(pendingIntent) }
    }

    fun handle(result: ActivityTransitionResult) {
        for (event in result.transitionEvents) {
            val enteringVehicle = event.activityType == DetectedActivity.IN_VEHICLE && event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            val leaving = (event.activityType == DetectedActivity.IN_VEHICLE && event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_EXIT) ||
                (event.activityType in listOf(DetectedActivity.STILL, DetectedActivity.WALKING) && event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER)
            if (enteringVehicle && !isDriving) {
                isDriving = true
                onDriveStarted?.invoke()
            } else if (leaving && isDriving) {
                isDriving = false
                onDriveEnded?.invoke()
            }
        }
    }

    private fun transition(activity: Int, type: Int) =
        ActivityTransition.Builder().setActivityType(activity).setActivityTransition(type).build()

    private companion object {
        const val TAG = "CrashSafe.drives"
    }
}

/** Activity recognition's transitions (entering or leaving a vehicle), even while the app is closed. */
class ActivityTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        (context.applicationContext as? CrashSafeApplication)?.environment?.autoDetector?.handle(result)
    }
}

/** After a reboot, the app starts so "Watch every drive" re-registers for activity transitions (see `resumeIfArmed`). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Creating the application already resumed the watcher.
        (context.applicationContext as? CrashSafeApplication)?.environment
    }
}

/**
 * "Watch every drive": when activity recognition reports a drive, start the driving monitor *and* crash
 * detection, and stop only what it started when the drive ends (a trip the driver started by hand is
 * left alone). The armed state is saved, so when Android starts a closed app for an activity transition —
 * with no screen on display — `resumeIfArmed()` brings detection back without any screen appearing.
 */
class BackgroundDriveWatcher(
    private val driving: DrivingMonitor,
    private val crashDetector: CrashDetector,
    private val wakeups: DriveWakeupSource,
    private val autoDetector: DriveAutoDetector?,
    private val prefs: SharedPreferences,
) {
    @Serializable
    data class Configuration(val ownerID: String, val carType: CarType)

    var configuration by mutableStateOf<Configuration?>(null)
        private set
    var startedDriving = false
        private set
    var startedDetection = false
        private set

    val isArmed: Boolean get() = configuration != null

    /** Watch every drive for this driver and car. Saved so a background start can resume. */
    fun arm(configuration: Configuration) {
        this.configuration = configuration
        prefs.edit().putString(STORAGE_KEY, Json.encodeToString(Configuration.serializer(), configuration)).apply()
        wakeups.setDriveWakeups(true)
        val detector = autoDetector ?: return
        detector.onDriveStarted = { driveStarted() }
        detector.onDriveEnded = { driveEnded() }
        detector.start()
    }

    /** Stop watching (setting turned off, or signed out). */
    fun disarm() {
        configuration = null
        prefs.edit().remove(STORAGE_KEY).apply()
        wakeups.setDriveWakeups(false)
        autoDetector?.stop()
        driveEnded()
    }

    /** Call on every launch, including a background start for an activity transition. */
    fun resumeIfArmed() {
        if (configuration != null) return
        val saved = prefs.getString(STORAGE_KEY, null)?.let { runCatching { Json.decodeFromString(Configuration.serializer(), it) }.getOrNull() } ?: return
        arm(saved)
    }

    fun driveStarted() {
        val configuration = configuration ?: return
        if (!driving.isActive) {
            driving.startLive(background = true)
            startedDriving = true
        }
        if (!crashDetector.isMonitoring) {
            crashDetector.startMonitoring(configuration.carType)
            startedDetection = true
        }
    }

    fun driveEnded() {
        if (startedDetection) {
            crashDetector.stopMonitoring()
            startedDetection = false
        }
        if (startedDriving) {
            if (driving.mode == DrivingMonitor.Mode.Live) driving.stop()
            startedDriving = false
        }
    }

    private companion object {
        const val STORAGE_KEY = "driveWatcher.configuration"
    }
}

/**
 * Keeps CrashSafe running with the screen off during a drive (iOS: the `location` + `audio` background modes):
 * a location foreground service with an ongoing notification, and a partial wake lock so motion keeps flowing.
 * The sensors themselves are owned by the app's shared `SensorHub`; this service only keeps the process awake.
 */
class DriveMonitorService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = PendingIntent.getActivity(this, 20, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val notification: Notification = NotificationCompat.Builder(this, CrashNotification.DRIVE_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_pulse)
            .setContentTitle("Pulse is riding along")
            .setContentText("Coaching your drive and watching for crashes.")
            .setOngoing(true)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_NAVIGATION)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "couldn't start the drive foreground service", e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CrashSafe:drive")?.apply {
                setReferenceCounted(false)
                acquire(4 * 60 * 60 * 1000L)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "CrashSafe.drives"
        const val NOTIFICATION_ID = 7001

        fun setRunning(context: Context, running: Boolean) {
            val intent = Intent(context, DriveMonitorService::class.java)
            if (running) {
                runCatching { ContextCompat.startForegroundService(context, intent) }
                    .onFailure { Log.w(TAG, "couldn't start the drive foreground service", it) }
            } else {
                context.stopService(intent)
            }
        }
    }
}
