import Foundation
import Observation
import SwiftData

@Observable
final class TripPlannerViewModel {
    var origin = ""
    var destination = ""
    var startDate: Date
    var endDate: Date
    private(set) var submitAttempted = false
    private(set) var lastSaved: String?

    @ObservationIgnored private let userID: String

    init(userID: String, now: Date = .now) {
        self.userID = userID
        self.startDate = now
        self.endDate = now.addingTimeInterval(24 * 3_600)
    }

    var originError: String? {
        submitAttempted && origin.trimmed.isEmpty ? "Where are you leaving from?" : nil
    }

    var destinationError: String? {
        submitAttempted && destination.trimmed.isEmpty ? "Where are you headed?" : nil
    }

    var datesError: String? {
        endDate < startDate ? "Return date must be after the start date." : nil
    }

    var isValid: Bool {
        !origin.trimmed.isEmpty && !destination.trimmed.isEmpty && endDate >= startDate
    }

    @discardableResult
    func save(in context: ModelContext) -> Trip? {
        submitAttempted = true
        guard isValid else { return nil }
        let trip = Trip(ownerID: userID, origin: origin.trimmed, destination: destination.trimmed,
                        startDate: startDate, endDate: endDate)
        context.insert(trip)
        lastSaved = trip.routeLabel
        origin = ""
        destination = ""
        submitAttempted = false
        return trip
    }

    func dismissSavedNotice() {
        lastSaved = nil
    }
}

/// Downloads the offline trip pack for one trip.
@Observable
final class TripPackViewModel {
    @ObservationIgnored private let service: any TripPackService

    init(service: any TripPackService) {
        self.service = service
    }

    func download(for trip: Trip) async {
        guard trip.tripPackStatus != .downloading else { return }
        trip.tripPackStatus = .downloading
        do {
            let pack = try await service.downloadPack(origin: trip.origin, destination: trip.destination)
            trip.tripPackSummary = pack.summary
            trip.tripPackUpdatedAt = pack.generatedAt
            trip.tripPackStatus = .ready
        } catch {
            trip.tripPackStatus = .failed
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
