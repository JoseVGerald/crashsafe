package org.cac.crashsafe

import android.app.Application
import org.cac.crashsafe.app.AppEnvironment
import org.cac.crashsafe.services.alerts.CrashNotification
import org.cac.crashsafe.services.sensors.AppState
import org.osmdroid.config.Configuration

/**
 * Runs on every launch — including when Android starts a closed app in the background for an activity
 * transition or after a reboot, where no screen ever appears — so drive watching resumes on its own.
 */
class CrashSafeApplication : Application() {
    lateinit var environment: AppEnvironment
        private set

    override fun onCreate() {
        super.onCreate()
        AppState.context = this
        CrashNotification.createChannels(this)
        // OpenStreetMap's tile servers ask every app to identify itself.
        Configuration.getInstance().apply {
            userAgentValue = "$packageName/${BuildConfig.VERSION_NAME}"
            osmdroidBasePath = cacheDir.resolve("osmdroid")
            osmdroidTileCache = cacheDir.resolve("osmdroid/tiles")
        }
        environment = AppEnvironment.live(this)
    }
}
