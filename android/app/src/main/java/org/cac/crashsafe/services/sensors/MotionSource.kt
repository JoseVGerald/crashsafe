package org.cac.crashsafe.services.sensors

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorVector
import kotlin.math.abs

interface MotionSource {
    val isAvailable: Boolean

    /** Delivers samples (or null plus "denied") on the main thread. */
    fun start(interval: Double, receive: (MotionSample?, Boolean) -> Unit)
    fun stop()
}

/**
 * The phone's motion sensors in Core Motion's conventions, so everything downstream (and the backend) reads the
 * same numbers on Android and iOS: user acceleration and gravity in g with gravity pointing down (flat, face up:
 * (0, 0, −1)), rotation in rad/s, in the device frame (x right, y top, z out of the screen — the same on both).
 *
 * Android's linear acceleration and gravity sensors point the other way (they report the reaction to gravity,
 * +9.81 m/s² up when flat), so both are negated and divided by g. A sample is emitted per linear-acceleration
 * event with the latest gravity and gyroscope readings, timestamped on the sensor's clock (elapsed realtime).
 */
class AndroidMotionSource(context: Context) : MotionSource {
    private val manager = context.getSystemService(SensorManager::class.java)
    private val linear = manager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
    private val gravity = manager?.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val gyro = manager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val main = Handler(Looper.getMainLooper())
    private var listener: SensorEventListener? = null

    override val isAvailable: Boolean get() = linear != null && gravity != null

    override fun start(interval: Double, receive: (MotionSample?, Boolean) -> Unit) {
        stop()
        val manager = manager ?: return
        if (!isAvailable) return
        var lastGravity = SensorVector(0.0, 0.0, -1.0)
        var lastRotation = SensorVector.zero
        // Seconds to add to a sensor timestamp to put it on the elapsed-realtime clock (0 on nearly every device).
        var clockOffset: Double? = null
        val wallOrigin = System.currentTimeMillis() / 1000.0 - SystemClock.elapsedRealtimeNanos() / 1e9
        val created = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val v = event.values
                when (event.sensor.type) {
                    Sensor.TYPE_GRAVITY -> lastGravity = SensorVector(-v[0] / G, -v[1] / G, -v[2] / G)
                    Sensor.TYPE_GYROSCOPE -> lastRotation = SensorVector(v[0].toDouble(), v[1].toDouble(), v[2].toDouble())
                    Sensor.TYPE_LINEAR_ACCELERATION -> {
                        val stamp = event.timestamp / 1e9
                        val offset = clockOffset ?: run {
                            val now = SystemClock.elapsedRealtimeNanos() / 1e9
                            (if (abs(now - stamp) > 0.5) now - stamp else 0.0).also { clockOffset = it }
                        }
                        val uptime = stamp + offset
                        receive(MotionSample(uptime = uptime, date = wallOrigin + uptime,
                            accelerationG = SensorVector(-v[0] / G, -v[1] / G, -v[2] / G),
                            gravityG = lastGravity, rotationRate = lastRotation), false)
                    }
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        listener = created
        val micros = (interval * 1_000_000).toInt()
        manager.registerListener(created, gravity, micros, main)
        gyro?.let { manager.registerListener(created, it, micros, main) }
        manager.registerListener(created, linear, micros, main)
    }

    override fun stop() {
        listener?.let { manager?.unregisterListener(it) }
        listener = null
    }

    private companion object {
        const val G = SensorVector.standardGravity
    }
}
