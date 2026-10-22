import Foundation

/// One road from OpenStreetMap (the free data CrashSafe uses for speed limits: Apple Maps doesn't
/// give apps speed limits). Built from an Overpass `way … out tags geom` response.
nonisolated struct RoadWay: Codable, Equatable, Sendable {
    nonisolated struct Point: Codable, Equatable, Sendable {
        var lat: Double
        var lon: Double
    }

    var id: Int64
    var highway: String
    var maxspeed: String?
    var maxspeedForward: String?
    var maxspeedBackward: String?
    var oneway: String?
    var name: String?
    var ref: String?
    var points: [Point]

    init(id: Int64, highway: String, maxspeed: String? = nil, maxspeedForward: String? = nil,
         maxspeedBackward: String? = nil, oneway: String? = nil, name: String? = nil, ref: String? = nil,
         points: [Point]) {
        self.id = id; self.highway = highway; self.maxspeed = maxspeed; self.maxspeedForward = maxspeedForward
        self.maxspeedBackward = maxspeedBackward; self.oneway = oneway; self.name = name; self.ref = ref
        self.points = points
    }

    var isOneway: Bool { ["yes", "true", "1", "-1"].contains(oneway ?? "") || highway == "motorway" }
    var displayName: String? { name ?? ref?.replacingOccurrences(of: ";", with: " / ") }
}

/// The speed limit where the car is, and how sure we are of it.
nonisolated struct SpeedLimitReading: Codable, Equatable, Sendable {
    var mph: Double
    /// True when the road is tagged with a posted limit; false for a typical limit for that kind of road.
    var isPosted: Bool
    var roadName: String?
    var highway: String
    var wayID: Int64
    var distanceMeters: Double
    /// What kind of road this is, in finer detail (residential, arterial, ramp, gravel…).
    var segment: RoadSegment? = nil
    /// Road features worth a word of caution.
    var features: RoadFeatures = []

    var environment: RoadKind { RoadKind(highway: highway, mph: mph) }
    /// The finest description available.
    var resolvedSegment: RoadSegment { segment ?? RoadSegment.classify(highway: highway, mph: mph) }
}

/// Things about the road the car is on that change how carefully to drive.
nonisolated struct RoadFeatures: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    static let bridge = RoadFeatures(rawValue: 1)
    static let tunnel = RoadFeatures(rawValue: 2)
    static let unpaved = RoadFeatures(rawValue: 4)
    static let roundabout = RoadFeatures(rawValue: 8)
    static let singleLane = RoadFeatures(rawValue: 16)

    var labels: [String] {
        [(Self.bridge, "bridge"), (.tunnel, "tunnel"), (.unpaved, "gravel"), (.roundabout, "roundabout"), (.singleLane, "one lane")]
            .compactMap { contains($0.0) ? $0.1 : nil }
    }
}

/// Finer road types than city / highway / rural, each with how careful to be and why.
nonisolated enum RoadSegment: String, Codable, CaseIterable, Sendable {
    case interstate, ramp, expressway, arterial, collector, localConnector, downtown, residential
    case livingStreet, alley, parkingLot, ruralRoad, gravelRoad

    nonisolated enum Caution: Int, Comparable, Sendable {
        case normal, elevated, high
        static func < (a: Caution, b: Caution) -> Bool { a.rawValue < b.rawValue }
    }

    var title: String {
        switch self {
        case .interstate: "Interstate / freeway"
        case .ramp: "Highway ramp"
        case .expressway: "Expressway"
        case .arterial: "Arterial road"
        case .collector: "Collector street"
        case .localConnector: "Neighborhood connector"
        case .downtown: "Downtown street"
        case .residential: "Residential street"
        case .livingStreet: "Shared street"
        case .alley: "Alley / service road"
        case .parkingLot: "Parking lot"
        case .ruralRoad: "Rural road"
        case .gravelRoad: "Gravel road"
        }
    }

    var caution: Caution {
        switch self {
        case .residential, .livingStreet, .alley, .parkingLot, .gravelRoad, .downtown: .high
        case .ramp, .arterial, .collector, .localConnector, .ruralRoad: .elevated
        case .interstate, .expressway: .normal
        }
    }

    /// One line of advice, said when the car enters this kind of road.
    var advice: String {
        switch self {
        case .residential: "Kids, pets and cars backing out of driveways can appear between parked cars. Go slow and cover the brake."
        case .livingStreet: "Shared street: people walk in the road here. Go at walking pace."
        case .alley: "Alley: blind corners and garages. Creep through."
        case .parkingLot: "Parking lot: cars back out without seeing you and people walk between them."
        case .downtown: "Downtown: crosswalks, cyclists and car doors opening. Cover the brake."
        case .gravelRoad: "Gravel road: stopping takes much longer. Slow down before curves."
        case .ruralRoad: "Rural road: sharp curves, no shoulder, and deer at dusk."
        case .ramp: "Ramp: match the curve's speed and check your blind spot before merging."
        case .arterial: "Busy arterial: watch for cars turning across your lane."
        case .collector: "Collector street: driveways and bus stops. Watch for pedestrians."
        case .localConnector: "Neighborhood road: crosswalks and bikes. Keep it easy."
        case .interstate: "Freeway: keep three seconds of space and merge smoothly."
        case .expressway: "Expressway: watch for cross traffic at intersections."
        }
    }

    /// The `default_speeds.json` categories to look for, most specific first.
    var defaultCategories: [String] {
        switch self {
        case .interstate: ["motorway", "expressway", "rural", "default"]
        case .expressway: ["expressway", "rural", "default"]
        case .residential: ["residential", "urban"]
        case .livingStreet: ["livingStreet", "residential", "urban"]
        case .alley, .parkingLot: ["alley", "residential", "urban"]
        case .downtown: ["business", "urban"]
        case .ruralRoad, .gravelRoad: ["rural", "default"]
        case .ramp: []
        case .arterial, .collector, .localConnector: ["urban"]
        }
    }

    /// From the OpenStreetMap road class, how built-up the area is (Valhalla's 0–15 density, when
    /// known), surface, and the limit.
    static func classify(highway: String, mph: Double?, density: Int? = nil, unpaved: Bool = false) -> RoadSegment {
        let rural = density.map { $0 <= 3 }
        if unpaved && !highway.hasPrefix("motorway") && !highway.hasPrefix("trunk") { return .gravelRoad }
        switch highway {
        case "motorway": return .interstate
        case let h where h.hasSuffix("_link"): return .ramp
        case "trunk": return rural == false || (mph ?? 0) >= 50 ? .expressway : .arterial
        case "primary": return rural == true ? .ruralRoad : .arterial
        case "secondary": return rural == true ? .ruralRoad : ((density ?? 0) >= 14 && (mph ?? 99) <= 25 ? .downtown : .collector)
        case "tertiary": return rural == true ? .ruralRoad : ((density ?? 0) >= 14 && (mph ?? 99) <= 25 ? .downtown : .localConnector)
        case "unclassified": return rural == true || (mph ?? 0) >= 40 ? .ruralRoad : .localConnector
        case "residential": return rural == true && (mph ?? 0) >= 35 ? .ruralRoad : .residential
        case "living_street": return .livingStreet
        case "service": return .alley
        case "parking_aisle": return .parkingLot
        default: return .localConnector
        }
    }
}

/// Legal default speed limits by region (`default_speeds.json`, built from osm-legal-default-speeds):
/// the limit for an untagged road where the car actually is, e.g. 25 mph on an Oregon residential street.
nonisolated struct RoadDefaults: Sendable {
    let regions: [String: [String: Double]]

    init(json: Data) throws {
        struct File: Decodable { var regions: [String: [String: Double]] }
        regions = try JSONDecoder().decode(File.self, from: json).regions
    }

    init(regions: [String: [String: Double]]) { self.regions = regions }

    /// `region` like "US-OR" (falls back to the country, "US").
    func typicalMPH(for segment: RoadSegment, region: String?) -> Double? {
        guard let region else { return nil }
        let codes = [region, String(region.prefix { $0 != "-" })]
        for code in codes {
            guard let row = regions[code] else { continue }
            for category in segment.defaultCategories {
                if let mph = row[category] { return mph }
            }
        }
        return nil
    }
}

/// What kind of road this is, for coaching ("city street", "highway", "rural road").
nonisolated enum RoadKind: String, Codable, Sendable {
    case city, highway, rural

    init(highway: String, mph: Double) {
        if highway.hasPrefix("motorway") || highway.hasPrefix("trunk") {
            self = .highway
        } else if highway == "unclassified" && mph >= 40 {
            self = .rural
        } else {
            self = .city
        }
    }
}

nonisolated enum RoadMatcher {
    /// Driveable road classes, in the Overpass regex the service queries.
    static let highwayPattern = "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$"

    /// Typical US limits when a road has no posted `maxspeed` tag (Washington's statutory defaults are
    /// 25 mph on city streets, 50 on county roads, 60 on state highways; RCW 46.61.400).
    static func typicalLimitMPH(for highway: String) -> Double? {
        switch highway {
        case "motorway": 60
        case "trunk": 55
        case "primary": 40
        case "secondary": 35
        case "tertiary": 30
        case "unclassified": 35
        case "residential": 25
        case "living_street": 15
        case "motorway_link", "trunk_link": 35
        case "primary_link", "secondary_link", "tertiary_link": 25
        default: nil
        }
    }

    /// OpenStreetMap `maxspeed` values: "35 mph", "50" (km/h by default), "60 km/h", "none", "signals"…
    static func parseMPH(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let first = raw.split(separator: ";").first.map(String.init) ?? raw
        let number = first.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value > 0, value < 200 else { return nil }
        if first.contains("mph") { return value }
        if first.contains("knots") { return value * 1.15078 }
        return (value * 0.621371).rounded() // km/h
    }

    /// The posted limit for travel along `bearing` (direction-specific tags first).
    static func postedMPH(_ way: RoadWay, forward: Bool) -> Double? {
        parseMPH(forward ? way.maxspeedForward : way.maxspeedBackward) ?? parseMPH(way.maxspeed)
    }

    /// Picks the road the car is on: the nearest one, preferring roads that run the way the car is heading.
    /// - Parameters:
    ///   - heading: direction of travel in degrees (0 = north), if known.
    ///   - maxDistance: GPS is usually within ~10 m; beyond this we don't guess.
    static func match(lat: Double, lon: Double, heading: Double?, ways: [RoadWay],
                      maxDistance: Double = 35) -> SpeedLimitReading? {
        var best: (score: Double, reading: SpeedLimitReading)?
        for way in ways where way.points.count >= 2 {
            guard let (distance, segmentBearing) = nearest(lat: lat, lon: lon, on: way.points), distance <= maxDistance else { continue }
            var forward = true
            var anglePenalty = 0.0
            if let heading {
                let diff = angleDifference(heading, segmentBearing)
                forward = diff <= 90
                // Two-way roads match either direction; one-way roads only their own.
                let alignment = way.isOneway ? diff : min(diff, 180 - diff)
                anglePenalty = alignment > 60 ? 60 : alignment * 0.4
            }
            let posted = postedMPH(way, forward: forward)
            guard let mph = posted ?? typicalLimitMPH(for: way.highway) else { continue }
            let score = distance + anglePenalty
            if best == nil || score < best!.score {
                best = (score, SpeedLimitReading(mph: mph, isPosted: posted != nil, roadName: way.displayName,
                                                 highway: way.highway, wayID: way.id, distanceMeters: distance))
            }
        }
        return best?.reading
    }

    /// Distance (m) from the point to the polyline, and the bearing (degrees) of the closest segment.
    static func nearest(lat: Double, lon: Double, on points: [RoadWay.Point]) -> (Double, Double)? {
        let mPerLat = 111_320.0, mPerLon = 111_320.0 * cos(lat * .pi / 180)
        var best: (Double, Double)?
        for (a, b) in zip(points, points.dropFirst()) {
            let ax = (a.lon - lon) * mPerLon, ay = (a.lat - lat) * mPerLat
            let bx = (b.lon - lon) * mPerLon, by = (b.lat - lat) * mPerLat
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(max(-(ax * dx + ay * dy) / len2, 0), 1) : 0
            let px = ax + t * dx, py = ay + t * dy
            let distance = (px * px + py * py).squareRoot()
            let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            if best == nil || distance < best!.0 { best = (distance, bearing) }
        }
        return best
    }

    /// Initial bearing from one fix to the next, degrees (0 = north).
    static func bearing(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// RoadKind-style highway tag for a Valhalla road class (`motorway`, `residential`, …; ramps are links).
    static func highway(valhallaClass roadClass: String?, use: String?) -> String? {
        guard let roadClass else { return nil }
        if use == "living_street" { return "living_street" }
        let known = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential"]
        guard known.contains(roadClass) else { return use == "ramp" ? "primary_link" : nil }
        if use == "ramp", ["motorway", "trunk", "primary", "secondary", "tertiary"].contains(roadClass) { return roadClass + "_link" }
        return roadClass
    }

    /// Parses Valhalla's `trace_attributes` (the OpenStreetMap community's routing server): the road the
    /// last point of a short GPS trace matched, with its posted limit. Valhalla reports `speed_limit` in
    /// km/h only where the road has a posted `maxspeed` tag, so a missing value falls back to the typical
    /// limit for the road class, marked not posted.
    static func decodeValhallaTrace(_ data: Data, maxDistance: Double = 35) throws -> SpeedLimitReading? {
        struct Response: Decodable {
            struct Edge: Decodable {
                var speed_limit: Double?
                var names: [String]?
                var way_id: Int64?
                var road_class: String?
                var use: String?
                var density: Int?
                var lane_count: Int?
                var bridge: Bool?
                var tunnel: Bool?
                var unpaved: Bool?
                var roundabout: Bool?
            }
            struct Matched: Decodable {
                var type: String?
                var edge_index: Int?
                var distance_from_trace_point: Double?
            }
            var edges: [Edge]?
            var matched_points: [Matched]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let edges = response.edges ?? []
        guard let point = response.matched_points?.last(where: { $0.type == "matched" && ($0.edge_index ?? -1) < edges.count && ($0.edge_index ?? -1) >= 0 }),
              let index = point.edge_index else { return nil }
        let distance = point.distance_from_trace_point ?? 0
        guard distance <= maxDistance else { return nil }
        let edge = edges[index]
        let highway = highway(valhallaClass: edge.road_class, use: edge.use)
        // 255 means "no limit" in Valhalla; 0 or missing means none posted.
        let posted = edge.speed_limit.flatMap { $0 > 0 && $0 < 250 ? ($0 * 0.621371).rounded() : nil }
        // No posted limit on a service road or parking aisle: don't guess one.
        let lot = ["parking_aisle", "driveway", "alley", "drive_through"].contains(edge.use ?? "")
        guard let mph = posted ?? highway.flatMap(typicalLimitMPH(for:)) ?? (lot ? 10 : nil) else { return nil }
        var features: RoadFeatures = []
        if edge.bridge == true { features.insert(.bridge) }
        if edge.tunnel == true { features.insert(.tunnel) }
        if edge.unpaved == true { features.insert(.unpaved) }
        if edge.roundabout == true { features.insert(.roundabout) }
        if edge.lane_count == 1, highway.map({ !["residential", "service", "living_street"].contains($0) }) ?? false { features.insert(.singleLane) }
        let segment: RoadSegment = edge.use == "parking_aisle" || edge.use == "driveway" ? .parkingLot
            : edge.use == "alley" ? .alley
            : RoadSegment.classify(highway: highway ?? "service", mph: mph, density: edge.density, unpaved: edge.unpaved == true)
        return SpeedLimitReading(mph: mph, isPosted: posted != nil, roadName: edge.names?.first, highway: highway ?? "service",
                                 wayID: edge.way_id ?? 0, distanceMeters: distance, segment: segment, features: features)
    }

    /// Parses an Overpass JSON response (`out tags geom`).
    static func decodeOverpass(_ data: Data) throws -> [RoadWay] {
        struct Response: Decodable {
            struct Element: Decodable {
                var type: String
                var id: Int64
                var tags: [String: String]?
                var geometry: [RoadWay.Point]?
            }
            var elements: [Element]
        }
        return try JSONDecoder().decode(Response.self, from: data).elements.compactMap { e in
            guard e.type == "way", let tags = e.tags, let highway = tags["highway"], let geometry = e.geometry else { return nil }
            return RoadWay(id: e.id, highway: highway, maxspeed: tags["maxspeed"], maxspeedForward: tags["maxspeed:forward"],
                           maxspeedBackward: tags["maxspeed:backward"], oneway: tags["oneway"], name: tags["name"],
                           ref: tags["ref"], points: geometry)
        }
    }
}
