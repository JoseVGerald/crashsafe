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

struct ValhallaTraceTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func realResponsesGiveThePostedLimit() throws {
        let i5 = try #require(try RoadMatcher.decodeValhallaTrace(Self.fixture("valhalla_i5_north")))
        #expect(i5.mph == 50 && i5.isPosted)            // 80 km/h in Valhalla = the "50 mph" OSM tag
        #expect(i5.environment == .highway && i5.roadName == "I 5 North")
        let main = try #require(try RoadMatcher.decodeValhallaTrace(Self.fixture("valhalla_sw_main_west")))
        #expect(main.mph == 20 && main.isPosted && main.environment == .city)
        #expect(main.roadName == "Southwest Main Street")
    }

    @Test func untaggedRoadsAreTypicalAndServiceRoadsAreNotGuessed() throws {
        func decode(_ edge: String, distance: Double = 4) throws -> SpeedLimitReading? {
            try RoadMatcher.decodeValhallaTrace(Data("""
            {"edges":[\(edge)],"matched_points":[{"type":"matched","edge_index":0,"distance_from_trace_point":\(distance)}]}
            """.utf8))
        }
        let residential = try #require(try decode(#"{"road_class":"residential","use":"road","names":["NE 7th Ave"],"way_id":1}"#))
        #expect(residential.mph == 25 && !residential.isPosted)
        let ramp = try #require(try decode(#"{"road_class":"motorway","use":"ramp","way_id":2}"#))
        #expect(ramp.mph == 35 && !ramp.isPosted && ramp.highway == "motorway_link")
        // Parking aisles have no posted limit but are labeled (10 mph typical, not posted).
        let lot = try decode(#"{"road_class":"service_other","use":"parking_aisle","way_id":3}"#)
        #expect(lot?.segment == .parkingLot && lot?.isPosted == false)
        #expect(try decode(#"{"road_class":"service_other","use":"road","way_id":6}"#) == nil) // other service roads: no guess
        #expect(try decode(#"{"road_class":"motorway","speed_limit":255,"way_id":4}"#)?.isPosted == false) // "no limit"
        #expect(try decode(#"{"road_class":"primary","speed_limit":56,"way_id":5}"#, distance: 80) == nil)  // too far to trust
        #expect(try RoadMatcher.decodeValhallaTrace(Data(#"{"edges":[],"matched_points":[{"type":"unmatched"}]}"#.utf8)) == nil)
    }
}

struct RoadSegmentTests {
    @Test func classifiesFinerRoadTypes() {
        #expect(RoadSegment.classify(highway: "motorway", mph: 60) == .interstate)
        #expect(RoadSegment.classify(highway: "motorway_link", mph: 35) == .ramp)
        #expect(RoadSegment.classify(highway: "residential", mph: 25, density: 15) == .residential)
        #expect(RoadSegment.classify(highway: "residential", mph: 45, density: 1) == .ruralRoad)
        #expect(RoadSegment.classify(highway: "primary", mph: 35, density: 12) == .arterial)
        #expect(RoadSegment.classify(highway: "primary", mph: 55, density: 2) == .ruralRoad)
        #expect(RoadSegment.classify(highway: "tertiary", mph: 20, density: 15) == .downtown)
        #expect(RoadSegment.classify(highway: "tertiary", mph: 35, density: 10, unpaved: true) == .gravelRoad)
        #expect(RoadSegment.classify(highway: "living_street", mph: 5) == .livingStreet)
        #expect(RoadSegment.residential.caution == .high && RoadSegment.interstate.caution == .normal)
        #expect(RoadSegment.residential.advice.contains("driveways"))
    }

    @Test func regionalDefaultsComeFromTheBundledTable() throws {
        let url = try #require(Bundle.module.url(forResource: "default_speeds", withExtension: "json", subdirectory: "Fixtures"))
        let defaults = try RoadDefaults(json: Data(contentsOf: url))
        #expect(defaults.regions.count > 200)
        #expect(defaults.typicalMPH(for: .residential, region: "US-OR") == 25)
        #expect(defaults.typicalMPH(for: .residential, region: "US-WA") == 25) // WA: urban default
        #expect(defaults.typicalMPH(for: .alley, region: "US-OR") == 15)
        #expect(defaults.typicalMPH(for: .livingStreet, region: "DE") == 5)  // walking pace
        #expect(defaults.typicalMPH(for: .ruralRoad, region: "DE") == 62)     // 100 km/h
        #expect(defaults.typicalMPH(for: .residential, region: nil) == nil)
    }

    @Test func valhallaDetailsBecomeSegmentAndFeatures() throws {
        let data = Data(#"{"edges":[{"road_class":"residential","use":"road","speed_limit":32,"density":15,"lane_count":1,"bridge":true,"unpaved":false,"names":["NE 19th Ave"],"way_id":9}],"matched_points":[{"type":"matched","edge_index":0,"distance_from_trace_point":3}]}"#.utf8)
        let r = try #require(try RoadMatcher.decodeValhallaTrace(data))
        #expect(r.segment == .residential && r.features.contains(.bridge) && r.mph == 20)
        let lot = Data(#"{"edges":[{"road_class":"service_other","use":"parking_aisle","way_id":3}],"matched_points":[{"type":"matched","edge_index":0,"distance_from_trace_point":2}]}"#.utf8)
        #expect(try RoadMatcher.decodeValhallaTrace(lot)?.segment == .parkingLot)
    }
}
