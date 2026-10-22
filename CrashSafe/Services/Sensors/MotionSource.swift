import CoreMotion
import Foundation

@MainActor
protocol MotionSource: AnyObject {
    var isAvailable: Bool { get }
    func start(interval: TimeInterval, receive: @escaping @MainActor (MotionSample?, Bool) -> Void)
    func stop()
}

/// Copies framework objects into immutable values before crossing onto the main actor.
@MainActor
final class CoreMotionSource: MotionSource {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.cac.crashsafe.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var generation = UUID()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start(interval: TimeInterval, receive: @escaping @MainActor (MotionSample?, Bool) -> Void) {
        stop()
        let generation = generation
        let origin = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        manager.deviceMotionUpdateInterval = interval
        let deliver: @Sendable (MotionSample?, Bool) -> Void = { [weak self] sample, denied in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                receive(sample, denied)
            }
        }
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue,
                                         withHandler: Self.handler(origin: origin, deliver: deliver))
    }

    func stop() {
        generation = UUID()
        manager.stopDeviceMotionUpdates()
    }

    /// The closure Core Motion calls on its own queue, ~100 times a second. It is built here, outside the
    /// main actor, on purpose: a closure created inside this `@MainActor` class would inherit main-actor
    /// isolation, and Swift 6 traps the moment such a closure runs on Core Motion's queue (this crashed
    /// every real iPhone as soon as a drive started; simulators have no motion hardware to show it).
    nonisolated static func handler(origin: Date, deliver: @escaping @Sendable (MotionSample?, Bool) -> Void)
        -> CMDeviceMotionHandler {
        return { data, error in
            let nsError = error as NSError?
            let denied = nsError?.domain == CMErrorDomain &&
                (nsError?.code == Int(CMErrorMotionActivityNotAuthorized.rawValue) ||
                 nsError?.code == Int(CMErrorNotAuthorized.rawValue))
            let sample = data.map {
                MotionSample(uptime: $0.timestamp, date: origin.addingTimeInterval($0.timestamp),
                             accelerationG: SensorVector(x: $0.userAcceleration.x, y: $0.userAcceleration.y, z: $0.userAcceleration.z),
                             gravityG: SensorVector(x: $0.gravity.x, y: $0.gravity.y, z: $0.gravity.z),
                             rotationRate: SensorVector(x: $0.rotationRate.x, y: $0.rotationRate.y, z: $0.rotationRate.z))
            }
            deliver(sample, denied)
        }
    }
}
