package org.cac.crashsafe.ui

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.cac.crashsafe.app.AppEnvironment
import org.cac.crashsafe.app.SessionStore
import org.cac.crashsafe.core.util.PhoneFormat
import org.cac.crashsafe.features.auth.AuthFlow
import org.cac.crashsafe.features.launch.SplashScreen
import org.cac.crashsafe.ui.theme.Brand
import org.cac.crashsafe.ui.theme.CrashSafeTheme
import java.io.File

val LocalEnvironment = staticCompositionLocalOf<AppEnvironment> { error("No AppEnvironment provided") }
val LocalActivityResults = staticCompositionLocalOf<ActivityResults?> { null }

/** Things only the activity can do: pick a contact. Registered when `MainActivity` is created. */
class ActivityResults(activity: ComponentActivity) {
    data class PickedContact(val name: String, val phone: String, val relationship: String = "")

    private val context: Context = activity
    private var pending: CompletableDeferred<Uri?>? = null
    private val launcher = activity.registerForActivityResult(object : ActivityResultContract<Unit, Uri?>() {
        override fun createIntent(context: Context, input: Unit) = Intent(Intent.ACTION_PICK, ContactsContract.CommonDataKinds.Phone.CONTENT_URI)
        override fun parseResult(resultCode: Int, intent: Intent?): Uri? = if (resultCode == Activity.RESULT_OK) intent?.data else null
    }) { uri ->
        pending?.complete(uri)
        pending = null
    }

    /**
     * Android's contact picker. It runs outside the app, so CrashSafe needs no Contacts permission and only sees
     * the one name and phone number the person picks.
     */
    suspend fun pickContact(): PickedContact? {
        val deferred = CompletableDeferred<Uri?>()
        pending?.complete(null)
        pending = deferred
        runCatching { launcher.launch(Unit) }.onFailure { return null }
        val uri = deferred.await() ?: return null
        return withContext(Dispatchers.IO) {
            runCatching {
                context.contentResolver.query(uri, arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER), null, null, null)?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    PickedContact(cursor.getString(0)?.trim() ?: "", PhoneFormat.display(cursor.getString(1) ?: ""))
                }
            }.getOrNull()
        }
    }
}

/** Opening other apps: the dialer, messages, maps, the share sheet, web links. */
object Actions {
    fun call(context: Context, number: String) {
        val digits = PhoneFormat.dialable(number)
        if (digits.isEmpty()) return
        start(context, Intent(Intent.ACTION_DIAL, Uri.parse("tel:$digits")))
    }

    fun message(context: Context, number: String) = start(context, Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${PhoneFormat.dialable(number)}")))

    fun open(context: Context, url: String) = start(context, Intent(Intent.ACTION_VIEW, Uri.parse(url)))

    /** Directions in the phone's maps app. */
    fun directions(context: Context, lat: Double, lon: Double, label: String) =
        start(context, Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=$lat,$lon(${Uri.encode(label)})")))

    fun mapSearch(context: Context, query: String) = start(context, Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=${Uri.encode(query)}")))

    fun shareText(context: Context, text: String, subject: String? = null) {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        subject?.let { send.putExtra(Intent.EXTRA_SUBJECT, it) }
        start(context, Intent.createChooser(send, null))
    }

    fun shareFile(context: Context, file: File, mimeType: String) {
        val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
        val send = Intent(Intent.ACTION_SEND).setType(mimeType).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        start(context, Intent.createChooser(send, null))
    }

    private fun start(context: Context, intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
        }
    }
}

/** Routes between splash, the signed-out flow and the signed-in app. */
@Composable
fun RootScreen() {
    val env = LocalEnvironment.current
    var resumed by remember { mutableStateOf(true) }
    CrashSafeTheme {
        Box(Modifier.fillMaxSize().background(Brand.background)) {
            Crossfade(targetState = env.session.phase, animationSpec = tween(350), label = "root") { phase ->
                when (phase) {
                    SessionStore.Phase.Launching -> SplashScreen()
                    SessionStore.Phase.SignedOut -> AuthFlow()
                    is SessionStore.Phase.SignedIn -> key(phase.user.id) { SignedInRoot(phase.user) } // fresh state per account
                }
            }
        }
    }

    LaunchedEffect(Unit) { env.session.restore() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    resumed = true
                    // Coming back from Settings (or the background): pick up permission changes right away.
                    env.location.refreshAuthorization()
                    env.sensors.refreshAfterForeground()
                    env.voice.reload()
                }
                Lifecycle.Event.ON_PAUSE -> resumed = false
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    // On screen: keep sensors running so Home can show what you're doing (walking, driving…).
    val userID = env.session.user?.id
    LaunchedEffect(userID, resumed) { env.intelligence.setActivitySensing(userID != null && resumed) }
    var previousUser by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(userID) {
        val previous = previousUser
        if (previous != null && previous != userID) {
            env.crashDetector.stopMonitoring()
            env.driving.stop()
            env.driveWatcher.disarm()
        }
        previousUser = userID
    }
}
