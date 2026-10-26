package org.cac.crashsafe

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.core.app.ActivityCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import org.cac.crashsafe.app.PermissionRequester
import org.cac.crashsafe.model.CheckInOutcome
import org.cac.crashsafe.services.alerts.CrashNotification
import org.cac.crashsafe.ui.ActivityResults
import org.cac.crashsafe.ui.LocalActivityResults
import org.cac.crashsafe.ui.RootScreen
import androidx.compose.runtime.CompositionLocalProvider
import org.cac.crashsafe.ui.LocalEnvironment

class MainActivity : ComponentActivity(), PermissionRequester {
    private val env get() = (application as CrashSafeApplication).environment
    private var pendingPermissions: CompletableDeferred<Map<String, Boolean>>? = null
    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        pendingPermissions?.complete(result)
        pendingPermissions = null
    }
    private val results = ActivityResults(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        env.permissions.requester = this
        handle(intent)
        setContent {
            CompositionLocalProvider(LocalEnvironment provides env, LocalActivityResults provides results) {
                RootScreen()
                // The check-in shows over the lock screen and turns the screen on, like an alarm.
                LaunchedEffect(Unit) {
                    snapshotFlow { env.router.activeCrash != null }.collect { showOverLockScreen(it) }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onDestroy() {
        if (env.permissions.requester === this) env.permissions.requester = null
        super.onDestroy()
    }

    override fun onStop() {
        super.onStop()
        lifecycleScope.launch { env.store.flush() }
    }

    /** "I need help" from the lock-screen notification. */
    private fun handle(intent: Intent?) {
        val outcome = intent?.getStringExtra(CrashNotification.EXTRA_OUTCOME)?.let { runCatching { CheckInOutcome.valueOf(it) }.getOrNull() }
        if (outcome != null) env.crashCenter.respond(outcome)
        intent?.removeExtra(CrashNotification.EXTRA_OUTCOME)
    }

    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // PermissionRequester

    override suspend fun request(permissions: Array<String>): Map<String, Boolean> {
        val deferred = CompletableDeferred<Map<String, Boolean>>()
        pendingPermissions?.complete(emptyMap())
        pendingPermissions = deferred
        permissionLauncher.launch(permissions)
        return deferred.await()
    }

    override fun shouldShowRationale(permission: String): Boolean = ActivityCompat.shouldShowRequestPermissionRationale(this, permission)
}
