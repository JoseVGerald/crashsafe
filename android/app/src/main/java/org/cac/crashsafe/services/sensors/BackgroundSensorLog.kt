package org.cac.crashsafe.services.sensors

import android.app.KeyguardManager
import android.content.Context
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.cac.crashsafe.core.util.nowSeconds
import java.io.File

/** Whether the app is off screen and whether the phone is locked, read live on each reading. */
object AppState {
    data class Snapshot(val background: Boolean, val locked: Boolean)

    var context: Context? = null

    fun current(): Snapshot {
        val foreground = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        val locked = context?.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked ?: false
        return Snapshot(background = !foreground, locked = locked)
    }
}

/**
 * Proof that sensors keep running off screen: readings received while the app was in the background
 * and while the phone was locked, with the longest motion gap. Counts only — no readings are stored.
 */
@Serializable
data class BackgroundSensorLog(
    val since: Double = nowSeconds(),
    val backgroundMotion: Int = 0,
    val backgroundLocation: Int = 0,
    val lockedMotion: Int = 0,
    val lockedLocation: Int = 0,
    /** Longest gap between motion readings while off screen, in seconds. */
    val longestBackgroundGap: Double = 0.0,
    val lastBackgroundReading: Double? = null,
) {
    val isEmpty: Boolean get() = backgroundMotion == 0 && backgroundLocation == 0

    fun recording(motion: Boolean, uptimeGap: Double?, background: Boolean, locked: Boolean, at: Double): BackgroundSensorLog {
        if (!background && !locked) return this
        return if (motion) {
            copy(backgroundMotion = backgroundMotion + 1, lockedMotion = lockedMotion + if (locked) 1 else 0,
                longestBackgroundGap = uptimeGap?.let { maxOf(longestBackgroundGap, it) } ?: longestBackgroundGap,
                lastBackgroundReading = at)
        } else {
            copy(backgroundLocation = backgroundLocation + 1, lockedLocation = lockedLocation + if (locked) 1 else 0,
                lastBackgroundReading = at)
        }
    }

    /** Written next to the app's data so a developer can pull it off a test phone (`adb shell run-as`). */
    class Store(private val file: File) {
        fun load(): BackgroundSensorLog? = runCatching { Json.decodeFromString(serializer(), file.readText()) }.getOrNull()

        fun save(log: BackgroundSensorLog) {
            runCatching {
                val temp = File(file.parentFile, file.name + ".tmp")
                temp.writeText(Json.encodeToString(serializer(), log))
                temp.renameTo(file)
            }
        }
    }

    companion object {
        const val TAG = "CrashSafe.bgsensors"
    }
}
