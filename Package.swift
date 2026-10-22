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
            "Sensors/SensorTypes.swift", "CrashDetection/CrashEvidence.swift", "CrashDetection/CrashPipeline.swift",
            "Sensors/SensorHistory.swift", "CrashDetection/ImpactAnalysis.swift",
            "Intelligence/TransportMode.swift", "Intelligence/HarshEvents.swift", "Intelligence/RoadMatching.swift",
            "Sensors/SensorLabMath.swift", "CrashDetection/CrashScenarios.swift"
        ]),
        // Virtual stress test: `Tools/StressLab/run.sh` (see docs/stress-test-report.md).
        .executableTarget(name: "StressLab", dependencies: ["CrashDetectionCore"], path: "Tools/StressLab",
                          exclude: ["fetch_datasets.py", "run.sh", "routes"]),
        .testTarget(name: "CrashDetectionCoreTests", dependencies: ["CrashDetectionCore"], path: "CoreTests",
                    exclude: ["Fixtures/README.md"], resources: [.copy("Fixtures")])
    ]
)
