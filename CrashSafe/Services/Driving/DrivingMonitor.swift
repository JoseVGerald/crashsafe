import CoreLocation
import CoreMotion
import Foundation
import Observation

enum RoadEnvironment: String, Sendable {
    case city, highway, forest

    var label: String {
        switch self {
        case .city: "city street"
        case .highway: "highway"
        case .forest: "wooded rural road"
        }
    }

    var hazard: String {
        switch self {
        case .city: "pedestrians, cyclists and sudden stops"
        case .highway: "spray, hydroplaning and fast-closing traffic"
        case .forest: "deer, blind curves and no streetlights"
        }
    }
}

/// Scripted drives so the full experience can be shown in the simulator or a parked car.
enum DriveScenario: String, CaseIterable, Identifiable, Sendable {
    case forestNight, cityRushHour, highwayRain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forestNight: "Forest road at night"
        case .cityRushHour: "City rush hour"
        case .highwayRain: "Highway in the rain"
        }
    }

    var systemImage: String {
        switch self {
        case .forestNight: "tree.fill"
        case .cityRushHour: "building.2.fill"
        case .highwayRain: "road.lanes"
        }
    }

    var environment: RoadEnvironment {
        switch self {
        case .forestNight: .forest
        case .cityRushHour: .city
        case .highwayRain: .highway
        }
    }

    var speedLimit: Double {
        switch self {
        case .forestNight: 50
        case .cityRushHour: 30
        case .highwayRain: 65
        }
    }

    /// The (slightly too fast) speed the demo driver drifts toward.
    var cruiseSpeed: Double {
        switch self {
        case .forestNight: 58
        case .cityRushHour: 34
        case .highwayRain: 71
        }
    }

    var isNight: Bool { self == .forestNight }

    var weather: WeatherSnapshot {
        switch self {
        case .forestNight:
            WeatherSnapshot(temperatureF: 41, condition: .drizzle, windMph: 6, visibilityMiles: 3, isDay: false)
        case .cityRushHour:
            WeatherSnapshot(temperatureF: 63, condition: .partlyCloudy, windMph: 8, visibilityMiles: 10, isDay: true)
        case .highwayRain:
            WeatherSnapshot(temperatureF: 52, condition: .heavyRain, windMph: 17, visibilityMiles: 1.5, isDay: true)
        }
    }
}

struct DrivingSnapshot: Equatable, Sendable {
    var speedMPH: Double = 0
    var speedLimitMPH: Double?
    var averageSpeedMPH: Double = 0
    var maxSpeedMPH: Double = 0
    var hardBrakes = 0
    var hardAccelerations = 0
    var peakG: Double = 0
    var currentG: Double = 0
    var environment: RoadEnvironment = .city
    var elapsed: TimeInterval = 0

    var isMoving: Bool { speedMPH > 3 }
}

/// Watches speed (GPS) and forces (accelerometer) while driving.
///
/// `live` uses real sensors and can keep running in the background during a drive.
/// `demo` plays a scripted `DriveScenario` — the simulator has no accelerometer or real motion.
@Observable
final class DrivingMonitor {
    enum Mode: Equatable {
        case idle
        case live
        case demo(DriveScenario)
    }

    private(set) var mode: Mode = .idle
    private(set) var snapshot = DrivingSnapshot()
    /// Recent g-force readings for the live sparkline.
    private(set) var gHistory: [Double] = Array(repeating: 0, count: 40)

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var lastSpeed: (mph: Double, at: Date)?
    @ObservationIgnored private var speedSamples: [Double] = []
    @ObservationIgnored private var startedAt: Date?

    init(location: LocationService) {
        self.location = location
    }

    var isActive: Bool { mode != .idle }

    var scenario: DriveScenario? {
        if case .demo(let scenario) = mode { scenario } else { nil }
    }

    var hasAccelerometer: Bool { motion.isDeviceMotionAvailable }

    // MARK: Control

    func startLive(background: Bool) {
        stop()
        reset(environment: .city, limit: nil)
        mode = .live
        location.onUpdate = { [weak self] update in self?.ingest(update) }
        location.setBackgroundUpdates(background)
        location.start()
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 20
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let a = data.userAcceleration
                self?.ingest(g: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
            }
        }
    }

    func startDemo(_ scenario: DriveScenario) {
        stop()
        reset(environment: scenario.environment, limit: scenario.speedLimit)
        mode = .demo(scenario)
        demoTask = Task { [weak self] in
            var speed = scenario.cruiseSpeed * 0.4
            var tick = 0
            while !Task.isCancelled, let self {
                tick += 1
                // Ease toward cruise speed with a little noise, with a hard brake every ~12 s.
                let brake = tick % 24 == 0
                speed += brake ? -14 : (scenario.cruiseSpeed - speed) * 0.12 + Double.random(in: -1.2...1.2)
                speed = max(0, speed)
                self.ingest(speedMPH: speed, at: .now)
                self.ingest(g: brake ? Double.random(in: 0.42...0.55) : Double.random(in: 0.02...0.12))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        demoTask?.cancel()
        demoTask = nil
        if mode == .live {
            location.onUpdate = nil
            location.setBackgroundUpdates(false)
            motion.stopDeviceMotionUpdates()
        }
        mode = .idle
    }

    // MARK: Ingest

    private func reset(environment: RoadEnvironment, limit: Double?) {
        snapshot = DrivingSnapshot(speedLimitMPH: limit, environment: environment)
        gHistory = Array(repeating: 0, count: gHistory.count)
        speedSamples = []
        lastSpeed = nil
        startedAt = .now
    }

    private func ingest(_ update: CLLocation) {
        guard update.speed >= 0 else { return }
        ingest(speedMPH: update.speed * 2.23694, at: update.timestamp)
    }

    private func ingest(speedMPH: Double, at date: Date) {
        if let last = lastSpeed {
            let dt = date.timeIntervalSince(last.at)
            if dt > 0 {
                let mphPerSecond = (speedMPH - last.mph) / dt
                // ≈ 0.3 g of braking or acceleration.
                if mphPerSecond < -6.5 { snapshot.hardBrakes += 1 }
                if mphPerSecond > 6.5 { snapshot.hardAccelerations += 1 }
            }
        }
        lastSpeed = (speedMPH, date)
        speedSamples.append(speedMPH)
        snapshot.speedMPH = speedMPH
        snapshot.maxSpeedMPH = max(snapshot.maxSpeedMPH, speedMPH)
        let moving = speedSamples.filter { $0 > 3 }
        snapshot.averageSpeedMPH = moving.isEmpty ? 0 : moving.reduce(0, +) / Double(moving.count)
        snapshot.elapsed = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
    }

    private func ingest(g: Double) {
        snapshot.currentG = g
        snapshot.peakG = max(snapshot.peakG, g)
        gHistory.removeFirst()
        gHistory.append(g)
    }
}
