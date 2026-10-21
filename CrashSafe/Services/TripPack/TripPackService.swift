import Foundation

struct TripPackPlace: Sendable, Equatable {
    let name: String
    let phone: String
    let milesFromRoute: Double
}

/// Offline data for one trip, downloaded before the signal drops.
struct TripPack: Sendable {
    let towCompanies: [TripPackPlace]
    let hospitals: [TripPackPlace]
    /// Pre-generated guides/scripts the offline assistant can read.
    let guides: [String]
    let generatedAt: Date

    var summary: String {
        "\(towCompanies.count) tow companies · \(hospitals.count) hospitals · \(guides.count) guides"
    }
}

/// Builds the trip pack for a planned route.
///
/// MAPS TEAM: implement `MapKitTripPackService` (MKLocalSearch for towing + hospitals
/// along the route) and persist packs to disk so they survive relaunch in airplane mode.
protocol TripPackService: AnyObject {
    func downloadPack(origin: String, destination: String) async throws -> TripPack
}

/// Returns fake places after a short delay.
final class MockTripPackService: TripPackService {
    func downloadPack(origin: String, destination: String) async throws -> TripPack {
        try await Task.sleep(for: .seconds(1.5))
        return TripPack(
            towCompanies: [
                TripPackPlace(name: "Evergreen Towing", phone: "555-0101", milesFromRoute: 1.2),
                TripPackPlace(name: "Cascade Roadside", phone: "555-0102", milesFromRoute: 3.8),
                TripPackPlace(name: "\(destination) Auto Rescue", phone: "555-0103", milesFromRoute: 0.6),
            ],
            hospitals: [
                TripPackPlace(name: "\(origin) General Hospital", phone: "555-0201", milesFromRoute: 2.4),
                TripPackPlace(name: "\(destination) Medical Center", phone: "555-0202", milesFromRoute: 1.1),
            ],
            guides: ["After a crash: first 10 minutes", "Talking to a tow driver", "Insurance: facts only"],
            generatedAt: .now
        )
    }
}
