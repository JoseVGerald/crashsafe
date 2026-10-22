import Foundation

/// A real crash: NHTSA test 7605, 35 MPH NCAP FRONTAL - 2012 TOYOTA YARIS LE 5-DOOR HATCHBACK (56.09 km/h into a rigid barrier).
/// The left rear sill accelerometer, converted to g and averaged into 100 Hz samples (car frame:
/// x forward, y right, z down). Public domain, NHTSA Vehicle Crash Test Database.
/// Regenerate with `Tools/StressLab/fetch_datasets.py`.
nonisolated enum RealCrashPulse {
    static let title = "Real crash · 2012 Toyota Yaris, 35 mph into a barrier (NHTSA 7605)"
    static let x: [Double] = [0.001, -0.030, -6.766, -11.041, -18.725, -44.247, -42.879, -47.356, -11.629, -5.057, 2.658, 1.984, -0.151, -1.289, 0.881, -0.865, -1.559, -0.226, 0.007, -0.032, -0.774, 0.302, 0.667, -0.270, -0.006, 0.437, 0.431, -0.057, 0.053, 0.458, 0.117, -0.263]
    static let y: [Double] = [0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000]
    static let z: [Double] = [0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000, 0.000]
}
