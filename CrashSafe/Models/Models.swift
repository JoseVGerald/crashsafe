import Foundation
import SwiftData

// MARK: - Auth

/// The signed-in account, independent of which AuthService produced it.
struct AuthUser: Codable, Equatable, Sendable {
    let id: String
    var name: String
    var email: String
}

// MARK: - Profile

enum CarType: String, Codable, CaseIterable, Identifiable {
    case sedan, suv, truck, minivan, hatchback, coupe, motorcycle, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sedan: "Sedan"
        case .suv: "SUV"
        case .truck: "Truck"
        case .minivan: "Minivan"
        case .hatchback: "Hatchback"
        case .coupe: "Coupe"
        case .motorcycle: "Motorcycle"
        case .other: "Other"
        }
    }
}

/// One per user. Stored on-device only.
@Model
final class Profile {
    @Attribute(.unique) var ownerID: String
    var medicalNotes: String
    var carMake: String
    var carModel: String
    var carTypeRaw: String
    var insurer: String
    var policyNumber: String
    @Relationship(deleteRule: .cascade, inverse: \FamilyContact.profile)
    var familyContacts: [FamilyContact] = []

    init(ownerID: String,
         medicalNotes: String = "",
         carMake: String = "",
         carModel: String = "",
         carType: CarType = .sedan,
         insurer: String = "",
         policyNumber: String = "") {
        self.ownerID = ownerID
        self.medicalNotes = medicalNotes
        self.carMake = carMake
        self.carModel = carModel
        self.carTypeRaw = carType.rawValue
        self.insurer = insurer
        self.policyNumber = policyNumber
    }

    var carType: CarType {
        get { CarType(rawValue: carTypeRaw) ?? .other }
        set { carTypeRaw = newValue.rawValue }
    }

    var sortedContacts: [FamilyContact] {
        familyContacts.sorted { $0.createdAt < $1.createdAt }
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

enum TripPackStatus: String, Codable {
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
}

// MARK: - Check-ins

enum CheckInOutcome: String, Codable {
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
    static let models: [any PersistentModel.Type] = [Profile.self, FamilyContact.self, Trip.self, CheckInRecord.self]
}
