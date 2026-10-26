package org.cac.crashsafe.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** Shows the system permission dialogs. `MainActivity` installs one; without a screen, requests just fail. */
interface PermissionRequester {
    suspend fun request(permissions: Array<String>): Map<String, Boolean>
    fun shouldShowRationale(permission: String): Boolean
}

/**
 * Location, physical activity (iOS's Motion & Fitness), notification and microphone permission state, re-read
 * whenever the app becomes active, so a change made in Settings shows up (and takes effect) as soon as the
 * user comes back. Android only says a permission is "denied for good" indirectly, after a request, so that
 * is remembered here; a denied-for-good request opens the app's Settings page instead, as iOS does.
 */
class PermissionCenter(private val context: Context, private val prefs: SharedPreferences) {
    var requester: PermissionRequester? = null

    /** Bumped on every refresh so screens that show permission state redraw. */
    var version by mutableIntStateOf(0)
        private set

    private fun has(permission: String): Boolean {
        @Suppress("UNUSED_EXPRESSION") version
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    val locationGranted: Boolean
        get() = has(Manifest.permission.ACCESS_FINE_LOCATION) || has(Manifest.permission.ACCESS_COARSE_LOCATION)
    val backgroundLocationGranted: Boolean
        get() = locationGranted && (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || has(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
    val locationDenied: Boolean get() = !locationGranted && deniedForGood(Manifest.permission.ACCESS_FINE_LOCATION)
    /** Android shows the "Allow all the time" choice once from the app; after that it lives in Settings. */
    val canPromptForBackground: Boolean
        get() = locationGranted && !backgroundLocationGranted && !deniedForGood(Manifest.permission.ACCESS_BACKGROUND_LOCATION)

    val motionGranted: Boolean
        get() = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || has(Manifest.permission.ACTIVITY_RECOGNITION)
    val motionDenied: Boolean get() = !motionGranted && deniedForGood(Manifest.permission.ACTIVITY_RECOGNITION)

    val notificationsGranted: Boolean
        get() {
            @Suppress("UNUSED_EXPRESSION") version
            return NotificationManagerCompat.from(context).areNotificationsEnabled() &&
                (Build.VERSION.SDK_INT < 33 || has(Manifest.permission.POST_NOTIFICATIONS))
        }
    val notificationsDenied: Boolean
        get() = !notificationsGranted && (Build.VERSION.SDK_INT < 33 || deniedForGood(Manifest.permission.POST_NOTIFICATIONS))

    val microphoneGranted: Boolean get() = has(Manifest.permission.RECORD_AUDIO)
    val microphoneDenied: Boolean get() = !microphoneGranted && deniedForGood(Manifest.permission.RECORD_AUDIO)

    fun refresh() {
        version++
    }

    suspend fun requestLocation(): Boolean =
        request(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION, primary = Manifest.permission.ACCESS_FINE_LOCATION)

    /** Asks for "Allow all the time". Returns false when no prompt can be shown (the caller opens Settings). */
    suspend fun requestBackgroundLocation(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return locationGranted
        if (!locationGranted && !requestLocation()) return false
        if (!canPromptForBackground) return backgroundLocationGranted
        return request(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    }

    suspend fun requestMotion(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return request(Manifest.permission.ACTIVITY_RECOGNITION)
    }

    suspend fun requestNotifications(): Boolean {
        if (Build.VERSION.SDK_INT < 33) {
            if (!notificationsGranted) openNotificationSettings()
            return notificationsGranted
        }
        if (notificationsGranted) return true
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled() && has(Manifest.permission.POST_NOTIFICATIONS)) {
            openNotificationSettings()
            return false
        }
        return request(Manifest.permission.POST_NOTIFICATIONS)
    }

    suspend fun requestMicrophone(): Boolean = request(Manifest.permission.RECORD_AUDIO)

    /** Asks for `permissions` (all granted counts as yes). Denied for good: opens Settings and returns false. */
    private suspend fun request(vararg permissions: String, primary: String = permissions.first()): Boolean {
        if (has(primary)) return true
        if (deniedForGood(primary)) {
            openSettings()
            return false
        }
        val requester = requester ?: return false
        val result = requester.request(arrayOf(*permissions))
        val granted = result[primary] == true || has(primary)
        if (!granted && !requester.shouldShowRationale(primary)) {
            prefs.edit().putBoolean(key(primary), true).apply()
        }
        refresh()
        return granted
    }

    private fun deniedForGood(permission: String): Boolean = prefs.getBoolean(key(permission), false) && !has(permission)

    private fun key(permission: String) = "permission.deniedForGood.$permission"

    fun openSettings() {
        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun openNotificationSettings() {
        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
