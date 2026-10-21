import CoreLocation
import Foundation
import SwiftData

// MARK: - Auth

/// The signed-in account, independent of which AuthService produced it.
struct AuthUser: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var email: String

    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? "there"
    }
}

// MARK: - Driver profile

nonisolated enum CarType: String, Codable, CaseIterable, Identifiable {
    case sedan, suv, truck, minivan, hatchback, coupe, ev, motorcycle, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sedan: "Sedan"
        case .suv: "SUV"
        case .truck: "Truck"
        case .minivan: "Minivan"
        case .hatchback: "Hatchback"
        case .coupe: "Coupe"
        case .ev: "EV"
        case .motorcycle: "Motorcycle"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .suv, .minivan: "suv.side.fill"
        case .truck: "truck.pickup.side.fill"
        case .ev: "bolt.car.fill"
        case .motorcycle: "motorcycle"
        default: "car.side.fill"
        }
    }
}

/// How Pulse should coach this driver. Drives the tone of every safety message.
nonisolated enum CoachingStyle: String, Codable, CaseIterable, Identifiable {
    /// Numbers and consequences: stopping distance, time saved vs. risk.
    case logical
    /// The people and things that matter to them.
    case emotional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logical: "Give me the facts"
        case .emotional: "Remind me what matters"
        }
    }

    var subtitle: String {
        switch self {
        case .logical: "Stopping distances, numbers and clear consequences."
        case .emotional: "A calm nudge about the people waiting for you."
        }
    }

    var systemImage: String {
        switch self {
        case .logical: "chart.bar.xaxis"
        case .emotional: "heart.fill"
        }
    }
}

nonisolated enum DrivingExperience: String, Codable, CaseIterable, Identifiable {
    case learner, newDriver, experienced, veteran

    var id: String { rawValue }

    var label: String {
        switch self {
        case .learner: "Permit"
        case .newDriver: "< 2 yrs"
        case .experienced: "2–10 yrs"
        case .veteran: "10+ yrs"
        }
    }
}

/// One per user. Stored on-device only.
@Model
final class Profile {
    @Attribute(.unique) var ownerID: String
    var medicalNotes: String
    var bloodType: String = ""
    var insurer: String
    var policyNumber: String
    var insurerPhone: String = ""
    var coachingStyleRaw: String = CoachingStyle.logical.rawValue
    var experienceRaw: String = DrivingExperience.newDriver.rawValue
    var onboardingCompleted: Bool = false
    /// Keep monitoring drives in the background (CarPlay-style coaching).
    var autoDetectDrives: Bool = true
    @Relationship(deleteRule: .cascade, inverse: \FamilyContact.profile)
    var familyContacts: [FamilyContact] = []
    @Relationship(deleteRule: .cascade, inverse: \Vehicle.profile)
    var vehicles: [Vehicle] = []

    init(ownerID: String,
         medicalNotes: String = "",
         insurer: String = "",
         policyNumber: String = "") {
        self.ownerID = ownerID
        self.medicalNotes = medicalNotes
        self.insurer = insurer
        self.policyNumber = policyNumber
    }

    var coachingStyle: CoachingStyle {
        get { CoachingStyle(rawValue: coachingStyleRaw) ?? .logical }
        set { coachingStyleRaw = newValue.rawValue }
    }

    var experience: DrivingExperience {
        get { DrivingExperience(rawValue: experienceRaw) ?? .newDriver }
        set { experienceRaw = newValue.rawValue }
    }

    var sortedContacts: [FamilyContact] {
        familyContacts.sorted { $0.createdAt < $1.createdAt }
    }

    var sortedVehicles: [Vehicle] {
        vehicles.sorted { ($0.isPrimary ? 0 : 1, $0.createdAt) < ($1.isPrimary ? 0 : 1, $1.createdAt) }
    }

    var primaryVehicle: Vehicle? {
        sortedVehicles.first
    }

    /// Detection tuning falls back to a sedan when no vehicle is set.
    var carType: CarType {
        primaryVehicle?.type ?? .sedan
    }

    func makePrimary(_ vehicle: Vehicle) {
        for other in vehicles { other.isPrimary = (other === vehicle) }
    }
}

@Model
final class Vehicle {
    var make: String
    var model: String
    var year: Int?
    var typeRaw: String
    var colorName: String
    var plate: String
    var isPrimary: Bool
    var createdAt: Date
    var profile: Profile?

    init(make: String, model: String, year: Int? = nil, type: CarType = .sedan,
         colorName: String = "", plate: String = "", isPrimary: Bool = false) {
        self.make = make
        self.model = model
        self.year = year
        self.typeRaw = type.rawValue
        self.colorName = colorName
        self.plate = plate
        self.isPrimary = isPrimary
        self.createdAt = .now
    }

    var type: CarType {
        get { CarType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    var displayName: String {
        let base = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        guard let year else { return base.isEmpty ? type.label : base }
        return "\(year) \(base)"
    }

    var detail: String {
        [type.label, colorName, plate].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@Model
final class FamilyContact {
    var name: String
    var phone: String
    var relationship: String
    var createdAt: Date
    var profile: Profile?

    init(name: String, phone: String, relationship: String = "") {
        self.name = name
        self.phone = phone
        self.relationship = relationship
        self.createdAt = .now
    }
}

// MARK: - Trips

nonisolated enum TripPackStatus: String, Codable {
    case notDownloaded, downloading, ready, failed

    var label: String {
        switch self {
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading…"
        case .ready: "Ready for offline"
        case .failed: "Download failed"
        }
    }
}

@Model
final class Trip {
    var ownerID: String
    var origin: String
    var destination: String
    var startDate: Date
    var endDate: Date
    var createdAt: Date
    var isActive: Bool
    var startedAt: Date?
    var tripPackStatusRaw: String
    var tripPackUpdatedAt: Date?
    var tripPackSummary: String?
    /// Encoded `TripPack` so help along the route works with no signal.
    var tripPackData: Data?
    var originLatitude: Double?
    var originLongitude: Double?
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    var routeDistanceMeters: Double?
    var routeTravelSeconds: Double?

    init(ownerID: String, origin: String, destination: String, startDate: Date, endDate: Date) {
        self.ownerID = ownerID
        self.origin = origin
        self.destination = destination
        self.startDate = startDate
        self.endDate = endDate
        self.createdAt = .now
        self.isActive = false
        self.tripPackStatusRaw = TripPackStatus.notDownloaded.rawValue
    }

    var tripPackStatus: TripPackStatus {
        get { TripPackStatus(rawValue: tripPackStatusRaw) ?? .notDownloaded }
        set { tripPackStatusRaw = newValue.rawValue }
    }

    var routeLabel: String { "\(origin) → \(destination)" }

    var originCoordinate: CLLocationCoordinate2D? {
        guard let originLatitude, let originLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: originLatitude, longitude: originLongitude)
    }

    var destinationCoordinate: CLLocationCoordinate2D? {
        guard let destinationLatitude, let destinationLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: destinationLatitude, longitude: destinationLongitude)
    }

    var tripPack: TripPack? {
        tripPackData.flatMap { try? JSONDecoder().decode(TripPack.self, from: $0) }
    }

    var routeSummary: String? {
        guard let routeDistanceMeters, let routeTravelSeconds else { return nil }
        let miles = Measurement(value: routeDistanceMeters, unit: UnitLength.meters).converted(to: .miles)
        let time = Duration.seconds(routeTravelSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(miles.formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(0))))) · \(time)"
    }
}

// MARK: - Check-ins

nonisolated enum CheckInOutcome: String, Codable {
    /// Driver tapped "I'm OK" → conscious path.
    case ok
    /// Driver tapped "I need help" → 911 prompt + family alert + assistant.
    case needsHelp
    /// Countdown ran out → unconscious path, family alerted.
    case noResponse

    var label: String {
        switch self {
        case .ok: "You said you were OK"
        case .needsHelp: "You asked for help"
        case .noResponse: "No response — family alerted"
        }
    }

    var shortLabel: String {
        switch self {
        case .ok: "You were OK"
        case .needsHelp: "Asked for help"
        case .noResponse: "No response"
        }
    }

    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .needsHelp: "cross.case.fill"
        case .noResponse: "bell.badge.fill"
        }
    }
}

@Model
final class CheckInRecord {
    var ownerID: String
    var date: Date
    var outcomeRaw: String
    var wasSimulated: Bool

    init(ownerID: String, outcome: CheckInOutcome, wasSimulated: Bool, date: Date = .now) {
        self.ownerID = ownerID
        self.outcomeRaw = outcome.rawValue
        self.wasSimulated = wasSimulated
        self.date = date
    }

    var outcome: CheckInOutcome { CheckInOutcome(rawValue: outcomeRaw) ?? .ok }
}

// MARK: - Assistant

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    let date: Date = .now
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Profile.self, Vehicle.self, FamilyContact.self, Trip.self, CheckInRecord.self,
    ]

    /// Opens the on-device store. If a schema change can't be migrated (dev builds),
    /// the store is reset instead of crashing — it only holds this phone's demo data.
    static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return container
        }
        let url = config.url
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        return try! ModelContainer(for: schema, configurations: config)
    }
}
