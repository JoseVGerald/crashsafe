import CoreLocation
import Foundation
import Testing
@testable import CrashSafe

/// Counts calls from any thread (test helper).
nonisolated final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

nonisolated struct FakeQuickSource: QuickSpeedLimitSource {
    var reading: SpeedLimitReading?
    var delay: Duration = .milliseconds(50)
    var primary = false
    let calls = CallCounter()
    var isPrimary: Bool { primary }
    var label: String { primary ? "TomTom" : "quick lookup" }
    func speedLimit(along points: [(lat: Double, lon: Double)]) async throws -> SpeedLimitReading? {
        calls.increment()
        try await Task.sleep(for: delay)
        return reading
    }
}

nonisolated struct FakeRoadSource: RoadDataSource {
    var ways: [RoadWay]
    var delay: Duration
    var fails = false
    let calls = CallCounter()
    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        calls.increment()
        try await Task.sleep(for: delay)
        if fails { throw URLError(.timedOut) }
        return ways
    }
    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        try await roads(nearLat: 0, lon: 0, radiusMeters: radiusMeters)
    }
}

@MainActor
struct SpeedLimitServiceTests {
    static let street = RoadWay(id: 7, highway: "primary", maxspeed: "35 mph", name: "Broadway",
                                points: [.init(lat: 45.5000, lon: -122.6000), .init(lat: 45.5100, lon: -122.6000)])
    static let quickReading = SpeedLimitReading(mph: 30, isPosted: true, roadName: "Broadway", highway: "primary", wayID: 7, distanceMeters: 2)

    static func fix(_ lat: Double, _ t: Double = 1) -> LocationSample {
        LocationSample(uptime: ProcessInfo.processInfo.systemUptime, date: .now, latitude: lat, longitude: -122.6, horizontalAccuracy: 5,
                       speedMPS: 15, speedAccuracy: 0.5)
    }

    /// The point of the change: a limit within a second, while the area's road data takes its time.
    @Test func quickLookupShowsALimitBeforeTheRoadDataArrives() async throws {
        let quick = FakeQuickSource(reading: Self.quickReading)
        let area = FakeRoadSource(ways: [Self.street], delay: .seconds(1))
        let service = SpeedLimitService(source: area, quick: quick, store: nil)
        service.startDrive()
        service.observe(Self.fix(45.5050))
        #expect(service.current == nil && service.status == .loading)
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.current?.mph == 30)                  // from the quick lookup
        #expect(service.firstLimit?.basis == "quick lookup")
        #expect((service.firstLimit?.seconds ?? 9) < 1)
        try await Task.sleep(for: .seconds(1))
        service.observe(Self.fix(45.5051))
        #expect(service.current?.mph == 35)                  // road data took over
        #expect(quick.calls.count == 1 && area.calls.count == 1)
    }

    @Test func noQuickLookupWhereRoadDataIsAlreadyOnThePhone() async throws {
        let quick = FakeQuickSource(reading: Self.quickReading)
        let area = FakeRoadSource(ways: [Self.street], delay: .milliseconds(10))
        let service = SpeedLimitService(source: area, quick: quick, store: nil)
        service.prefetch(lat: 45.5050, lon: -122.6)          // what Home does when it learns the location
        try await Task.sleep(for: .milliseconds(200))
        service.startDrive()
        service.observe(Self.fix(45.5050))
        #expect(service.current?.mph == 35)
        #expect(service.firstLimit?.basis == "road data")
        #expect(quick.calls.count == 0 && area.calls.count == 1)
    }

    /// TomTom's trace match beats the local one-point OpenStreetMap match, even with road data on the phone.
    @Test func primarySourceWinsOverLocalRoadData() async throws {
        let quick = FakeQuickSource(reading: Self.quickReading, primary: true)
        let area = FakeRoadSource(ways: [Self.street], delay: .milliseconds(10))
        let service = SpeedLimitService(source: area, quick: quick, store: nil)
        service.prefetch(lat: 45.5050, lon: -122.6)
        try await Task.sleep(for: .milliseconds(200))
        service.startDrive()
        service.observe(Self.fix(45.5050))
        #expect(service.current?.mph == 35)                  // road data until TomTom answers
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.current?.mph == 30 && service.current?.isPosted == true)
        service.observe(Self.fix(45.5051))
        #expect(service.current?.mph == 30)                  // and it stays the source
        #expect(quick.calls.count == 1)
    }

    @Test func fallbackQuickSourceMovesOnOnlyWhenOneFails() async throws {
        struct Broken: QuickSpeedLimitSource {
            var isPrimary: Bool { true }
            func speedLimit(along points: [(lat: Double, lon: Double)]) async throws -> SpeedLimitReading? { throw URLError(.timedOut) }
        }
        let backup = FakeQuickSource(reading: Self.quickReading, delay: .zero)
        let chain = FallbackQuickSource(sources: [Broken(), backup])
        #expect(chain.isPrimary)
        #expect(try await chain.speedLimit(along: [(45.5, -122.6)])?.mph == 30)
        let noRoad = FakeQuickSource(reading: nil, delay: .zero)
        #expect(try await FallbackQuickSource(sources: [noRoad, backup]).speedLimit(along: [(45.5, -122.6)]) == nil)
        #expect(backup.calls.count == 1)
    }

    @Test func quickLookupsAreThrottled() async throws {
        let quick = FakeQuickSource(reading: Self.quickReading)
        let area = FakeRoadSource(ways: [], delay: .seconds(5), fails: true)
        let service = SpeedLimitService(source: area, quick: quick, store: nil)
        service.startDrive()
        for i in 0..<10 { service.observe(Self.fix(45.5050 + Double(i) * 0.0001)) }  // 10 fixes, ~100 m
        try await Task.sleep(for: .milliseconds(300))
        for i in 10..<15 { service.observe(Self.fix(45.5050 + Double(i) * 0.0001)) }
        #expect(quick.calls.count == 1)                      // one in flight, then spaced out
        #expect(service.current?.mph == 30)
    }

    @Test func racingTakesTheFirstServerToAnswer() async throws {
        let slow = FakeRoadSource(ways: [Self.street], delay: .seconds(3))
        let fast = FakeRoadSource(ways: [Self.street], delay: .milliseconds(50))
        let broken = FakeRoadSource(ways: [], delay: .milliseconds(10), fails: true)
        let started = ContinuousClock.now
        let ways = try await RacingRoadSource(sources: [slow, broken, fast]).roads(nearLat: 45.5, lon: -122.6, radiusMeters: 500)
        #expect(ways.count == 1)
        #expect(ContinuousClock.now - started < .seconds(1))
        await #expect(throws: (any Error).self) {
            _ = try await RacingRoadSource(sources: [broken, broken]).roads(nearLat: 45.5, lon: -122.6, radiusMeters: 500)
        }
        let empty = FakeRoadSource(ways: [], delay: .milliseconds(10))
        #expect(try await RacingRoadSource(sources: [empty, broken]).roads(nearLat: 45.5, lon: -122.6, radiusMeters: 500).isEmpty)
    }
}

@MainActor
struct AreaCoachingTests {
    @Test func residentialStreetsGetASpokenExtraCareWarning() {
        var snapshot = DrivingSnapshot(speedLimitMPH: 25, environment: .city)
        snapshot.speedMPH = 22
        snapshot.roadSegment = .residential
        let message = CoachingEngine.areaCaution(snapshot)
        #expect(message?.title == "Residential area: be extra careful")
        #expect(message?.speaksAloud == true && message?.repeatAfter == 300)
        snapshot.roadSegment = .interstate
        #expect(CoachingEngine.areaCaution(snapshot) == nil)
    }
}
