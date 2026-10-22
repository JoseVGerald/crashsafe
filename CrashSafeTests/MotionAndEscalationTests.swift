import Foundation
import Testing
@testable import CrashSafe

@MainActor
struct EscalationTests {
    func makeCenter(alarm: SilentCrashAlarm, dialer: NoEmergencyDialer) -> CrashResponseCenter {
        let center = CrashResponseCenter(alerts: MockEmergencyAlertService(), notifier: RecordingNotifier(),
                                         isOnline: { true }, alarm: alarm, dialer: dialer,
                                         duration: 30, tick: .milliseconds(5))
        center.keepAlive = { _ in {} }
        return center
    }

    @Test func asksEveryFiveSecondsThenSoundsTheAlarmAndCallsForHelp() async throws {
        let alarm = SilentCrashAlarm(), dialer = NoEmergencyDialer()
        let center = makeCenter(alarm: alarm, dialer: dialer)
        let model = center.begin(CrashEvent(date: .now, peakG: 9, speedDropMPH: 20, isSimulated: false), ownerID: "u1")
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.phase == .resolved(.noResponse))
        // 30, 25, 20, 15, 10, 5 seconds left.
        #expect(alarm.spoken.filter { $0.hasPrefix("Are you okay?") }.count == 6)
        #expect(alarm.spoken.contains { $0.contains("sound an alarm and call for help") })
        #expect(alarm.isSirenOn && center.isSirenOn)
        #expect(dialer.calls == 1 && center.startedEmergencyCall)
        center.stopSiren()
        #expect(!alarm.isSirenOn)
    }

    @Test func answeringOkStopsEverything() {
        let alarm = SilentCrashAlarm(), dialer = NoEmergencyDialer()
        let center = makeCenter(alarm: alarm, dialer: dialer)
        center.begin(CrashEvent(date: .now, peakG: 9, speedDropMPH: 20, isSimulated: false), ownerID: "u1")
        center.respond(.ok)
        #expect(!alarm.isSirenOn && dialer.calls == 0)
        #expect(alarm.spoken.last == "Okay. I'm glad you're okay.")
    }

    @Test func testCrashesNeverStartA911Call() async throws {
        let alarm = SilentCrashAlarm(), dialer = NoEmergencyDialer()
        let center = makeCenter(alarm: alarm, dialer: dialer)
        center.begin(CrashEvent(date: .now, peakG: 9, speedDropMPH: 20, isSimulated: true), ownerID: "u1")
        try await Task.sleep(for: .milliseconds(400))
        #expect(alarm.isSirenOn)           // the siren is still demonstrated
        #expect(dialer.calls == 0 && !center.startedEmergencyCall)
        let other = makeCenter(alarm: SilentCrashAlarm(), dialer: dialer)
        other.begin(CrashEvent(date: .now, peakG: 9, speedDropMPH: 20, isSimulated: false), ownerID: "u1")
        other.respond(.needsHelp)
        #expect(dialer.calls == 1)
    }
}

@MainActor
struct MotionIntelligenceAppTests {
    func intelligence() -> MotionIntelligence {
        MotionIntelligence(sensors: SensorHub(motion: TestMotionSource(), location: TestLocationSource(), useWatchdog: false))
    }

    func feed(_ i: MotionIntelligence, seconds: Double, speed: Double, accel: (Double) -> SensorVector) {
        var lat = 45.5
        for k in 0..<Int(seconds * 100) {
            let t = 100 + Double(k) / 100
            i.ingest(.motion(MotionSample(uptime: t, date: Date(timeIntervalSinceReferenceDate: t), accelerationG: accel(t),
                                          gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: .zero)))
            if k % 100 == 0 {
                i.ingest(.location(LocationSample(uptime: t, date: Date(timeIntervalSinceReferenceDate: t), latitude: lat,
                                                  longitude: -122.6, horizontalAccuracy: 5, speedMPS: speed, speedAccuracy: 0.5)))
                lat += speed / 111_320
            }
        }
    }

    @Test func walkingIsDetectedLiveAndReachesPulse() async throws {
        let i = intelligence()
        feed(i, seconds: 12, speed: 1.4) { t in SensorVector(x: 0, y: 0, z: 0.25 * sin(2 * .pi * 1.9 * t)) }
        #expect(i.windowsAnalyzed >= 3)
        #expect(i.current?.label == "walk")
        let activity = try #require(i.assistantActivity)
        #expect(activity.transport.basis == "model" && activity.transport.modelId == "crashsafe-shl8-features-v3")
        var context = AssistantContext(userName: "Jose", isOnline: false, scenario: .general, carDescription: "",
                                       insurer: "", medicalNotes: "", familyContactNames: [])
        context.activity = activity
        let reply = try await LocalEvidenceAssistant().reply(to: [ChatMessage(role: .user, text: "What am I doing right now?")],
                                                            context: context)
        #expect(reply.contains("walking"))
    }

    @Test func impactAndPacketUseTheBackendSchema() throws {
        let i = intelligence()
        let simulated = CrashEvent(date: .now, peakG: 6, speedDropMPH: 20, isSimulated: true)
        let report = try #require(i.impactReport(for: simulated))
        #expect(report.isSimulated && report.severity == .moderate)
        var event = simulated
        event.impact = report
        var packet = AssistantIncident.make(event: event)
        packet.behaviorEvents = [.init(kind: "harsh_brake", start: 10, end: 12, severity: 0.8)]
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(packet)) as? [String: Any])
        let impact = try #require(json["impact"] as? [String: Any])
        for key in ["peak_g", "pulse_duration_s", "delta_v_mps", "time_to_stop_s", "severity", "is_simulated"] {
            #expect(impact[key] != nil, "missing \(key)")
        }
        #expect((json["behavior_events"] as? [[String: Any]])?.first?["kind"] as? String == "harsh_brake")
        let activity = AssistantActivity(transport: .init(label: "car", basis: "model", probability: 0.9, modelId: "m"),
                                         harshBrakes10min: 2, harshAccels10min: 0)
        let a = try #require(JSONSerialization.jsonObject(with: encoder.encode(activity)) as? [String: Any])
        #expect(a["harsh_brakes_10min"] as? Int == 2)
        #expect((a["transport"] as? [String: Any])?["model_id"] as? String == "m")
    }

    @Test func pulseExplainsTheMeasuredImpact() async throws {
        var event = CrashEvent(date: .now, peakG: 6, speedDropMPH: 20, isSimulated: true)
        event.impact = ImpactAnalyzer.simulatedReport()
        var context = AssistantContext(userName: "Jose", isOnline: false, scenario: .afterCrash(.ok), carDescription: "",
                                       insurer: "", medicalNotes: "", familyContactNames: [])
        context.incident = AssistantIncident.make(event: event)
        let reply = try await LocalEvidenceAssistant().reply(to: [ChatMessage(role: .user, text: "How hard did I hit?")],
                                                            context: context)
        #expect(reply.contains("14 mph") && reply.contains("moderate") && reply.contains("test crash"))
    }
}

/// Regressions for the two crashes pulled from a real iPhone (2026-10-21).
struct ThreadingRegressionTests {
    /// Core Motion calls the handler on its own queue. A main-actor-isolated handler traps there
    /// ("Drive this car" crashed every real device); this would bring down the test run.
    @Test func motionHandlerRunsOnCoreMotionsQueue() async {
        let delivered = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let handler = CoreMotionSource.handler(origin: .now) { sample, denied in
                done.resume(returning: sample == nil && !denied)
            }
            let queue = OperationQueue()
            queue.addOperation { handler(nil, nil) }
        }
        #expect(delivered)
    }

    /// Notification completions must finish on the main thread (UIKit asserts it).
    @Test func notificationCompletionFinishesOnMain() async {
        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let completion = MainThreadCompletion<Int> { _ in done.resume(returning: Thread.isMainThread) }
            DispatchQueue.global().async {
                DispatchQueue.main.async { completion.call(1) }
            }
        }
        #expect(onMain)
    }
}

@MainActor
struct SpeedingCoachTests {
    func input(speed: Double, limit: Double?, posted: Bool = true, environment: RoadEnvironment = .city,
               style: CoachingStyle = .logical) -> CoachingEngine.Input {
        var s = DrivingSnapshot()
        s.speedMPH = speed
        s.speedLimitMPH = limit
        s.speedLimitIsPosted = posted
        s.environment = environment
        return CoachingEngine.Input(snapshot: s, advice: DrivingAdvice.make(weather: nil, isNight: false), weather: nil,
                                    isNight: false, style: style, experience: .newDriver, lovedOne: "your mom")
    }

    @Test func speaksOnlyWhenOverTheSpeedLimit() {
        #expect(!CoachingEngine.message(for: input(speed: 30, limit: 30)).speaksAloud)
        #expect(!CoachingEngine.message(for: input(speed: 33, limit: 30)).speaksAloud)   // GPS wobble room
        #expect(CoachingEngine.message(for: input(speed: 36, limit: 30)).speaksAloud)
        #expect(!CoachingEngine.message(for: input(speed: 60, limit: nil)).speaksAloud)  // unknown limit: stay quiet
        // A typical (unposted) limit needs a bigger margin before Pulse speaks.
        #expect(!CoachingEngine.message(for: input(speed: 32, limit: 25, posted: false)).speaksAloud)
        #expect(CoachingEngine.message(for: input(speed: 36, limit: 25, posted: false)).speaksAloud)
    }

    @Test func imagineMessageUsesRealStoppingPhysics() {
        // 42 in a 30 on dry pavement: at 30 you stop in ~110 ft; at 42 you'd still be doing ~37 mph there.
        #expect(CoachingEngine.stoppingDistanceFeet(mph: 30, friction: 0.7) == 110)
        #expect(CoachingEngine.impactSpeedMPH(from: 42, obstacleFeet: 110, friction: 0.7) == 37)
        #expect(CoachingEngine.impactSpeedMPH(from: 30, obstacleFeet: 110, friction: 0.7) == 0)
        let city = CoachingEngine.message(for: input(speed: 42, limit: 30))
        #expect(city.title == "Slow to 30 mph" && city.severity == .warning)
        #expect(city.body.contains("Imagine a child running out"))
        #expect(city.body.contains("about 37 mph") && city.body.contains("1 in 3"))
        let highway = CoachingEngine.message(for: input(speed: 78, limit: 60, environment: .highway))
        #expect(highway.body.contains("traffic stopped") && highway.body.contains("story"))
        let heart = CoachingEngine.message(for: input(speed: 42, limit: 30, style: .emotional))
        #expect(heart.body.hasPrefix("Your mom") && heart.body.contains("Imagine"))
    }
}
