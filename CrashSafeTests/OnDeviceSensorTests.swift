import CoreMotion
import Speech
import Foundation
import Testing
@testable import CrashSafe

/// Runs only on a real iPhone (the simulator has no motion hardware): the exact path that crashed when
/// "Drive this car" started live sensors, and the live data the Sensor Lab shows. Quiet: no speech,
/// no siren, no alerts.
///
///     xcodebuild test -project CrashSafe.xcodeproj -scheme CrashSafe -destination 'id=<device>' \
///       -only-testing:CrashSafeTests/OnDeviceSensorTests DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates
@MainActor
struct OnDeviceSensorTests {
    nonisolated static var hasHardware: Bool { CMMotionManager().isDeviceMotionAvailable }

    /// Core Motion calls back on its own queue ~100 times a second; before the fix, the first callback
    /// trapped (dispatch_assert_queue_fail) and the app crashed.
    @Test(.enabled(if: hasHardware)) func realMotionReachesTheMainActorAtAbout100Hz() async throws {
        let source = CoreMotionSource()
        var samples: [MotionSample] = []
        source.start(interval: 0.01) { sample, _ in
            MainActor.assertIsolated()
            if let sample { samples.append(sample) }
        }
        try await Task.sleep(for: .seconds(2))
        source.stop()
        let count = samples.count
        #expect(count >= 150, "got \(count) samples in 2 s")
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1.uptime > $0.uptime })
        let gravity = samples.map(\.gravityG.magnitude)
        #expect(gravity.allSatisfy { (0.95...1.05).contains($0) })
        // Lying still (or held), user acceleration is small and the tilt is defined.
        #expect(SensorLabMath.tilt(gravity: try #require(samples.last).gravityG) != nil)
        let measuredHz = Double(count - 1) / (samples.last!.uptime - samples.first!.uptime)
        #expect(measuredHz > 80, "measured \(measuredHz) Hz")
    }

    /// What "Drive this car" does: a live drive plus crash monitoring on the shared sensor hub.
    @Test(.enabled(if: hasHardware)) func liveDriveAndCrashMonitoringRunOnRealSensors() async throws {
        let hub = SensorHub(location: TestLocationSource())
        let driving = DrivingMonitor(sensors: hub)
        let detector = CoreMotionCrashDetector(sensors: hub)
        var readings = 0
        _ = hub.addObserver { if case .motion = $0 { readings += 1 } }
        driving.startLive(background: false)
        detector.startMonitoring(carType: .sedan)
        try await Task.sleep(for: .seconds(2))
        #expect(hub.health.state == .active)
        #expect(hub.health.measuredHz > 80)
        #expect(readings >= 150)
        #expect(detector.lastAssessment == nil) // sitting still is never a crash
        detector.stopMonitoring()
        driving.stop()
        #expect(!hub.isRunning)
    }

    /// The Profile lag: real motion arrives 100 times a second while the app is open, and every change to
    /// the observed sensor health redraws Home, Profile and CarPlay. It should change a few times, not 200.
    @Test(.enabled(if: hasHardware)) func realMotionBarelyChangesWhatScreensObserve() async throws {
        let hub = SensorHub(location: TestLocationSource())
        let owner = UUID()
        let probe = ObservationProbe()
        hub.acquire(owner: owner, background: false)
        let end = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < end {
            probe.watch { _ = hub.health }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hub.health.measuredHz > 80)
        #expect(probe.count <= 5, "health changed \(probe.count) times in 2 s of real motion")
        hub.release(owner: owner)
    }

    /// The phone reaching Pulse on the Mac over Wi-Fi: a conversational reply, then Corey's voice.
    @Test(.enabled(if: hasHardware && PulseBackend.endpoint() != nil)) func pulseAndCoreyReachThePhoneOverWiFi() async throws {
        let endpoint = try #require(PulseBackend.endpoint())
        var talk = URLRequest(url: endpoint.appendingPathComponent("v1/converse"), timeoutInterval: 20)
        talk.httpMethod = "POST"
        talk.setValue("application/json", forHTTPHeaderField: "Content-Type")
        PulseBackend.authorize(&talk)
        talk.httpBody = Data(#"{"messages":[{"role":"user","text":"Someone bumped my car in a parking lot. What should I do first?"}]}"#.utf8)
        let (reply, response) = try await URLSession.shared.data(for: talk)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let answer = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect((answer["answer"] as? String)?.isEmpty == false)
        var speak = URLRequest(url: endpoint.appendingPathComponent("v1/tts"), timeoutInterval: 20)
        speak.httpMethod = "POST"
        speak.setValue("application/json", forHTTPHeaderField: "Content-Type")
        PulseBackend.authorize(&speak)
        speak.httpBody = Data(#"{"text":"I'm right here with you."}"#.utf8)
        let (audio, audioResponse) = try await URLSession.shared.data(for: speak)
        #expect((audioResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
        #expect(audio.count > 5_000)
    }

    /// Pulse with no server at all: this phone asks OpenRouter for the reply and Cartesia for Corey's voice,
    /// over whatever internet it has. Runs on builds with keys (Config/Pulse.xcconfig.local), on a phone or, in
    /// the simulator, with `TEST_RUNNER_PULSE_LIVE=1` (it uses the real services).
    @Test(.enabled(if: (hasHardware || ProcessInfo.processInfo.environment["PULSE_LIVE"] == "1")
                   && PulseKeys.openRouter() != nil && PulseKeys.cartesia() != nil))
    func pulseTalksAndSpeaksStraightFromThePhone() async throws {
        let pulse = try #require(DirectPulseService.configured() as? DirectPulseService)
        var context = AssistantContext(userName: "Test", isOnline: true, scenario: .general, carDescription: "", insurer: "",
                                       medicalNotes: "", familyContactNames: [])
        context.assistanceStage = "active"
        let first = [ChatMessage(role: .user, text: "A white truck just sideswiped me on the freeway. I pulled over and I'm okay.")]
        let reply = try await pulse.reply(to: first, context: context)
        #expect(pulse.lastModel != nil, "answered by: \(reply)")
        let followUp = first + [ChatMessage(role: .assistant, text: reply), ChatMessage(role: .user, text: "What color was the truck?")]
        let second = try await pulse.reply(to: followUp, context: context)
        #expect(second.lowercased().contains("white"), "\(second)")
        let audio = await PulseSpeaker().corey(PulseSpeaker.spokenPart(of: second))
        #expect((audio?.count ?? 0) > 5_000)
    }


    /// `run_pulse_agent.py` running next to the backend).
    @Test(.enabled(if: hasHardware && PulseBackend.endpoint() != nil)) func pulseAgentRemembersTheConversationOverWiFi() async throws {
        let endpoint = try #require(PulseBackend.endpoint())
        let conversation = UUID().uuidString
        func say(_ text: String) async throws -> [String: Any] {
            var talk = URLRequest(url: endpoint.appendingPathComponent("v1/converse"), timeoutInterval: 20)
            talk.httpMethod = "POST"
            talk.setValue("application/json", forHTTPHeaderField: "Content-Type")
            PulseBackend.authorize(&talk)
            talk.httpBody = try JSONSerialization.data(withJSONObject: [
                "conversation_id": conversation, "messages": [["role": "user", "text": text]]])
            let (reply, _) = try await URLSession.shared.data(for: talk)
            return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        }
        let first = try await say("A red sedan just hit my car at a stop sign. I'm okay.")
        #expect(first["generation_mode"] as? String == "pulse_agent")
        let second = try await say("What color was the car that hit me?")   // only this turn is sent
        #expect(second["generation_mode"] as? String == "pulse_agent")
        #expect((second["answer"] as? String)?.lowercased().contains("red") == true, "\(second["answer"] ?? "")")
    }

    /// Apple's speech recognizer on this phone understands Pulse's own Corey clip (the same engine the
    /// mic buttons use; asks for Speech Recognition permission the first time).
    @Test(.enabled(if: hasHardware)) func speechRecognitionUnderstandsSpokenWords() async throws {
        try #require(await Self.speechAllowed(), "Speech Recognition permission")
        let clip = try #require(PulseVoiceClips.url(for: CrashResponseCenter.promptText(remaining: 30)))
        let text = try await Self.transcribe(clip)
        #expect(text.lowercased().contains("are you ok"), "heard: \(text)") // "OK" or "okay"
    }

    // Speech callbacks arrive on background queues: these helpers run off the main actor so their
    // closures aren't main-actor isolated (that trapped this test the first time).
    @concurrent nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    @concurrent nonisolated static func transcribe(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { throw URLError(.unsupportedURL) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal { done = true; continuation.resume(returning: result.bestTranscription.formattedString) }
                else if let error { done = true; continuation.resume(throwing: error) }
            }
        }
    }

    /// The Sensor Lab on real sensors: live samples, then a replayed clip in their place, then live again.
    @Test(.enabled(if: hasHardware)) func sensorLabShowsLiveMotionAndReplaysOverIt() async throws {
        let replay = ReplayMotionSource()
        let hub = SensorHub(motion: replay, location: TestLocationSource())
        replay.onFinish = { [weak hub] in hub?.motionSourceChanged() }
        let lab = SensorLabModel(sensors: hub, replay: replay)
        lab.start()
        try await Task.sleep(for: .seconds(1))
        let live = try #require(lab.latest)
        #expect(abs(live.gravityG.magnitude - 1) < 0.05)
        #expect(lab.tilt != nil)
        var rng = SeededGenerator(seed: 4)
        let crash = ScenarioFactory().make(.frontalCrash, rng: &rng)
        // Just the 1.5 s around the impact, so the test stays short.
        let window = crash.readings.filter { abs($0.uptime - crash.eventUptime) < 0.75 }
        replay.play(.init(title: "test", readings: window)) { hub.motionSourceChanged() }
        try await Task.sleep(for: .seconds(1))
        #expect(lab.peakG > 3) // the replayed hit, not the phone on the desk
        try await Task.sleep(for: .seconds(1.2))
        #expect(!lab.isReplaying)
        #expect(hub.health.state == .active) // live sensors resumed
        lab.stop()
        #expect(!hub.isRunning)
    }
}
