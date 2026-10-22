import Foundation
import Observation

@MainActor
protocol LocationSampleSource: AnyObject {
    var isDenied: Bool { get }
    func addSampleObserver(_ receive: @escaping (LocationSample) -> Void) -> UUID
    func removeSampleObserver(_ id: UUID)
    func start()
    func setBackgroundUpdates(_ enabled: Bool)
}

/// A single acquisition session with independent consumers and reference-counted leases.
/// No raw readings are saved to disk or uploaded.
@MainActor
@Observable
final class SensorHub {
    private(set) var health = SensorHealth()
    var isRunning: Bool { !owners.isEmpty }
    var hasMotionHardware: Bool { motion.isAvailable }

    @ObservationIgnored private let motion: any MotionSource
    @ObservationIgnored private let location: any LocationSampleSource
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let useWatchdog: Bool
    @ObservationIgnored private var owners: [UUID: Bool] = [:]
    @ObservationIgnored private var observers: [UUID: (SensorReading) -> Void] = [:]
    @ObservationIgnored private var locationObserver: UUID?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastMotion: TimeInterval?
    @ObservationIgnored private var lastLocation: TimeInterval?
    @ObservationIgnored private var latestLocation: LocationSample?
    @ObservationIgnored private var rateStart: TimeInterval?
    @ObservationIgnored private var rateCount = 0
    @ObservationIgnored private var startedAt: TimeInterval = 0

    init(motion: any MotionSource = CoreMotionSource(), location: any LocationSampleSource,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         useWatchdog: Bool = true) {
        self.motion = motion
        self.location = location
        self.now = now
        self.useWatchdog = useWatchdog
    }

    func addObserver(_ receive: @escaping (SensorReading) -> Void) -> UUID {
        let id = UUID()
        observers[id] = receive
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func acquire(owner: UUID, background: Bool) {
        let wasRunning = isRunning
        owners[owner] = background
        location.setBackgroundUpdates(owners.values.contains(true))
        guard !wasRunning else { return }
        health = SensorHealth(state: motion.isAvailable ? .starting : .unavailable,
                              locationUnavailable: true)
        lastMotion = nil
        lastLocation = nil
        latestLocation = nil
        rateStart = nil
        rateCount = 0
        startedAt = now()
        locationObserver = location.addSampleObserver { [weak self] in self?.receive($0) }
        location.start()
        if motion.isAvailable {
            motion.start(interval: 1 / health.requestedHz) { [weak self] sample, denied in
                guard let self, self.isRunning else { return }
                guard let sample else {
                    self.health.state = denied ? .permissionDenied : .interrupted
                    return
                }
                self.receive(sample)
            }
        }
        if useWatchdog {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.checkFreshness()
                }
            }
        }
    }

    func release(owner: UUID) {
        guard owners.removeValue(forKey: owner) != nil else { return }
        location.setBackgroundUpdates(owners.values.contains(true))
        guard !isRunning else { return }
        motion.stop()
        if let locationObserver { location.removeSampleObserver(locationObserver) }
        locationObserver = nil
        watchdog?.cancel()
        watchdog = nil
        health.state = .stopped
        // LocationService also serves maps/weather; releasing motion must not stop those consumers.
    }

    func checkFreshness() {
        guard isRunning else { return }
        health.locationUnavailable = location.isDenied || !(latestLocation?.hasReliableSpeed(at: now(), maximumAge: 5) ?? false)
        guard health.state == .active || health.state == .starting else { return }
        if now() - (lastMotion ?? startedAt) > 0.5 { health.state = .stale }
    }

    private func receive(_ sample: MotionSample) {
        guard isRunning else { return }
        guard sample.isValid, sample.uptime <= now() + 0.05, now() - sample.uptime <= 0.5,
              lastMotion.map({ sample.uptime > $0 }) ?? true else {
            health.rejectedMotionSamples += 1
            return
        }
        if let lastMotion, sample.uptime - lastMotion > 0.15 { health.motionGaps += 1 }
        lastMotion = sample.uptime
        rateCount += 1
        if let rateStart, sample.uptime - rateStart >= 1 {
            health.measuredHz = Double(rateCount - 1) / (sample.uptime - rateStart)
            self.rateStart = sample.uptime
            rateCount = 1
        } else if rateStart == nil { rateStart = sample.uptime }
        health.state = .active
        for receive in Array(observers.values) { receive(.motion(sample)) }
    }

    private func receive(_ sample: LocationSample) {
        guard isRunning else { return }
        guard sample.isValid, sample.uptime <= now() + 0.05, now() - sample.uptime <= 5,
              lastLocation.map({ sample.uptime > $0 }) ?? true else {
            health.rejectedLocationSamples += 1
            return
        }
        lastLocation = sample.uptime
        latestLocation = sample
        health.locationUnavailable = !sample.hasReliableSpeed(at: now(), maximumAge: 5)
        for receive in Array(observers.values) { receive(.location(sample)) }
    }
}
