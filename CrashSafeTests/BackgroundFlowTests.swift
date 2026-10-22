import Foundation
import Testing
import UserNotifications
@testable import CrashSafe

/// The locked-phone path: a drive noticed in the background starts crash detection, a crash starts the
/// countdown and a lock-screen notification without any screen, and lock-screen answers reach it.
@MainActor
struct BackgroundFlowTests {
    // MARK: Drive watcher

    @Test func autoDetectedDriveStartsCrashDetectionForTheChosenCar() {
        let (watcher, driving, detector, wakeups) = makeWatcher()
        watcher.arm(.init(ownerID: "u1", carType: .suv))
        #expect(wakeups.enabled == true)

        watcher.driveStarted()
        #expect(driving.mode == .live)
        #expect(detector.isMonitoring && detector.carType == .suv)

        watcher.driveEnded()
        #expect(driving.mode == .idle && !detector.isMonitoring)
    }

    @Test func autoDetectionLeavesAManualTripAlone() {
        let (watcher, driving, detector, _) = makeWatcher()
        watcher.arm(.init(ownerID: "u1", carType: .sedan))
        // The driver started a trip by hand first.
        driving.startLive(background: true)
        detector.startMonitoring(carType: .truck)

        watcher.driveStarted()
        #expect(detector.carType == .truck) // not restarted with another car
        watcher.driveEnded()
        #expect(driving.mode == .live && detector.isMonitoring) // still running
        driving.stop()
    }

    @Test func armedStateSurvivesARelaunchAndClearsOnSignOut() {
        let defaults = UserDefaults(suiteName: "watcher-\(UUID().uuidString)")!
        let (first, _, _, _) = makeWatcher(defaults: defaults)
        first.arm(.init(ownerID: "u1", carType: .motorcycle))

        // A fresh process (iOS relaunched the app for a location event): no view runs, only resumeIfArmed().
        let (relaunched, _, detector, wakeups) = makeWatcher(defaults: defaults)
        #expect(!relaunched.isArmed)
        relaunched.resumeIfArmed()
        #expect(relaunched.configuration == .init(ownerID: "u1", carType: .motorcycle))
        #expect(wakeups.enabled == true)
        relaunched.driveStarted()
        #expect(detector.carType == .motorcycle)

        relaunched.disarm()
        #expect(wakeups.enabled == false && !detector.isMonitoring)
        let (afterSignOut, _, _, _) = makeWatcher(defaults: defaults)
        afterSignOut.resumeIfArmed()
        #expect(!afterSignOut.isArmed)
    }

    // MARK: Crash response without a screen

    @Test func crashStartsCountdownAndLockScreenAlertWithoutAnyView() async throws {
        let notifier = RecordingNotifier()
        let center = makeCenter(notifier: notifier)
        var recorded: [CheckInOutcome] = []
        center.recordOutcome = { _, _, outcome in recorded.append(outcome) }
        center.recipientsProvider = { _ in [AlertRecipient(name: "Maria", phone: "555-0100")] }

        let event = CrashEvent(date: .now, peakG: 6, speedDropMPH: 35, isSimulated: false)
        let viewModel = center.begin(event, ownerID: "u1")
        #expect(notifier.checkIns.count == 1)
        #expect(notifier.checkIns.first?.contacts == "Maria")

        try await Task.sleep(for: .milliseconds(300)) // countdown runs out with no screen involved
        #expect(viewModel.phase == .resolved(.noResponse))
        #expect(recorded == [.noResponse])
        #expect(notifier.withdrawn == [event.id])
        #expect(notifier.followUps.first?.contains("No answer, so we're alerting Maria") == true)
    }

    @Test func lockScreenAnswerReachesTheRunningCountdown() {
        let notifier = RecordingNotifier()
        let center = makeCenter(notifier: notifier, tick: .seconds(60))
        let event = CrashEvent(date: .now, peakG: 6, speedDropMPH: 35, isSimulated: false)
        let viewModel = center.begin(event, ownerID: "u1")

        // A second impact while the first check-in is open doesn't start another.
        #expect(center.begin(CrashEvent(date: .now, peakG: 7, speedDropMPH: 20, isSimulated: false), ownerID: "u1") === viewModel)
        #expect(notifier.checkIns.count == 1)

        let answer = CrashNotification.outcome(forAction: CrashNotification.okAction)
        #expect(answer == .ok)
        center.respond(answer!)
        #expect(viewModel.phase == .resolved(.ok))
        #expect(notifier.withdrawn == [event.id] && notifier.followUps.isEmpty)
        center.dismiss()
        #expect(center.current == nil)
    }

    @Test func lockScreenActionsAreSetUpForUseWithoutUnlocking() throws {
        let category = try #require(CrashNotification.categories.first)
        let ok = try #require(category.actions.first { $0.identifier == CrashNotification.okAction })
        let help = try #require(category.actions.first { $0.identifier == CrashNotification.helpAction })
        #expect(!ok.options.contains(.foreground) && !ok.options.contains(.authenticationRequired))
        #expect(help.options.contains(.foreground))
        #expect(CrashNotification.outcome(forAction: CrashNotification.helpAction) == .needsHelp)
        #expect(CrashNotification.outcome(forAction: UNNotificationDefaultActionIdentifier) == nil)
    }

    @Test func crashWhileClosedUsesTheArmedDriverWhenNoOneIsSignedInYet() {
        let notifier = RecordingNotifier()
        let defaults = UserDefaults(suiteName: "env-\(UUID().uuidString)")!
        let env = AppEnvironment(
            auth: MockAuthService(defaults: defaults, latency: .zero), crashDetector: MockCrashDetector(),
            assistant: MockAssistantService(latency: .zero), voiceInput: MockVoiceInputService(),
            tripPacks: MockTripPackService(), alerts: MockEmergencyAlertService(), weather: MockWeatherService(),
            connectivity: ConnectivityMonitor(start: false), notifier: notifier, defaults: defaults)
        let event = CrashEvent(date: .now, peakG: 6, speedDropMPH: 30, isSimulated: false)

        env.handleCrash(event) // signed out and not armed: nobody to check on
        #expect(env.router.activeCrash == nil && notifier.checkIns.isEmpty)

        env.driveWatcher.arm(.init(ownerID: "u1", carType: .sedan)) // background relaunch: session not restored
        env.handleCrash(event)
        #expect(env.router.activeCrash == event && env.crashCenter.isCounting)
        #expect(notifier.checkIns.count == 1)
        env.crashCenter.respond(.ok)
        env.driveWatcher.disarm()
    }

    // MARK: Off-screen sensor proof

    @Test func sensorReadingsAreCountedOnlyWhileOffScreen() {
        var state = (background: false, locked: false)
        let motion = TestMotionSource()
        let location = TestLocationSource()
        let hub = SensorHub(motion: motion, location: location, now: { 10 }, useWatchdog: false, appState: { state })
        hub.acquire(owner: UUID(), background: true)

        motion.emit(sample(9.99))
        #expect(hub.backgroundLog.isEmpty) // on screen: not counted

        state = (true, false)
        motion.emit(sample(9.995))
        state = (true, true)
        motion.emit(sample(10))
        location.emit(LocationSample(uptime: 10, date: .now, latitude: 45.5, longitude: -122.6,
                                     horizontalAccuracy: 5, speedMPS: 20, speedAccuracy: 1))
        #expect(hub.backgroundLog.backgroundMotion == 2 && hub.backgroundLog.lockedMotion == 1)
        #expect(hub.backgroundLog.backgroundLocation == 1 && hub.backgroundLog.lockedLocation == 1)
        #expect(abs(hub.backgroundLog.longestBackgroundGap - 0.005) < 0.0001)

        hub.resetBackgroundLog()
        #expect(hub.backgroundLog.isEmpty)
    }

    // MARK: Helpers

    private func makeWatcher(defaults: UserDefaults = UserDefaults(suiteName: "watcher-\(UUID().uuidString)")!)
        -> (BackgroundDriveWatcher, DrivingMonitor, RecordingCrashDetector, TestWakeups) {
        let sensors = SensorHub(motion: TestMotionSource(), location: TestLocationSource(), useWatchdog: false)
        let driving = DrivingMonitor(sensors: sensors)
        let detector = RecordingCrashDetector()
        let wakeups = TestWakeups()
        let watcher = BackgroundDriveWatcher(driving: driving, crashDetector: detector, wakeups: wakeups,
                                             autoDetector: nil, defaults: defaults)
        return (watcher, driving, detector, wakeups)
    }

    private func makeCenter(notifier: RecordingNotifier, tick: Duration = .milliseconds(10)) -> CrashResponseCenter {
        let center = CrashResponseCenter(alerts: MockEmergencyAlertService(), notifier: notifier, isOnline: { true },
                                         duration: 3, tick: tick)
        center.keepAlive = { _ in {} }
        return center
    }

    private func sample(_ uptime: TimeInterval) -> MotionSample {
        MotionSample(uptime: uptime, date: .now, accelerationG: SensorVector(x: 0, y: 0, z: 0.1),
                     gravityG: SensorVector(x: 0, y: 0, z: -1), rotationRate: SensorVector(x: 0, y: 0, z: 0))
    }
}

@MainActor
final class TestWakeups: DriveWakeupSource {
    var enabled: Bool?
    func setDriveWakeups(_ enabled: Bool) { self.enabled = enabled }
}

@MainActor
final class RecordingCrashDetector: CrashDetector {
    private(set) var isMonitoring = false
    private(set) var carType: CarType?
    let events: AsyncStream<CrashEvent>
    private let continuation: AsyncStream<CrashEvent>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream(of: CrashEvent.self) }

    func startMonitoring(carType: CarType) {
        isMonitoring = true
        self.carType = carType
    }

    func stopMonitoring() { isMonitoring = false }
    func simulateCrash() {}
}

@MainActor
final class RecordingNotifier: CrashNotifying {
    var checkIns: [(id: UUID, contacts: String?)] = []
    var withdrawn: [UUID] = []
    var followUps: [String] = []

    func postCheckIn(for event: CrashEvent, secondsToRespond: Int, contactSummary: String?) {
        checkIns.append((event.id, contactSummary))
    }

    func withdrawCheckIn(for event: CrashEvent) { withdrawn.append(event.id) }
    func postFollowUp(_ text: String, for event: CrashEvent) { followUps.append(text) }
}
