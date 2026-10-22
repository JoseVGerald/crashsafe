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
    /// Readings received while off screen or locked (see `BackgroundSensorLog`).
    private(set) var backgroundLog = BackgroundSensorLog()
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
    @ObservationIgnored private let appState: () -> (background: Bool, locked: Bool)
    @ObservationIgnored private var lastLogSave: TimeInterval = 0
    @ObservationIgnored private var persistsBackgroundLog = false

    init(motion: any MotionSource = CoreMotionSource(), location: any LocationSampleSource,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         useWatchdog: Bool = true,
         persistsBackgroundLog: Bool = false,
         appState: @escaping () -> (background: Bool, locked: Bool) = { AppState.current() }) {
        self.motion = motion
        self.location = location
        self.now = now
        self.useWatchdog = useWatchdog
        self.appState = appState
        self.persistsBackgroundLog = persistsBackgroundLog
        if persistsBackgroundLog, let saved = BackgroundSensorLog.load() { backgroundLog = saved }
    }

    func resetBackgroundLog() {
        backgroundLog = BackgroundSensorLog()
        if persistsBackgroundLog { backgroundLog.save() }
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
        if motion.isAvailable { startMotion() }
        if useWatchdog {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.checkFreshness()
                }
            }
        }
    }

    /// Call when the app returns to the foreground (for example, from Settings): a stream that was
    /// denied, interrupted or stale is started again, so newly granted Motion access takes effect
    /// without restarting the drive.
    func refreshAfterForeground() {
        guard isRunning else { return }
        location.start()
        switch health.state {
        case .permissionDenied, .interrupted, .stale, .unavailable:
            guard motion.isAvailable else {
                health.state = .unavailable
                return
            }
            motion.stop()
            lastMotion = nil
            rateStart = nil
            rateCount = 0
            startedAt = now()
            health.state = .starting
            startMotion()
        case .starting, .active, .stopped:
            break
        }
    }

    /// The motion source started or stopped delivering on its own (a replayed clip began or ended).
    /// Starts motion if it can now, or marks it unavailable instead of letting it go stale.
    func motionSourceChanged() {
        guard isRunning else { return }
        if motion.isAvailable {
            guard health.state != .active && health.state != .starting else { return }
            motion.stop()
            lastMotion = nil
            rateStart = nil
            rateCount = 0
            startedAt = now()
            health.state = .starting
            startMotion()
        } else {
            motion.stop()
            health.state = .unavailable
            health.measuredHz = 0
        }
    }

    private func startMotion() {
        motion.start(interval: 1 / health.requestedHz) { [weak self] sample, denied in
            guard let self, self.isRunning else { return }
            guard let sample else {
                self.health.state = denied ? .permissionDenied : .interrupted
                return
            }
            self.receive(sample)
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

    private func noteOffScreen(motion: Bool, gap: Double?) {
        let state = appState()
        guard state.background || state.locked else { return }
        let firstOffScreen = backgroundLog.isEmpty
        backgroundLog.record(motion: motion, uptimeGap: gap, background: state.background, locked: state.locked, at: .now)
        if firstOffScreen {
            BackgroundSensorLog.logger.info("Off-screen sensor readings started (locked: \(state.locked))")
        }
        // Persist about every 5 s so the count survives the app being closed.
        if persistsBackgroundLog, now() - lastLogSave > 5 {
            lastLogSave = now()
            backgroundLog.save()
            BackgroundSensorLog.logger.info(
                "Off screen: \(self.backgroundLog.backgroundMotion) motion, \(self.backgroundLog.backgroundLocation) GPS; locked: \(self.backgroundLog.lockedMotion) motion, \(self.backgroundLog.lockedLocation) GPS")
        }
    }

    private func receive(_ sample: MotionSample) {
        guard isRunning else { return }
        guard sample.isValid, sample.uptime <= now() + 0.05, now() - sample.uptime <= 0.5,
              lastMotion.map({ sample.uptime > $0 }) ?? true else {
            health.rejectedMotionSamples += 1
            return
        }
        if let lastMotion, sample.uptime - lastMotion > 0.15 { health.motionGaps += 1 }
        noteOffScreen(motion: true, gap: lastMotion.map { sample.uptime - $0 })
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
        noteOffScreen(motion: false, gap: nil)
        health.locationUnavailable = !sample.hasReliableSpeed(at: now(), maximumAge: 5)
        for receive in Array(observers.values) { receive(.location(sample)) }
    }
}
