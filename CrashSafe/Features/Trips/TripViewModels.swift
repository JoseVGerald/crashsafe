import Foundation
import MapKit
import Observation
import SwiftData

@Observable
final class TripPlannerViewModel {
    var origin: PlaceSelection? {
        didSet { if origin != oldValue { Task { await updateRoute() } } }
    }
    var destination: PlaceSelection? {
        didSet { if destination != oldValue { Task { await updateRoute() } } }
    }
    var startDate: Date
    var endDate: Date
    private(set) var route: MKRoute?
    private(set) var isRouting = false
    private(set) var submitAttempted = false
    private(set) var lastSaved: String?

    @ObservationIgnored private let userID: String

    init(userID: String, now: Date = .now) {
        self.userID = userID
        self.startDate = now
        self.endDate = now.addingTimeInterval(24 * 3_600)
    }

    var originError: String? {
        submitAttempted && origin == nil ? "Choose where you're leaving from." : nil
    }

    var destinationError: String? {
        submitAttempted && destination == nil ? "Choose where you're headed." : nil
    }

    var datesError: String? {
        endDate < startDate ? "Return date must be after the start date." : nil
    }

    var isValid: Bool {
        origin != nil && destination != nil && endDate >= startDate
    }

    var routeSummary: String? {
        guard let route else { return nil }
        let miles = Measurement(value: route.distance, unit: UnitLength.meters).converted(to: .miles)
        let time = Duration.seconds(route.expectedTravelTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(miles.formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))) · \(time)"
    }

    func swap() {
        let oldOrigin = origin
        origin = destination
        destination = oldOrigin
    }

    func updateRoute() async {
        guard let origin, let destination else {
            route = nil
            return
        }
        isRouting = true
        defer { isRouting = false }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile
        route = try? await MKDirections(request: request).calculate().routes.first
    }

    @discardableResult
    func save(in context: ModelContext) -> Trip? {
        submitAttempted = true
        guard isValid, let origin, let destination else { return nil }
        let originName = origin.isCurrentLocation ? (origin.subtitle.isEmpty ? "Current location" : origin.subtitle) : origin.title
        let trip = Trip(ownerID: userID, origin: originName, destination: destination.title,
                        startDate: startDate, endDate: endDate)
        trip.originLatitude = origin.latitude
        trip.originLongitude = origin.longitude
        trip.destinationLatitude = destination.latitude
        trip.destinationLongitude = destination.longitude
        trip.routeDistanceMeters = route?.distance
        trip.routeTravelSeconds = route?.expectedTravelTime
        context.insert(trip)
        lastSaved = trip.routeLabel
        self.destination = nil
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
            let pack = try await service.downloadPack(for: TripPackRequest(
                origin: trip.origin, destination: trip.destination,
                originCoordinate: trip.originCoordinate, destinationCoordinate: trip.destinationCoordinate))
            trip.tripPackData = try? JSONEncoder().encode(pack)
            trip.tripPackSummary = pack.summary
            trip.tripPackUpdatedAt = pack.generatedAt
            trip.tripPackStatus = .ready
        } catch {
            trip.tripPackStatus = .failed
        }
    }
}
