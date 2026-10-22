// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CrashDetectionCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CrashDetectionCore", targets: ["CrashDetectionCore"])],
    targets: [
        .target(name: "CrashDetectionCore", path: "CrashSafe/Services", exclude: [
            "Alerts", "Assistant", "Auth", "Connectivity", "Driving", "Location", "TripPack", "Weather",
            "Sensors/MotionSource.swift", "Sensors/SensorHub.swift", "CrashDetection/CrashDetector.swift"
        ], sources: [
            "Sensors/SensorTypes.swift", "CrashDetection/CrashEvidence.swift", "CrashDetection/CrashPipeline.swift"
        ]),
        .testTarget(name: "CrashDetectionCoreTests", dependencies: ["CrashDetectionCore"], path: "CoreTests")
    ]
)
