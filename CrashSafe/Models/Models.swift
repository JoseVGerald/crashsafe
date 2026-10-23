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

// MARK: About you (onboarding)
// Each answer changes how Pulse helps (who may be in the car after a crash, how to calm you, which
// guidance comes first), and together they pick the coaching style. Stored on the phone only.

nonisolated enum AgeBand: String, Codable, CaseIterable, Identifiable {
    case teen, young, adult, midlife, senior
    var id: String { rawValue }
    var label: String {
        switch self {
        case .teen: "16–19"
        case .young: "20–24"
        case .adult: "25–44"
        case .midlife: "45–64"
        case .senior: "65+"
        }
    }
}

nonisolated enum DrivingPurpose: String, Codable, CaseIterable, Identifiable {
    case commute, work, family, roadTrips
    var id: String { rawValue }
    var label: String {
        switch self {
        case .commute: "Commute or school"
        case .work: "Work or rideshare"
        case .family: "Errands and family"
        case .roadTrips: "Long road trips"
        }
    }
    var systemImage: String {
        switch self {
        case .commute: "building.2.fill"
        case .work: "briefcase.fill"
        case .family: "cart.fill"
        case .roadTrips: "road.lanes"
        }
    }
}

nonisolated enum UsualPassengers: String, Codable, CaseIterable, Identifiable {
    case alone, kids, adults
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alone: "Just me"
        case .kids: "Kids"
        case .adults: "Other adults"
        }
    }
    var systemImage: String {
        switch self {
        case .alone: "person.fill"
        case .kids: "figure.and.child.holdinghands"
        case .adults: "person.2.fill"
        }
    }
}

nonisolated enum DrivingFeeling: String, Codable, CaseIterable, Identifiable {
    case confident, okay, nervous
    var id: String { rawValue }
    var label: String {
        switch self {
        case .confident: "Confident"
        case .okay: "Mostly fine"
        case .nervous: "Nervous"
        }
    }
    var systemImage: String {
        switch self {
        case .confident: "hand.thumbsup.fill"
        case .okay: "face.smiling"
        case .nervous: "heart.text.square.fill"
        }
    }
}

nonisolated enum PastCrash: String, Codable, CaseIterable, Identifiable {
    case none, minor, serious
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Never"
        case .minor: "A minor one"
        case .serious: "A serious one"
        }
    }
    var systemImage: String {
        switch self {
        case .none: "checkmark.shield.fill"
        case .minor: "car.side.rear.and.collision.and.car.side.front"
        case .serious: "cross.case.fill"
        }
    }
}

nonisolated extension CoachingStyle {
    /// Picks the style from the About-you answers: people in the car, nerves and past crashes point to a calm,
    /// people-first nudge; building experience, driving for work and confidence point to the facts. Ties go to
    /// the facts. Returns the reasons that decided it, in plain words, so the choice is never a mystery.
    static func recommended(experience: DrivingExperience, passengers: UsualPassengers?, feeling: DrivingFeeling?,
                            pastCrash: PastCrash?, purpose: DrivingPurpose?) -> (style: CoachingStyle, reasons: [String]) {
        var heart: [(Int, String)] = [], facts: [(Int, String)] = []
        switch passengers {
        case .kids: heart.append((2, "kids ride with you"))
        case .adults: heart.append((1, "people often ride with you"))
        default: break
        }
        switch feeling {
        case .nervous: heart.append((2, "driving makes you nervous"))
        case .confident: facts.append((1, "you feel confident behind the wheel"))
        default: break
        }
        switch pastCrash {
        case .serious: heart.append((2, "you've been through a serious crash"))
        case .minor: heart.append((1, "you've been in a crash before"))
        default: break
        }
        switch purpose {
        case .work: facts.append((1, "you drive for work"))
        case .family: heart.append((1, "you drive for your family"))
        default: break
        }
        if experience == .learner || experience == .newDriver { facts.append((1, "you're still building experience")) }
        let heartScore = heart.reduce(0) { $0 + $1.0 }, factsScore = facts.reduce(0) { $0 + $1.0 }
        let (style, why) = heartScore > factsScore ? (CoachingStyle.emotional, heart) : (.logical, facts)
        return (style, why.sorted { $0.0 > $1.0 }.prefix(2).map(\.1))
    }
}

/// The big US auto insurers, for one-tap setup. The claims number is prefilled and can be edited;
/// it is the number each company lists for reporting an auto claim (check your insurance card).
nonisolated struct InsurerPreset: Identifiable, Hashable, Sendable {
    let name: String
    let claimsPhone: String
    var id: String { name }

    static let all: [InsurerPreset] = [
        .init(name: "State Farm", claimsPhone: "(800) 732-5246"),
        .init(name: "GEICO", claimsPhone: "(800) 841-3000"),
        .init(name: "Progressive", claimsPhone: "(800) 776-4737"),
        .init(name: "Allstate", claimsPhone: "(800) 255-7828"),
        .init(name: "USAA", claimsPhone: "(800) 531-8722"),
        .init(name: "Liberty Mutual", claimsPhone: "(800) 225-2467"),
        .init(name: "Farmers", claimsPhone: "(800) 435-7764"),
        .init(name: "Nationwide", claimsPhone: "(800) 421-3535"),
        .init(name: "Travelers", claimsPhone: "(800) 252-4633"),
        .init(name: "American Family", claimsPhone: "(800) 692-6326"),
    ]
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
    // About-you answers; empty until answered.
    var ageBandRaw: String = ""
    var drivingPurposeRaw: String = ""
    var passengersRaw: String = ""
    var drivingFeelingRaw: String = ""
    var pastCrashRaw: String = ""
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

    var ageBand: AgeBand? {
        get { AgeBand(rawValue: ageBandRaw) }
        set { ageBandRaw = newValue?.rawValue ?? "" }
    }
    var drivingPurpose: DrivingPurpose? {
        get { DrivingPurpose(rawValue: drivingPurposeRaw) }
        set { drivingPurposeRaw = newValue?.rawValue ?? "" }
    }
    var passengers: UsualPassengers? {
        get { UsualPassengers(rawValue: passengersRaw) }
        set { passengersRaw = newValue?.rawValue ?? "" }
    }
    var drivingFeeling: DrivingFeeling? {
        get { DrivingFeeling(rawValue: drivingFeelingRaw) }
        set { drivingFeelingRaw = newValue?.rawValue ?? "" }
    }
    var pastCrash: PastCrash? {
        get { PastCrash(rawValue: pastCrashRaw) }
        set { pastCrashRaw = newValue?.rawValue ?? "" }
    }

    /// The coaching style the About-you answers point to, with the reasons.
    var recommendedCoaching: (style: CoachingStyle, reasons: [String]) {
        CoachingStyle.recommended(experience: experience, passengers: passengers, feeling: drivingFeeling,
                                  pastCrash: pastCrash, purpose: drivingPurpose)
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

/// What the phone knew when the crash happened, kept with the check-in so the impact report can be opened
/// later (Home → last check-in). Stays on the phone.
nonisolated struct CrashSnapshot: Codable, Equatable, Sendable {
    var date: Date
    var peakG: Double
    var speedDropMPH: Double?
    var impact: ImpactReport?
    var latitude: Double?
    var longitude: Double?
    var accuracyMeters: Double?
    var street: String?
    var place: String?
    /// e.g. "Rain, 48°F, visibility 2 mi, dark".
    var weather: String?
    var isSimulated: Bool
}

@Model
final class CheckInRecord {
    var ownerID: String
    var date: Date
    var outcomeRaw: String
    var wasSimulated: Bool
    var snapshotData: Data?
    // Filled in by the driver on the impact report, for the police/insurer copy.
    var otherDriver: String = ""
    var otherInsurance: String = ""
    var otherPlate: String = ""
    var policeReportNumber: String = ""

    init(ownerID: String, outcome: CheckInOutcome, wasSimulated: Bool, date: Date = .now, snapshot: CrashSnapshot? = nil) {
        self.ownerID = ownerID
        self.outcomeRaw = outcome.rawValue
        self.wasSimulated = wasSimulated
        self.date = date
        self.snapshotData = snapshot.flatMap { try? JSONEncoder().encode($0) }
    }

    var outcome: CheckInOutcome { CheckInOutcome(rawValue: outcomeRaw) ?? .ok }
    var snapshot: CrashSnapshot? { snapshotData.flatMap { try? JSONDecoder().decode(CrashSnapshot.self, from: $0) } }
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
