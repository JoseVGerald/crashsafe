import Foundation
import Observation
import SwiftData

/// Starts/ends trips and keeps crash detection and the driving monitor in sync with the active trip.
@Observable
final class HomeViewModel {
    @ObservationIgnored private let detector: any CrashDetector
    @ObservationIgnored private let driving: DrivingMonitor
    @ObservationIgnored private let conditions: ConditionsStore
    @ObservationIgnored private let userID: String

    init(detector: any CrashDetector, driving: DrivingMonitor, conditions: ConditionsStore, userID: String) {
        self.detector = detector
        self.driving = driving
        self.conditions = conditions
        self.userID = userID
    }

    var isMonitoring: Bool { detector.isMonitoring }

    func start(_ trip: Trip, among trips: [Trip], profile: Profile?) {
        for other in trips where other.isActive && other !== trip {
            other.isActive = false
            other.startedAt = nil
        }
        trip.isActive = true
        trip.startedAt = .now
        driving.speedLimits?.setOfflineRoads(trip.tripPack?.roads ?? [])
        detector.startMonitoring(carType: profile?.carType ?? .sedan)
        if driving.scenario == nil {
            driving.startLive(background: profile?.autoDetectDrives ?? true)
        }
    }

    /// A trip with no planned route, for short drives.
    func startQuickTrip(among trips: [Trip], profile: Profile?, in context: ModelContext) {
        let trip = Trip(ownerID: userID, origin: "Current location", destination: "Quick drive",
                        startDate: .now, endDate: .now.addingTimeInterval(12 * 3_600))
        context.insert(trip)
        start(trip, among: trips, profile: profile)
    }

    /// Switching cars mid-drive re-tunes crash detection to the new vehicle type.
    func changeVehicle(profile: Profile?) {
        guard detector.isMonitoring else { return }
        detector.stopMonitoring()
        detector.startMonitoring(carType: profile?.carType ?? .sedan)
    }

    func end(_ trip: Trip) {
        trip.isActive = false
        trip.startedAt = nil
        detector.stopMonitoring()
        if driving.mode == .live { driving.stop() }
    }

    /// After relaunch an active trip is restored from disk but nothing is running yet.
    func resumeIfNeeded(activeTrip: Trip?, profile: Profile?) {
        guard activeTrip != nil else { return }
        if !detector.isMonitoring { detector.startMonitoring(carType: profile?.carType ?? .sedan) }
        if !driving.isActive { driving.startLive(background: profile?.autoDetectDrives ?? true) }
    }

    func startDemo(_ scenario: DriveScenario) {
        driving.startDemo(scenario)
        conditions.override(with: scenario.weather)
    }

    func stopDemo(location: LocationService) async {
        driving.stop()
        conditions.override(with: nil)
        await conditions.refresh(for: location.location, force: true)
    }

    func simulateCrash() {
        detector.simulateCrash()
    }
}
