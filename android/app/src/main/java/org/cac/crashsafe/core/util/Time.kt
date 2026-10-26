package org.cac.crashsafe.core.util

import java.util.UUID

/** Wall clock, seconds since 1970 (Swift's `Date.now.timeIntervalSince1970`). */
fun nowSeconds(): Double = System.currentTimeMillis() / 1000.0

fun newID(): String = UUID.randomUUID().toString()

/** Swift's `Double.rounded()`: to nearest, ties away from zero. */
fun Double.roundedHalfAway(): Double = if (this >= 0) kotlin.math.floor(this + 0.5) else -kotlin.math.floor(-this + 0.5)

/** `Int(x.rounded())`. */
fun Double.roundToIntHalfAway(): Int = roundedHalfAway().toInt()
