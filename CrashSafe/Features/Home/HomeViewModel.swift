import Foundation
import Observation
import SwiftData

/// Starts/ends trips and keeps the crash detector in sync with the active trip.
@Observable
final class HomeViewModel {
    @ObservationIgnored private let detector: any CrashDetector
    @ObservationIgnored private let userID: String

    init(detector: any CrashDetector, userID: String) {
        self.detector = detector
        self.userID = userID
    }

    var isMonitoring: Bool { detector.isMonitoring }

    func start(_ trip: Trip, among trips: [Trip], carType: CarType) {
        for other in trips where other.isActive && other !== trip {
            other.isActive = false
            other.startedAt = nil
        }
        trip.isActive = true
        trip.startedAt = .now
        detector.startMonitoring(carType: carType)
    }

    /// A trip with no planned route, for short drives.
    func startQuickTrip(among trips: [Trip], carType: CarType, in context: ModelContext) {
        let trip = Trip(ownerID: userID, origin: "Current location", destination: "Quick drive",
                        startDate: .now, endDate: .now.addingTimeInterval(12 * 3_600))
        context.insert(trip)
        start(trip, among: trips, carType: carType)
    }

    func end(_ trip: Trip) {
        trip.isActive = false
        trip.startedAt = nil
        detector.stopMonitoring()
    }

    /// After relaunch an active trip is restored from disk but the detector isn't running yet.
    func resumeMonitoringIfNeeded(activeTrip: Trip?, carType: CarType) {
        if activeTrip != nil, !detector.isMonitoring {
            detector.startMonitoring(carType: carType)
        }
    }

    func simulateCrash() {
        detector.simulateCrash()
    }
}
