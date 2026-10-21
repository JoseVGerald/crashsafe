import CoreLocation
import Foundation
import MapKit

/// A hospital, police station or tow company.
nonisolated struct HelpPlace: Codable, Sendable, Hashable, Identifiable {
    enum Category: String, Codable, Sendable, CaseIterable {
        case hospital, police, towing

        var title: String {
            switch self {
            case .hospital: "Hospital"
            case .police: "Police"
            case .towing: "Tow truck"
            }
        }

        var systemImage: String {
            switch self {
            case .hospital: "cross.fill"
            case .police: "shield.lefthalf.filled"
            case .towing: "car.side.fill"
            }
        }
    }

    let name: String
    let phone: String
    let category: Category
    let latitude: Double
    let longitude: Double

    var id: String { "\(category.rawValue)|\(name)|\(latitude)" }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distanceMiles(from location: CLLocation) -> Double {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: location) / 1_609.34
    }
}

/// Offline data for one trip, downloaded before the signal drops.
nonisolated struct TripPack: Codable, Sendable {
    let towCompanies: [HelpPlace]
    let hospitals: [HelpPlace]
    let police: [HelpPlace]
    /// Pre-generated guides/scripts the offline assistant can read.
    let guides: [String]
    let generatedAt: Date

    var allPlaces: [HelpPlace] { hospitals + police + towCompanies }

    var summary: String {
        "\(towCompanies.count) tow · \(hospitals.count) hospitals · \(police.count) police · \(guides.count) guides"
    }
}

struct TripPackRequest: Sendable {
    let origin: String
    let destination: String
    let originCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
}

/// Builds the trip pack for a planned route.
protocol TripPackService: AnyObject {
    func downloadPack(for request: TripPackRequest) async throws -> TripPack
}

/// Searches Apple Maps around the start, middle and end of the route.
final class MapKitTripPackService: TripPackService {
    private let fallback = MockTripPackService()

    func downloadPack(for request: TripPackRequest) async throws -> TripPack {
        guard let from = request.originCoordinate, let to = request.destinationCoordinate else {
            return try await fallback.downloadPack(for: request)
        }
        let middle = CLLocationCoordinate2D(latitude: (from.latitude + to.latitude) / 2,
                                            longitude: (from.longitude + to.longitude) / 2)
        var found: [HelpPlace] = []
        for anchor in [from, middle, to] {
            found += await PlaceSearch.helpPlaces(near: anchor, radiusMeters: 20_000, perCategory: 3)
        }
        let unique = Array(Set(found))
        guard !unique.isEmpty else { return try await fallback.downloadPack(for: request) }
        return TripPack(
            towCompanies: unique.filter { $0.category == .towing },
            hospitals: unique.filter { $0.category == .hospital },
            police: unique.filter { $0.category == .police },
            guides: TripPack.standardGuides,
            generatedAt: .now
        )
    }
}

/// Returns fake places after a short delay (no coordinates / no network).
final class MockTripPackService: TripPackService {
    func downloadPack(for request: TripPackRequest) async throws -> TripPack {
        try await Task.sleep(for: .seconds(1.2))
        let base = request.originCoordinate ?? CLLocationCoordinate2D(latitude: 47.61, longitude: -122.20)
        func place(_ name: String, _ phone: String, _ category: HelpPlace.Category, _ dLat: Double, _ dLon: Double) -> HelpPlace {
            HelpPlace(name: name, phone: phone, category: category,
                      latitude: base.latitude + dLat, longitude: base.longitude + dLon)
        }
        return TripPack(
            towCompanies: [place("Evergreen Towing", "555-0101", .towing, 0.01, 0.02),
                           place("Cascade Roadside", "555-0102", .towing, -0.02, 0.01)],
            hospitals: [place("\(request.origin) General Hospital", "555-0201", .hospital, 0.02, -0.01)],
            police: [place("\(request.origin) Police", "555-0301", .police, -0.01, -0.02)],
            guides: TripPack.standardGuides,
            generatedAt: .now
        )
    }
}

extension TripPack {
    static let standardGuides = ["After a crash: the first 10 minutes", "Talking to a tow driver", "Insurance: facts only"]
}

/// Apple Maps searches shared by the trip pack and the post-crash help hub.
enum PlaceSearch {
    static func helpPlaces(near coordinate: CLLocationCoordinate2D, radiusMeters: Double = 15_000,
                           perCategory: Int = 4) async -> [HelpPlace] {
        var results: [HelpPlace] = []
        for category in HelpPlace.Category.allCases {
            results += await search(category, near: coordinate, radiusMeters: radiusMeters).prefix(perCategory)
        }
        return results
    }

    static func search(_ category: HelpPlace.Category, near coordinate: CLLocationCoordinate2D,
                       radiusMeters: Double) async -> [HelpPlace] {
        let request = MKLocalSearch.Request()
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radiusMeters, longitudinalMeters: radiusMeters)
        switch category {
        case .hospital:
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.hospital])
            request.resultTypes = .pointOfInterest
        case .police:
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.police])
            request.resultTypes = .pointOfInterest
        case .towing:
            request.naturalLanguageQuery = "towing service"
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return response.mapItems
            .compactMap { item -> HelpPlace? in
                let point = item.placemark.coordinate
                return HelpPlace(name: item.name ?? category.title, phone: item.phoneNumber ?? "",
                                 category: category, latitude: point.latitude, longitude: point.longitude)
            }
            .sorted { $0.distanceMiles(from: origin) < $1.distanceMiles(from: origin) }
    }
}
