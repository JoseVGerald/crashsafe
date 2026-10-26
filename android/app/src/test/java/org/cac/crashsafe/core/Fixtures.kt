package org.cac.crashsafe.core

import org.cac.crashsafe.core.sensors.LocationSample
import org.cac.crashsafe.core.sensors.MotionSample
import org.cac.crashsafe.core.sensors.SensorHistory
import org.cac.crashsafe.core.sensors.SensorReading
import org.cac.crashsafe.core.sensors.SensorVector
import java.io.File

object Fixtures {
    fun text(name: String): String {
        val url = Fixtures::class.java.classLoader!!.getResource("fixtures/$name") ?: error("missing fixture $name")
        return url.readText()
    }

    /** The app's bundled assets (src/main/assets), read the way unit tests can. */
    fun asset(path: String): String {
        val candidates = listOf(File("src/main/assets/$path"), File("app/src/main/assets/$path"))
        return candidates.first { it.exists() }.readText()
    }
}

/** Synthetic signals with known physics, so each number can be checked by hand. */
object Synthetic {
    fun motion(uptime: Double, a: SensorVector, rotation: SensorVector = SensorVector.zero): SensorReading =
        SensorReading.Motion(MotionSample(uptime = uptime, date = uptime, accelerationG = a,
            gravityG = SensorVector(0.0, 0.0, -1.0), rotationRate = rotation))

    fun fix(uptime: Double, speed: Double, lat: Double = 45.5, lon: Double = -122.6): SensorReading =
        SensorReading.Location(LocationSample(uptime = uptime, date = uptime, latitude = lat, longitude = lon,
            horizontalAccuracy = 5.0, speedMPS = speed, speedAccuracy = 0.5))

    /** 100 Hz motion from `start` for `seconds`, with 1 Hz GPS moving north at `speed` m/s. */
    fun history(seconds: Double, start: Double = 100.0, speed: (Double) -> Double,
                rotation: (Double) -> SensorVector = { SensorVector.zero }, accel: (Double) -> SensorVector): SensorHistory {
        val h = SensorHistory()
        var lat = 45.5
        for (i in 0 until (seconds * 100).toInt()) {
            val t = start + i / 100.0
            h.append(motion(t, accel(t), rotation(t)))
            if (i % 100 == 0) {
                h.append(fix(t, speed(t), lat))
                lat += speed(t) / 111_320
            }
        }
        return h
    }
}
