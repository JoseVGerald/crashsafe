package org.cac.crashsafe.core

import org.cac.crashsafe.core.roads.RoadDefaults
import org.cac.crashsafe.core.roads.RoadFeatures
import org.cac.crashsafe.core.roads.RoadKind
import org.cac.crashsafe.core.roads.RoadMatcher
import org.cac.crashsafe.core.roads.RoadSegment
import org.cac.crashsafe.core.roads.RoadWay
import org.cac.crashsafe.core.roads.SpeedLimitReading
import org.cac.crashsafe.core.sensors.LocationSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeedLimitTest {
    private fun fixture(name: String): List<RoadWay> = RoadMatcher.decodeOverpass(Fixtures.text("$name.json"))

    @Test fun parsesOpenStreetMapMaxspeedValues() {
        assertEquals(35.0, RoadMatcher.parseMPH("35 mph"))
        assertEquals(31.0, RoadMatcher.parseMPH("50"))        // km/h is the OSM default unit
        assertEquals(37.0, RoadMatcher.parseMPH("60 km/h"))
        assertEquals(25.0, RoadMatcher.parseMPH("25 mph;35 mph"))
        assertNull(RoadMatcher.parseMPH("none"))
        assertNull(RoadMatcher.parseMPH("signals"))
        assertNull(RoadMatcher.parseMPH(null))
    }

    @Test fun realDowntownPortlandStreetIs20mph() {
        val ways = fixture("overpass_portland_downtown")
        assertEquals(112, ways.size)
        // On SW Main Street, heading west (it's one-way westbound).
        val reading = RoadMatcher.match(45.5156735, -122.677360, 268.0, ways)!!
        assertTrue(reading.mph == 20.0 && reading.isPosted)
        assertEquals("Southwest Main Street", reading.roadName)
        assertEquals(RoadKind.city, reading.environment)
    }

    @Test fun realInterstate5IsAPosted50mphHighway() {
        val ways = fixture("overpass_portland_i5")
        // Northbound I-5 near the Rose Quarter, heading ~NW.
        val reading = RoadMatcher.match(45.54100, -122.67178, 321.0, ways)!!
        assertTrue(reading.mph == 50.0 && reading.isPosted)
        assertEquals(RoadKind.highway, reading.environment)
        assertTrue(reading.roadName?.contains("I 5") == true)
    }

    @Test fun headingPicksTheRoadTheCarIsActuallyOn() {
        // A 25 mph street running north and a 45 mph road running east, crossing 12 m from the car.
        val north = RoadWay(id = 1, highway = "residential", maxspeed = "25 mph", name = "North St",
            points = listOf(RoadWay.Point(45.5000, -122.6000), RoadWay.Point(45.5020, -122.6000)))
        val east = RoadWay(id = 2, highway = "primary", maxspeed = "45 mph", name = "East Ave",
            points = listOf(RoadWay.Point(45.5011, -122.6020), RoadWay.Point(45.5011, -122.5980)))
        assertEquals("North St", RoadMatcher.match(45.5010, -122.60005, 0.0, listOf(north, east))?.roadName)
        assertEquals("East Ave", RoadMatcher.match(45.5010, -122.60005, 90.0, listOf(north, east))?.roadName)
        // Too far from any road: no guess.
        assertNull(RoadMatcher.match(45.51, -122.61, 0.0, listOf(north, east)))
    }

    @Test fun untaggedRoadsUseTypicalLimitsAndSaySo() {
        val street = RoadWay(id = 3, highway = "residential",
            points = listOf(RoadWay.Point(45.5, -122.6), RoadWay.Point(45.501, -122.6)))
        val reading = RoadMatcher.match(45.5005, -122.6, null, listOf(street))
        assertTrue(reading?.mph == 25.0 && reading.isPosted == false)
        // Direction-specific limits.
        val split = street.copy(maxspeedForward = "35 mph", maxspeedBackward = "25 mph")
        assertEquals(35.0, RoadMatcher.match(45.5005, -122.6, 0.0, listOf(split))?.mph)
        assertEquals(25.0, RoadMatcher.match(45.5005, -122.6, 180.0, listOf(split))?.mph)
    }
}

class ValhallaTraceTest {
    @Test fun realResponsesGiveThePostedLimit() {
        val i5 = RoadMatcher.decodeValhallaTrace(Fixtures.text("valhalla_i5_north.json"))!!
        assertTrue(i5.mph == 50.0 && i5.isPosted)            // 80 km/h in Valhalla = the "50 mph" OSM tag
        assertTrue(i5.environment == RoadKind.highway && i5.roadName == "I 5 North")
        val main = RoadMatcher.decodeValhallaTrace(Fixtures.text("valhalla_sw_main_west.json"))!!
        assertTrue(main.mph == 20.0 && main.isPosted && main.environment == RoadKind.city)
        assertEquals("Southwest Main Street", main.roadName)
    }

    private fun decode(edge: String, distance: Double = 4.0): SpeedLimitReading? = RoadMatcher.decodeValhallaTrace(
        """{"edges":[$edge],"matched_points":[{"type":"matched","edge_index":0,"distance_from_trace_point":$distance}]}""")

    @Test fun untaggedRoadsAreTypicalAndServiceRoadsAreNotGuessed() {
        val residential = decode("""{"road_class":"residential","use":"road","names":["NE 7th Ave"],"way_id":1}""")!!
        assertTrue(residential.mph == 25.0 && !residential.isPosted)
        val ramp = decode("""{"road_class":"motorway","use":"ramp","way_id":2}""")!!
        assertTrue(ramp.mph == 35.0 && !ramp.isPosted && ramp.highway == "motorway_link")
        // Parking aisles have no posted limit but are labeled (10 mph typical, not posted).
        val lot = decode("""{"road_class":"service_other","use":"parking_aisle","way_id":3}""")
        assertTrue(lot?.segment == RoadSegment.parkingLot && lot.isPosted == false)
        assertNull(decode("""{"road_class":"service_other","use":"road","way_id":6}""")) // other service roads: no guess
        assertEquals(false, decode("""{"road_class":"motorway","speed_limit":255,"way_id":4}""")?.isPosted) // "no limit"
        assertNull(decode("""{"road_class":"primary","speed_limit":56,"way_id":5}""", distance = 80.0))  // too far to trust
        assertNull(RoadMatcher.decodeValhallaTrace("""{"edges":[],"matched_points":[{"type":"unmatched"}]}"""))
    }
}

class TomTomSnapTest {
    private fun decode(properties: String, snap: String = "Matched"): SpeedLimitReading? = RoadMatcher.decodeTomTomSnap(
        """{"route":[{"properties":$properties}],
         "projectedPoints":[{"geometry":{"coordinates":[-122.6,45.5]},"properties":{"routeIndex":0,"snapResult":"$snap"}}]}""",
        lastPoint = 45.5 to -122.6)

    @Test fun theTraceMatchWinsOverTheCloserFrontageRoad() {
        val json = Fixtures.text("tomtom_snap_freeway.json")
        val reading = RoadMatcher.decodeTomTomSnap(json, lastPoint = 45.54102 to -122.67180)!!
        assertTrue(reading.mph == 50.0 && reading.isPosted)
        assertTrue(reading.roadName == "I-5 N" && reading.highway == "motorway" && reading.environment == RoadKind.highway)
        assertTrue(reading.segment == RoadSegment.interstate && reading.distanceMeters < 5)
        // Too far from where the car really is: not trusted.
        assertNull(RoadMatcher.decodeTomTomSnap(json, lastPoint = 45.5420 to -122.6718))
    }

    @Test fun unitsRoadClassesAndMissingLimits() {
        assertEquals(50.0, decode("""{"speedLimits":{"value":80,"unit":"kmph","type":"Maximum"},"frc":2}""")?.mph)
        val untagged = decode("""{"frc":6,"address":{"roadName":"NE 7th Ave"}}""")!!
        assertTrue(untagged.mph == 25.0 && !untagged.isPosted && untagged.highway == "residential")
        // An advisory speed (ramp curves) isn't the legal limit.
        val ramp = decode("""{"speedLimits":{"value":25,"unit":"mph","type":"Recommended"},"frc":0,"roadUse":"Ramp"}""")!!
        assertTrue(ramp.highway == "motorway_link" && !ramp.isPosted && ramp.mph == 35.0)
        val lot = decode("""{"frc":7,"formOfWay":"ETAParkingArea"}""")
        assertTrue(lot?.segment == RoadSegment.parkingLot && lot.mph == 10.0)
        val rural = decode("""{"speedLimits":{"value":55,"unit":"mph","type":"Maximum"},"frc":2,"urbanArea":false}""")
        assertEquals(RoadSegment.ruralRoad, rural?.segment)
        assertEquals(RoadFeatures.tunnel + RoadFeatures.roundabout, decode("""{"frc":3,"partOfTunnel":true,"formOfWay":"Roundabout"}""")?.features)
        assertNull(decode("""{"frc":2}""", snap = "OffRoad"))
        assertTrue(RoadMatcher.stableID("abc") == RoadMatcher.stableID("abc") && RoadMatcher.stableID("abc") != RoadMatcher.stableID("abd"))
    }
}

class RoadSegmentTest {
    @Test fun classifiesFinerRoadTypes() {
        assertEquals(RoadSegment.interstate, RoadSegment.classify("motorway", 60.0))
        assertEquals(RoadSegment.ramp, RoadSegment.classify("motorway_link", 35.0))
        assertEquals(RoadSegment.residential, RoadSegment.classify("residential", 25.0, density = 15))
        assertEquals(RoadSegment.ruralRoad, RoadSegment.classify("residential", 45.0, density = 1))
        assertEquals(RoadSegment.arterial, RoadSegment.classify("primary", 35.0, density = 12))
        assertEquals(RoadSegment.ruralRoad, RoadSegment.classify("primary", 55.0, density = 2))
        assertEquals(RoadSegment.downtown, RoadSegment.classify("tertiary", 20.0, density = 15))
        assertEquals(RoadSegment.gravelRoad, RoadSegment.classify("tertiary", 35.0, density = 10, unpaved = true))
        assertEquals(RoadSegment.livingStreet, RoadSegment.classify("living_street", 5.0))
        assertTrue(RoadSegment.residential.caution == RoadSegment.Caution.high && RoadSegment.interstate.caution == RoadSegment.Caution.normal)
        assertTrue(RoadSegment.residential.advice.contains("driveways"))
    }

    @Test fun regionalDefaultsComeFromTheBundledTable() {
        val defaults = RoadDefaults.fromJson(Fixtures.text("default_speeds.json"))
        assertTrue(defaults.regions.size > 200)
        assertEquals(25.0, defaults.typicalMPH(RoadSegment.residential, "US-OR"))
        assertEquals(25.0, defaults.typicalMPH(RoadSegment.residential, "US-WA")) // WA: urban default
        assertEquals(15.0, defaults.typicalMPH(RoadSegment.alley, "US-OR"))
        assertEquals(5.0, defaults.typicalMPH(RoadSegment.livingStreet, "DE"))  // walking pace
        assertEquals(62.0, defaults.typicalMPH(RoadSegment.ruralRoad, "DE"))     // 100 km/h
        assertNull(defaults.typicalMPH(RoadSegment.residential, null))
    }

    @Test fun valhallaDetailsBecomeSegmentAndFeatures() {
        val r = RoadMatcher.decodeValhallaTrace("""{"edges":[{"road_class":"residential","use":"road","speed_limit":32,"density":15,"lane_count":1,"bridge":true,"unpaved":false,"names":["NE 19th Ave"],"way_id":9}],"matched_points":[{"type":"matched","edge_index":0,"distance_from_trace_point":3}]}""")!!
        assertTrue(r.segment == RoadSegment.residential && RoadFeatures.bridge in r.features && r.mph == 20.0)
        val lot = """{"edges":[{"road_class":"service_other","use":"parking_aisle","way_id":3}],"matched_points":[{"type":"matched","edge_index":0,"distance_from_trace_point":2}]}"""
        assertEquals(RoadSegment.parkingLot, RoadMatcher.decodeValhallaTrace(lot)?.segment)
    }
}

class SensorTypesTest {
    @Test fun staleFutureAndInaccurateGpsCannotCorroborateImpact() {
        var fix = LocationSample(uptime = 10.0, date = 0.0, latitude = 47.0, longitude = -122.0,
            horizontalAccuracy = 5.0, speedMPS = 20.0, speedAccuracy = 1.0)
        assertTrue(fix.hasReliableSpeed(11.0))
        assertFalse(fix.hasReliableSpeed(13.0))
        assertFalse(fix.hasReliableSpeed(9.0))
        fix = fix.copy(speedAccuracy = -1.0)
        assertFalse(fix.hasReliableSpeed(11.0))
        fix = fix.copy(speedAccuracy = 10.0)
        assertFalse(fix.hasReliableSpeed(11.0))
        assertFalse(fix.copy(latitude = Double.NaN).isValid)
    }
}
