import Foundation
import Testing
@testable import CrashDetectionCore

struct SpeedLimitTests {
    static func fixture(_ name: String) throws -> [RoadWay] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try RoadMatcher.decodeOverpass(Data(contentsOf: url))
    }

    @Test func parsesOpenStreetMapMaxspeedValues() {
        #expect(RoadMatcher.parseMPH("35 mph") == 35)
        #expect(RoadMatcher.parseMPH("50") == 31)        // km/h is the OSM default unit
        #expect(RoadMatcher.parseMPH("60 km/h") == 37)
        #expect(RoadMatcher.parseMPH("25 mph;35 mph") == 25)
        #expect(RoadMatcher.parseMPH("none") == nil)
        #expect(RoadMatcher.parseMPH("signals") == nil)
        #expect(RoadMatcher.parseMPH(nil) == nil)
    }

    @Test func realDowntownPortlandStreetIs20mph() throws {
        let ways = try Self.fixture("overpass_portland_downtown")
        #expect(ways.count == 112)
        // On SW Main Street, heading west (it's one-way westbound).
        let reading = try #require(RoadMatcher.match(lat: 45.5156735, lon: -122.677360, heading: 268, ways: ways))
        #expect(reading.mph == 20 && reading.isPosted)
        #expect(reading.roadName == "Southwest Main Street")
        #expect(reading.environment == .city)
    }

    @Test func realInterstate5IsAPosted50mphHighway() throws {
        let ways = try Self.fixture("overpass_portland_i5")
        // Northbound I-5 near the Rose Quarter, heading ~NW.
        let reading = try #require(RoadMatcher.match(lat: 45.54100, lon: -122.67178, heading: 321, ways: ways))
        #expect(reading.mph == 50 && reading.isPosted)
        #expect(reading.environment == .highway)
        #expect(reading.roadName?.contains("I 5") == true)
    }

    @Test func headingPicksTheRoadTheCarIsActuallyOn() {
        // A 25 mph street running north and a 45 mph road running east, crossing 12 m from the car.
        let north = RoadWay(id: 1, highway: "residential", maxspeed: "25 mph", oneway: nil, name: "North St",
                            points: [.init(lat: 45.5000, lon: -122.6000), .init(lat: 45.5020, lon: -122.6000)])
        let east = RoadWay(id: 2, highway: "primary", maxspeed: "45 mph", oneway: nil, name: "East Ave",
                           points: [.init(lat: 45.5011, lon: -122.6020), .init(lat: 45.5011, lon: -122.5980)])
        let car = (lat: 45.5010, lon: -122.60005)
        #expect(RoadMatcher.match(lat: car.lat, lon: car.lon, heading: 0, ways: [north, east])?.roadName == "North St")
        #expect(RoadMatcher.match(lat: car.lat, lon: car.lon, heading: 90, ways: [north, east])?.roadName == "East Ave")
        // Too far from any road: no guess.
        #expect(RoadMatcher.match(lat: 45.51, lon: -122.61, heading: 0, ways: [north, east]) == nil)
    }

    @Test func untaggedRoadsUseTypicalLimitsAndSayso() {
        let street = RoadWay(id: 3, highway: "residential", maxspeed: nil, oneway: nil, name: nil,
                             points: [.init(lat: 45.5, lon: -122.6), .init(lat: 45.501, lon: -122.6)])
        let reading = RoadMatcher.match(lat: 45.5005, lon: -122.6, heading: nil, ways: [street])
        #expect(reading?.mph == 25 && reading?.isPosted == false)
        // Direction-specific limits.
        var split = street
        split.maxspeedForward = "35 mph"
        split.maxspeedBackward = "25 mph"
        #expect(RoadMatcher.match(lat: 45.5005, lon: -122.6, heading: 0, ways: [split])?.mph == 35)
        #expect(RoadMatcher.match(lat: 45.5005, lon: -122.6, heading: 180, ways: [split])?.mph == 25)
    }
}
