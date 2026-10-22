import Foundation

/// Wraps the real motion sensor and can play a clip in its place, on the live clock: a recording from
/// the Sensor Lab, a real crash-test pulse, or a generated event. The simulator has no motion sensor,
/// so this is how motion reaches the app there; on a phone it replays a crash without crashing.
/// Everything downstream (SensorHub, the crash pipeline, motion analysis) sees ordinary samples.
@MainActor
final class ReplayMotionSource: MotionSource {
    nonisolated struct Clip: Sendable {
        var title: String
        /// Seconds from the start of the clip.
        var samples: [(t: TimeInterval, sample: MotionSample)]

        init(title: String, readings: [SensorReading]) {
            self.title = title
            let motion = readings.compactMap { reading -> MotionSample? in
                if case .motion(let m) = reading { return m }
                return nil
            }
            let origin = motion.first?.uptime ?? 0
            samples = motion.map { ($0.uptime - origin, $0) }
        }

        var duration: TimeInterval { samples.last?.t ?? 0 }
    }

    private let live: any MotionSource
    private var receive: (@MainActor (MotionSample?, Bool) -> Void)?
    private var interval: TimeInterval = 0.01
    private var playback: Task<Void, Never>?
    private var isRestarting = false
    private(set) var current: Clip?
    /// Called when a clip ends or is stopped (so the hub can notice the real sensor is back, or absent).
    var onFinish: (() -> Void)?

    init(live: any MotionSource = CoreMotionSource()) {
        self.live = live
    }

    var isAvailable: Bool { live.isAvailable || current != nil }
    var hasHardware: Bool { live.isAvailable }
    var isReplaying: Bool { current != nil }

    func start(interval: TimeInterval, receive: @escaping @MainActor (MotionSample?, Bool) -> Void) {
        self.interval = interval
        self.receive = receive
        if current == nil, live.isAvailable { live.start(interval: interval, receive: receive) }
    }

    func stop() {
        receive = nil
        live.stop()
        // The hub stops motion before starting it again; that mustn't end the clip it's starting for.
        guard !isRestarting else { return }
        playback?.cancel()
        playback = nil
        current = nil
    }

    /// Plays `clip` in real time. Live readings pause meanwhile and resume after.
    /// - Parameter restart: asks the sensor hub to (re)start motion, needed where there's no hardware.
    func play(_ clip: Clip, loop: Bool = false, restart: () -> Void) {
        playback?.cancel()
        live.stop()
        current = clip
        isRestarting = true
        restart()
        isRestarting = false
        playback = Task { [weak self] in
            repeat {
                guard let self else { return }
                let start = ProcessInfo.processInfo.systemUptime
                let origin = Date.now
                var index = 0
                while index < clip.samples.count {
                    if Task.isCancelled { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    while index < clip.samples.count, clip.samples[index].t <= elapsed {
                        var sample = clip.samples[index].sample
                        sample.uptime = start + clip.samples[index].t
                        sample.date = origin.addingTimeInterval(clip.samples[index].t)
                        self.receive?(sample, false)
                        index += 1
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } while loop && !Task.isCancelled
            self?.finish()
        }
    }

    func stopReplay() {
        guard current != nil else { return }
        playback?.cancel()
        playback = nil
        finish()
    }

    private func finish() {
        current = nil
        playback = nil
        if let receive, live.isAvailable { live.start(interval: interval, receive: receive) }
        onFinish?()
    }
}
