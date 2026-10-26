package org.cac.crashsafe.core.crash

import org.cac.crashsafe.core.util.newID

/** A possible crash, as reported by a `CrashDetector`. */
data class CrashEvent(
    /** Wall clock, seconds since 1970. */
    val date: Double,
    /** Peak acceleration in g. */
    val peakG: Double,
    /** Drop in GPS speed around the impact, in mph; null when reliable GPS is missing. */
    val speedDropMPH: Double?,
    val isSimulated: Boolean,
    val assessment: CrashAssessment? = null,
    /** How hard the hit was and how fast the car stopped (from the rolling sensor history). */
    val impact: ImpactReport? = null,
    val id: String = newID(),
)
