import AVFoundation
import CoreMotion
import Foundation
import Observation

/// Turns live driving data into spoken coaching, independent of which screen is open.
/// With the `location` + `audio` background modes it keeps working with the phone locked.
@Observable
final class DriveCoach {
    private(set) var message: CoachingMessage?
    private(set) var messageID = 0
    var speaks = true {
        didSet { if !speaks { synthesizer.stopSpeaking(at: .immediate) } }
    }

    /// Supplies the driver profile inputs each time the coach evaluates.
    @ObservationIgnored var profileProvider: () -> (style: CoachingStyle, experience: DrivingExperience, lovedOne: String?) = {
        (.logical, .newDriver, nil)
    }
    @ObservationIgnored private let driving: DrivingMonitor
    @ObservationIgnored private let conditions: ConditionsStore
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSpoken: (title: String, at: Date)?

    init(driving: DrivingMonitor, conditions: ConditionsStore) {
        self.driving = driving
        self.conditions = conditions
    }

    var isNight: Bool { driving.scenario?.isNight ?? conditions.isNight }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.evaluate()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func evaluate() {
        guard driving.isActive, driving.snapshot.isMoving else { return }
        let profile = profileProvider()
        let next = CoachingEngine.message(for: CoachingEngine.Input(
            snapshot: driving.snapshot,
            advice: DrivingAdvice.make(weather: conditions.weather, isNight: isNight),
            weather: conditions.weather,
            isNight: isNight,
            style: profile.style,
            experience: profile.experience,
            lovedOne: profile.lovedOne
        ))
        guard next != message else { return }
        let isNewAdvice = next.title != message?.title
        message = next
        // Animate/speak only for new advice; numbers in the same advice just refresh.
        if isNewAdvice {
            messageID += 1
            speak(next)
        }
    }

    private func speak(_ message: CoachingMessage) {
        // Only when over the speed limit; other advice stays on screen.
        guard speaks, message.speaksAloud else { return }
        // Don't nag: the same warning at most once a minute.
        if let last = lastSpoken, last.title == message.title, Date.now.timeIntervalSince(last.at) < 60 { return }
        lastSpoken = (message.title, .now)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: "\(message.title). \(message.body)")
        utterance.voice = PulseVoice.preferred()
        utterance.rate = 0.5
        synthesizer.stopSpeaking(at: .word)
        synthesizer.speak(utterance)
    }
}

/// Starts live monitoring automatically when Core Motion says the phone is in a moving car.
@Observable
final class DriveAutoDetector {
    private(set) var isDriving = false
    @ObservationIgnored private let activity = CMMotionActivityManager()
    @ObservationIgnored var onDriveStarted: (() -> Void)?
    @ObservationIgnored var onDriveEnded: (() -> Void)?

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start() {
        guard isAvailable else { return }
        activity.startActivityUpdates(to: .main) { [weak self] update in
            guard let self, let update, update.confidence != .low else { return }
            if update.automotive, !self.isDriving {
                self.isDriving = true
                self.onDriveStarted?()
            } else if !update.automotive, update.stationary || update.walking, self.isDriving {
                self.isDriving = false
                self.onDriveEnded?()
            }
        }
    }

    func stop() {
        activity.stopActivityUpdates()
    }
}
