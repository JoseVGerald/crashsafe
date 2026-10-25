import CoreLocation
import Foundation
import Observation
import os

/// Fetches the roads around the car (OpenStreetMap, via the free Overpass API).
nonisolated protocol RoadDataSource: Sendable {
    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay]
    /// Roads within `radiusMeters` of a path (Overpass `around` with a polyline).
    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay]
}

/// One public Overpass server. No key; please keep requests infrequent (the service fetches an area
/// once, keeps it on disk, and reuses it until the car leaves it).
nonisolated struct OverpassRoadSource: RoadDataSource {
    static let servers = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]
    var server: URL
    var session: URLSession = .shared
    /// Busy public servers often take 30–90 s (or are down); the quick lookup covers the wait.
    var timeout: TimeInterval = 90

    /// All the public mirrors at once; the first to answer wins.
    static func mirrors() -> RacingRoadSource {
        RacingRoadSource(sources: servers.map { OverpassRoadSource(server: $0) })
    }

    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        try await run("[out:json][timeout:80];way(around:\(Int(radiusMeters)),\(String(format: "%.4f", lat)),\(String(format: "%.4f", lon)))"
            + "[highway~\"\(RoadMatcher.highwayPattern)\"];out tags geom qt;")
    }

    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        guard !path.isEmpty else { return [] }
        let line = path.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        return try await run("[out:json][timeout:90];way(around:\(Int(radiusMeters)),\(line))"
            + "[highway~\"\(RoadMatcher.highwayPattern)\"];out tags geom qt;")
    }

    private func run(_ query: String) async throws -> [RoadWay] {
        var request = URLRequest(url: server, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("CrashSafe/0.1 (Congressional App Challenge student project)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try await Self.decode(data)
    }

    /// A 1 km area is about a megabyte of JSON: decoded off the main thread.
    @concurrent private static func decode(_ data: Data) async throws -> [RoadWay] {
        try RoadMatcher.decodeOverpass(data)
    }
}

/// Asks every source at once and takes the first one that returns roads. The public servers are often
/// slow or down, and trying them one after another (with long timeouts) used to take minutes.
nonisolated struct RacingRoadSource: RoadDataSource {
    let sources: [any RoadDataSource]

    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        try await race { try await $0.roads(nearLat: lat, lon: lon, radiusMeters: radiusMeters) }
    }

    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        try await race { try await $0.roads(along: path, radiusMeters: radiusMeters) }
    }

    private func race(_ body: @escaping @Sendable (any RoadDataSource) async throws -> [RoadWay]) async throws -> [RoadWay] {
        try await withTaskGroup(of: Result<[RoadWay], any Error>.self, returning: Result<[RoadWay], any Error>.self) { group in
            for source in sources {
                group.addTask {
                    do { return .success(try await body(source)) } catch { return .failure(error) }
                }
            }
            var lastError: any Error = URLError(.cannotFindHost)
            var answeredEmpty = false
            while let result = await group.next() {
                switch result {
                case .success(let ways) where !ways.isEmpty:
                    group.cancelAll()
                    return .success(ways)
                case .success:
                    answeredEmpty = true
                case .failure(let error):
                    lastError = error
                }
            }
            return answeredEmpty ? .success([]) : .failure(lastError)
        }.get()
    }
}

/// The speed limit of the road the car is on right now, from a short trace of recent GPS points.
nonisolated protocol QuickSpeedLimitSource: Sendable {
    func speedLimit(along points: [(lat: Double, lon: Double)]) async throws -> SpeedLimitReading?
    /// True when this source's limits beat the local OpenStreetMap match even once road data is on the
    /// phone (TomTom: better limits, matched along the trace). False: only used until road data arrives.
    var isPrimary: Bool { get }
    /// Where a limit came from, for the log.
    var label: String { get }
}

nonisolated extension QuickSpeedLimitSource {
    var isPrimary: Bool { false }
    var label: String { "quick lookup" }
}

/// TomTom's Snap to Roads API: matches the last few GPS points to the road the car is driving on and
/// returns TomTom's speed limit for it (the same map data as in-car navigation, far more complete than
/// OpenStreetMap's `maxspeed` tags in the US). Needs a TomTom key (`PulseKeys.tomTom`); the free tier
/// covers 2,500 requests a day, and the service asks about once every 120 m in town, 400 m on highways.
nonisolated struct TomTomSpeedLimitSource: QuickSpeedLimitSource {
    let key: String
    var endpoint = URL(string: "https://api.tomtom.com/snapToRoads/1")!
    var session: URLSession = .shared
    var timeout: TimeInterval = 6

    var isPrimary: Bool { true }
    var label: String { "TomTom" }

    static let fields = "{projectedPoints{type,geometry{type,coordinates},properties{routeIndex,snapResult}},"
        + "route{type,properties{id,speedLimits{value,unit,type},address{roadName,roadNumbers},frc,formOfWay,roadUse,"
        + "laneInfo{numberOfLanes},partOfTunnel,urbanArea}}}"

    /// With a key in this build; nil without one.
    static func configured() -> TomTomSpeedLimitSource? {
        PulseKeys.tomTom().map { TomTomSpeedLimitSource(key: $0) }
    }

    func speedLimit(along points: [(lat: Double, lon: Double)]) async throws -> SpeedLimitReading? {
        guard !points.isEmpty else { return nil }
        // ~11 m rounding, like the Valhalla lookup; TomTom needs two points, so a lone one is sent twice.
        var trace = points.suffix(5).map { (lat: ($0.lat * 1e4).rounded() / 1e4, lon: ($0.lon * 1e4).rounded() / 1e4) }
        if trace.count == 1 { trace.append(trace[0]) }
        // Direction of travel at each point (from the one before it) keeps the match off the opposite carriageway.
        let headings = trace.indices.map { i -> String in
            let (a, b) = i == 0 ? (trace[0], trace[1]) : (trace[i - 1], trace[i])
            guard a != b else { return "" }
            return String(Int(RoadMatcher.bearing(fromLat: a.lat, lon: a.lon, toLat: b.lat, lon: b.lon).rounded()) % 360)
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "points", value: trace.map { String(format: "%.4f,%.4f", $0.lon, $0.lat) }.joined(separator: ";")),
            URLQueryItem(name: "headings", value: headings.joined(separator: ";")),
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "vehicleType", value: "PassengerCar"),
            URLQueryItem(name: "measurementSystem", value: "imperial"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.setValue("CrashSafe/0.1 (Congressional App Challenge student project)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        // 400 with a lone point TomTom can't place counts as "no road"; 403 (bad key) and 429 (out of quota) throw.
        if status == 400 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try RoadMatcher.decodeTomTomSnap(data, lastPoint: points.last)
    }
}

/// Tries each quick source in order, moving on only when one fails (no key quota, server down);
/// "no road here" from the first one is an answer, not a failure.
nonisolated struct FallbackQuickSource: QuickSpeedLimitSource {
    let sources: [any QuickSpeedLimitSource]

    /// TomTom when this build has a key, with the free Valhalla server behind it.
    static func standard() -> FallbackQuickSource {
        let sources: [(any QuickSpeedLimitSource)?] = [TomTomSpeedLimitSource.configured(), ValhallaSpeedLimitSource()]
        return FallbackQuickSource(sources: sources.compactMap { $0 })
    }

    var isPrimary: Bool { sources.first?.isPrimary ?? false }
    var label: String { sources.first?.label ?? "quick lookup" }

    func speedLimit(along points: [(lat: Double, lon: Double)]) async throws -> SpeedLimitReading? {
        var lastError: any Error = URLError(.cannotFindHost)
        for source in sources {
            do { return try await source.speedLimit(along: points) } catch { lastError = error }
        }
        throw lastError
    }
}

/// The OpenStreetMap community's Valhalla routing server (FOSSGIS, Germany): the same OpenStreetMap
/// limits as Overpass, but served from a routing graph kept in memory, so it answers in under a second
/// instead of 30–60 s. Free, no key; fair use is about one request per second per user, and the service
/// only asks while the phone has no road data for where the car is.
nonisolated struct ValhallaSpeedLimitSource: QuickSpeedLimitSource {
    var endpoint = URL(string: "https://valhalla1.openstreetmap.de/trace_attributes")!
    var session: URLSession = .shared
    var timeout: TimeInterval = 6

    func speedLimit(along points: [(lat: Double, lon: Double)]) async throws -> SpeedLimitReading? {
        guard !points.isEmpty else { return nil }
        // ~11 m rounding; a lone point (parked) is sent twice, the least Valhalla accepts.
        var shape = points.suffix(5).map { ["lat": ($0.lat * 1e4).rounded() / 1e4, "lon": ($0.lon * 1e4).rounded() / 1e4] }
        if shape.count == 1 { shape.append(shape[0]) }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("CrashSafe/0.1 (Congressional App Challenge student project)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "shape": shape, "costing": "auto", "shape_match": "map_snap",
            "filters": ["attributes": ["edge.speed_limit", "edge.names", "edge.way_id", "edge.road_class", "edge.use",
                                       "edge.density", "edge.lane_count", "edge.bridge", "edge.tunnel", "edge.unpaved", "edge.roundabout",
                                       "matched.edge_index", "matched.type", "matched.distance_from_trace_point"],
                        "action": "include"],
        ] as [String: Any])
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        // 400 "no suitable edges": nowhere near a road (a field, a big parking lot).
        if status == 400 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try RoadMatcher.decodeValhallaTrace(data)
    }
}

/// The CrashSafe backend's cached road tiles (`GET /v1/roads`, `POST /v1/roads/route`): instant once a
/// tile has been fetched, and independent of how busy the public servers are right now.
nonisolated struct BackendRoadSource: RoadDataSource {
    let endpoint: URL
    var session: URLSession = .shared

    /// Same server as Pulse: an HTTPS `RAGEndpoint`, or the Mac running a Debug simulator.
    static func configured() -> BackendRoadSource? {
        PulseBackend.endpoint().map { BackendRoadSource(endpoint: $0) }
    }

    private struct Response: Decodable { var ways: [RoadWay] }

    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        var components = URLComponents(url: endpoint.appending(path: "v1/roads"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.3f", lat)),
                                 URLQueryItem(name: "lon", value: String(format: "%.3f", lon)),
                                 URLQueryItem(name: "radius", value: String(Int(radiusMeters)))]
        var request = URLRequest(url: components.url!, timeoutInterval: 90)
        PulseBackend.authorize(&request)
        return try await decode(request)
    }

    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        var request = URLRequest(url: endpoint.appending(path: "v1/roads/route"), timeoutInterval: 180)
        PulseBackend.authorize(&request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": path.map { [($0.latitude * 1e4).rounded() / 1e4, ($0.longitude * 1e4).rounded() / 1e4] },
            "radius": radiusMeters,
        ])
        return try await decode(request)
    }

    private func decode(_ request: URLRequest) async throws -> [RoadWay] {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).ways
    }
}

/// Tries each source in order (backend cache, then the public servers directly, all at once).
nonisolated struct FallbackRoadSource: RoadDataSource {
    let sources: [any RoadDataSource]

    static func standard() -> FallbackRoadSource {
        var sources: [any RoadDataSource] = []
        if let backend = BackendRoadSource.configured() { sources.append(backend) }
        sources.append(OverpassRoadSource.mirrors())
        return FallbackRoadSource(sources: sources)
    }

    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        try await first { try await $0.roads(nearLat: lat, lon: lon, radiusMeters: radiusMeters) }
    }

    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        try await first { try await $0.roads(along: path, radiusMeters: radiusMeters) }
    }

    private func first(_ body: (any RoadDataSource) async throws -> [RoadWay]) async throws -> [RoadWay] {
        var lastError: Error = URLError(.cannotFindHost)
        for source in sources {
            do {
                let ways = try await body(source)
                if !ways.isEmpty { return ways }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// The posted (or typical) speed limit where the car is, kept current from GPS.
///
/// Two layers, so a limit shows within a second of the first GPS fix:
/// - Road data for the ~1 km around the car (OpenStreetMap via Overpass, or the trip pack), kept on disk
///   and matched locally: works offline and costs nothing per fix, but a new area takes 30–60 s to arrive,
///   many US roads have no posted limit in it, and matching one GPS point can pick a road beside the car.
/// - A quick lookup of just the road the car is on, matched along its last few GPS points
///   (`QuickSpeedLimitSource`, < 1 s). With a TomTom key it is the main source the whole drive and the
///   local match only fills in when TomTom can't be reached; without one (Valhalla) it covers the wait
///   for road data.
///
/// Privacy: the area lookup sends a position rounded to ~100 m; the quick lookup sends the last few
/// GPS points rounded to ~11 m (with TomTom, all drive; with Valhalla, only while no road data for the
/// area is on the phone). Neither sends anything that identifies the driver.
@MainActor
@Observable
final class SpeedLimitService {
    enum Status: Equatable { case idle, loading, ready, failed }

    private(set) var current: SpeedLimitReading?
    private(set) var status: Status = .idle
    private(set) var roadsLoaded = 0
    /// Seconds from a drive's first GPS fix to its first limit, and where that limit came from.
    private(set) var firstLimit: (seconds: Double, basis: String)?

    @ObservationIgnored private let source: any RoadDataSource
    @ObservationIgnored private let quick: (any QuickSpeedLimitSource)?
    @ObservationIgnored private let store: RoadAreaStore?
    @ObservationIgnored private var cache: (lat: Double, lon: Double, ways: [RoadWay])?
    /// Roads saved with the active trip's pack (work with no signal).
    @ObservationIgnored private var offline: [RoadWay] = []
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var retryAfter: Date = .distantPast
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastFix: LocationSample?
    @ObservationIgnored private var heading: Double?
    /// Recent fixes at least 6 m apart: the trace the quick lookup matches.
    @ObservationIgnored private var trail: [LocationSample] = []
    @ObservationIgnored private var quickReading: (reading: SpeedLimitReading, lat: Double, lon: Double)?
    @ObservationIgnored private var quickInFlight = false
    @ObservationIgnored private var quickAfter: Date = .distantPast
    @ObservationIgnored private var firstFixAt: Date?
    /// "US-OR"-style region of the car, for that region's legal default limits on untagged roads.
    @ObservationIgnored var regionCode: () -> String? = { nil }
    @ObservationIgnored private let defaults: RoadDefaults? = Bundle.main.url(forResource: "default_speeds", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }.flatMap { try? RoadDefaults(json: $0) }

    static let log = Logger(subsystem: "org.cac.crashsafe", category: "speed-limits")
    /// Area fetched around the car; refetched when it gets within `refetchMargin` of the edge.
    static let radius = 1_000.0
    static let refetchMargin = 400.0
    /// A quick reading is used this far from where it was looked up, and refreshed after this far
    /// (further apart on highways, where the limit rarely changes).
    static let quickValidity = 250.0
    static let quickSpacing = 120.0
    static let quickHighwaySpacing = 400.0
    static let quickHighwayValidity = 600.0
    /// At most one quick lookup per this many seconds (the server's fair use is one per second).
    static let quickInterval: TimeInterval = 3

    init(source: any RoadDataSource = FallbackRoadSource.standard(),
         quick: (any QuickSpeedLimitSource)? = FallbackQuickSource.standard(),
         store: RoadAreaStore? = RoadAreaStore()) {
        self.source = source
        self.quick = quick
        self.store = store
    }

    /// Roads downloaded with the trip pack for the drive that's starting (empty for a quick drive).
    func setOfflineRoads(_ roads: [RoadWay]) {
        offline = roads
        roadsLoaded = (cache?.ways.count ?? 0) + roads.count
        if !roads.isEmpty && status == .idle { status = .ready }
    }

    /// Starts loading the roads around a position before a drive needs them (the app does this as soon
    /// as it knows where the phone is, so "Drive this car" usually finds them already on the phone).
    func prefetch(lat: Double, lon: Double) {
        let fix = LocationSample(uptime: ProcessInfo.processInfo.systemUptime, date: .now, latitude: lat, longitude: lon,
                                 horizontalAccuracy: 10, speedMPS: -1, speedAccuracy: -1)
        guard fix.isValid else { return }
        if let cache, covers(cache, fix) { return }
        if let saved = store?.area(covering: fix, radius: Self.radius - Self.refetchMargin) {
            useArea(saved)
            return
        }
        fetch(lat: fix.latitude, lon: fix.longitude)
    }

    /// A new drive: forget the last drive's position and limit (road data stays).
    func startDrive() {
        current = nil
        lastFix = nil
        heading = nil
        trail = []
        quickReading = nil
        firstFixAt = nil
        firstLimit = nil
    }

    private func match(_ fix: LocationSample) -> SpeedLimitReading? {
        RoadMatcher.match(lat: fix.latitude, lon: fix.longitude, heading: heading, ways: (cache?.ways ?? []) + offline)
    }

    /// Feed every GPS fix. Matching is local and instant; the network is only used for a new area.
    func observe(_ fix: LocationSample) {
        guard fix.isValid, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 60 else { return }
        if firstFixAt == nil { firstFixAt = .now }
        if let last = lastFix {
            let moved = TransportFeatures.haversine(last.latitude, last.longitude, fix.latitude, fix.longitude)
            if moved >= 6 {
                heading = RoadMatcher.bearing(fromLat: last.latitude, lon: last.longitude, toLat: fix.latitude, lon: fix.longitude)
                lastFix = fix
                trail.append(fix)
                if trail.count > 5 { trail.removeFirst() }
            }
        } else {
            lastFix = fix
            trail = [fix]
        }
        if cache == nil || !covers(cache!, fix), let saved = store?.area(covering: fix, radius: Self.radius - Self.refetchMargin) {
            useArea(saved)
        }
        let hasRoadData = (cache.map { covers($0, fix) } ?? false) || !offline.isEmpty
        let primary = quick?.isPrimary == true
        let quickHere = quickReading.flatMap {
            TransportFeatures.haversine($0.lat, $0.lon, fix.latitude, fix.longitude) <= Self.validity(of: $0.reading) ? $0.reading : nil
        }
        if primary, let quickHere {
            show(quickHere, basis: quick?.label ?? "quick lookup")
        } else if let local = match(fix) {
            show(local, basis: "road data")
        } else if let quickHere {
            show(quickHere, basis: quick?.label ?? "quick lookup")
        } else {
            current = nil
        }
        if primary { lookUpQuickly(fix) }
        if !(cache.map { covers($0, fix) } ?? false) {
            if !primary, match(fix) == nil { lookUpQuickly(fix) }
            if !(current != nil && hasRoadData) { fetch(lat: fix.latitude, lon: fix.longitude) }
        }
    }

    func reset() {
        startDrive()
    }

    private func show(_ reading: SpeedLimitReading, basis: String) {
        var reading = reading
        if reading.segment == nil { reading.segment = RoadSegment.classify(highway: reading.highway, mph: reading.isPosted ? reading.mph : nil) }
        // An untagged road gets the legal default where the car is (e.g. 25 mph on an Oregon residential street).
        if !reading.isPosted, let segment = reading.segment,
           let regional = defaults?.typicalMPH(for: segment, region: regionCode()) {
            reading.mph = regional
        }
        current = reading
        if status != .ready { status = .ready }
        if firstLimit == nil, let firstFixAt {
            let seconds = Date.now.timeIntervalSince(firstFixAt)
            firstLimit = (seconds, basis)
            Self.log.info("first speed limit after \(seconds, format: .fixed(precision: 1), privacy: .public) s from \(basis, privacy: .public)")
        }
    }

    private static func validity(of reading: SpeedLimitReading) -> Double {
        reading.environment == .highway ? quickHighwayValidity : quickValidity
    }

    private func useArea(_ area: (lat: Double, lon: Double, ways: [RoadWay])) {
        cache = area
        roadsLoaded = area.ways.count + offline.count
        status = .ready
    }

    private func covers(_ area: (lat: Double, lon: Double, ways: [RoadWay]), _ fix: LocationSample) -> Bool {
        TransportFeatures.haversine(area.lat, area.lon, fix.latitude, fix.longitude) < Self.radius - Self.refetchMargin
    }

    /// The road the car is on, from the quick source: all drive for a primary source (TomTom), otherwise
    /// while the area's road data is still on its way.
    private func lookUpQuickly(_ fix: LocationSample) {
        guard let quick, !quickInFlight, Date.now >= quickAfter else { return }
        if let previous = quickReading,
           TransportFeatures.haversine(previous.lat, previous.lon, fix.latitude, fix.longitude)
            < (previous.reading.environment == .highway ? Self.quickHighwaySpacing : Self.quickSpacing) { return }
        quickInFlight = true
        if current == nil, status != .ready { status = .loading }
        var points = trail.map { (lat: $0.latitude, lon: $0.longitude) }
        if trail.last != fix { points.append((fix.latitude, fix.longitude)) }
        let started = Date.now
        Task {
            do {
                let reading = try await quick.speedLimit(along: points)
                Self.log.debug("quick lookup: \(reading.map { "\(Int($0.mph)) mph" } ?? "no road", privacy: .public) in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public) s")
                quickAfter = Date.now.addingTimeInterval(Self.quickInterval)
                if let reading {
                    quickReading = (reading, fix.latitude, fix.longitude)
                    // Road data that arrived meanwhile wins (unless this source is primary); a reading for where the
                    // car no longer is doesn't count.
                    let last = lastFix ?? fix
                    if quick.isPrimary || match(last) == nil,
                       TransportFeatures.haversine(fix.latitude, fix.longitude, last.latitude, last.longitude) <= Self.validity(of: reading) {
                        show(reading, basis: quick.label)
                    }
                }
            } catch {
                Self.log.debug("quick lookup failed: \(error.localizedDescription, privacy: .public)")
                quickAfter = Date.now.addingTimeInterval(10)
            }
            quickInFlight = false
        }
    }

    private func fetch(lat: Double, lon: Double) {
        guard !fetching, Date.now >= retryAfter else { return }
        fetching = true
        if cache == nil, current == nil { status = .loading }
        // ~100 m rounding: enough for a 1 km area, less precise than the car's real position.
        let lat = (lat * 1000).rounded() / 1000, lon = (lon * 1000).rounded() / 1000
        let started = Date.now
        Task { [source] in
            do {
                let ways = try await source.roads(nearLat: lat, lon: lon, radiusMeters: Self.radius)
                Self.log.debug("roads: \(ways.count, privacy: .public) in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s")
                useArea((lat, lon, ways))
                failures = 0
                store?.save(lat: lat, lon: lon, ways: ways)
                if let last = lastFix, let local = match(last) { show(local, basis: "road data") }
            } catch {
                Self.log.debug("roads failed after \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s: \(error.localizedDescription, privacy: .public)")
                if cache == nil, current == nil { status = .failed }
                // Back off while the public servers struggle: 20 s, 40 s, 80 s… up to 5 min.
                failures += 1
                retryAfter = Date.now.addingTimeInterval(min(300, 20 * pow(2, Double(failures - 1))))
            }
            fetching = false
        }
    }
}

/// The last few road areas fetched, kept on disk so a regular route works without waiting on the network.
/// Only road data is stored (no trace of where or when the car was).
struct RoadAreaStore: Sendable {
    var directory: URL = URL.cachesDirectory.appending(path: "road-areas")
    var keep = 40

    func area(covering fix: LocationSample, radius: Double) -> (lat: Double, lon: Double, ways: [RoadWay])? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json" {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_").compactMap { Double($0) }
            guard parts.count == 2, TransportFeatures.haversine(parts[0], parts[1], fix.latitude, fix.longitude) < radius,
                  let data = try? Data(contentsOf: file), let ways = try? JSONDecoder().decode([RoadWay].self, from: data) else { continue }
            return (parts[0], parts[1], ways)
        }
        return nil
    }

    func save(lat: Double, lon: Double, ways: [RoadWay]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ways) else { return }
        try? data.write(to: directory.appending(path: String(format: "%.3f_%.3f.json", lat, lon)), options: .atomic)
        // Oldest first out.
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        for old in files.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}
