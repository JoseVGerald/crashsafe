// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CrashDetectionCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CrashDetectionCore", targets: ["CrashDetectionCore"])],
    targets: [
        .target(name: "CrashDetectionCore", path: "CrashSafe/Services", sources: ["Sensors/SensorTypes.swift"]),
        .testTarget(name: "CrashDetectionCoreTests", dependencies: ["CrashDetectionCore"], path: "CoreTests")
    ]
)
