import CoreLocation
import Foundation
import Observation
import os

/// Fetches the roads around the car (OpenStreetMap, via the free Overpass API).
protocol RoadDataSource: Sendable {
    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay]
    /// Roads within `radiusMeters` of a path (Overpass `around` with a polyline).
    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay]
}

/// Public Overpass servers, tried in order. No key; please keep requests infrequent (the service
/// fetches an area once and reuses it until the car leaves it).
struct OverpassRoadSource: RoadDataSource {
    static let servers = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]
    var session: URLSession = .shared
    /// Public servers are often slow (30–60 s); a lookup never blocks driving, so wait for them.
    var timeout: TimeInterval = 45

    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        try await run("[out:json][timeout:25];way(around:\(Int(radiusMeters)),\(String(format: "%.4f", lat)),\(String(format: "%.4f", lon)))"
            + "[highway~\"\(RoadMatcher.highwayPattern)\"];out tags geom qt;")
    }

    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        guard !path.isEmpty else { return [] }
        let line = path.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        return try await run("[out:json][timeout:90];way(around:\(Int(radiusMeters)),\(line))"
            + "[highway~\"\(RoadMatcher.highwayPattern)\"];out tags geom qt;")
    }

    private func run(_ query: String) async throws -> [RoadWay] {
        var lastError: Error = URLError(.cannotFindHost)
        for server in Self.servers {
            var request = URLRequest(url: server, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("CrashSafe/0.1 (Congressional App Challenge student project)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "data", value: query)]
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return try RoadMatcher.decodeOverpass(data)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// The CrashSafe backend's cached road tiles (`GET /v1/roads`, `POST /v1/roads/route`): instant once a
/// tile has been fetched, and independent of how busy the public servers are right now.
struct BackendRoadSource: RoadDataSource {
    let endpoint: URL
    var session: URLSession = .shared

    /// Same server as Pulse: an HTTPS `RAGEndpoint`, or the Mac running a Debug simulator.
    static func configured() -> BackendRoadSource? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "RAGEndpoint") as? String,
           let url = URL(string: configured), url.scheme == "https" {
            return BackendRoadSource(endpoint: url)
        }
        #if DEBUG && targetEnvironment(simulator)
        return BackendRoadSource(endpoint: URL(string: "http://127.0.0.1:8787")!)
        #else
        return nil
        #endif
    }

    private struct Response: Decodable { var ways: [RoadWay] }

    func roads(nearLat lat: Double, lon: Double, radiusMeters: Double) async throws -> [RoadWay] {
        var components = URLComponents(url: endpoint.appending(path: "v1/roads"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.3f", lat)),
                                 URLQueryItem(name: "lon", value: String(format: "%.3f", lon)),
                                 URLQueryItem(name: "radius", value: String(Int(radiusMeters)))]
        return try await decode(URLRequest(url: components.url!, timeoutInterval: 90))
    }

    func roads(along path: [CLLocationCoordinate2D], radiusMeters: Double) async throws -> [RoadWay] {
        var request = URLRequest(url: endpoint.appending(path: "v1/roads/route"), timeoutInterval: 180)
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

/// Tries each source in order (backend cache, then the public servers directly).
struct FallbackRoadSource: RoadDataSource {
    let sources: [any RoadDataSource]

    static func standard() -> FallbackRoadSource {
        var sources: [any RoadDataSource] = []
        if let backend = BackendRoadSource.configured() { sources.append(backend) }
        sources.append(OverpassRoadSource())
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
/// Privacy: the area lookup sends the car's position, rounded to ~100 m, to a public OpenStreetMap server.
@MainActor
@Observable
final class SpeedLimitService {
    enum Status: Equatable { case idle, loading, ready, failed }

    private(set) var current: SpeedLimitReading?
    private(set) var status: Status = .idle
    private(set) var roadsLoaded = 0

    @ObservationIgnored private let source: any RoadDataSource
    @ObservationIgnored private let store: RoadAreaStore?
    @ObservationIgnored private var cache: (lat: Double, lon: Double, ways: [RoadWay])?
    /// Roads saved with the active trip's pack (work with no signal).
    @ObservationIgnored private var offline: [RoadWay] = []
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var retryAfter: Date = .distantPast
    @ObservationIgnored private var lastFix: LocationSample?
    @ObservationIgnored private var heading: Double?

    /// Area fetched around the car; refetched when it gets within `refetchMargin` of the edge.
    static let log = Logger(subsystem: "org.cac.crashsafe", category: "speed-limits")
    static let radius = 700.0
    static let refetchMargin = 300.0

    init(source: any RoadDataSource = FallbackRoadSource.standard(), store: RoadAreaStore? = RoadAreaStore()) {
        self.source = source
        self.store = store
    }

    /// Roads downloaded with the trip pack for the drive that's starting (empty for a quick drive).
    func setOfflineRoads(_ roads: [RoadWay]) {
        offline = roads
        roadsLoaded = (cache?.ways.count ?? 0) + roads.count
        if !roads.isEmpty && status == .idle { status = .ready }
    }

    private func match(_ fix: LocationSample) -> SpeedLimitReading? {
        RoadMatcher.match(lat: fix.latitude, lon: fix.longitude, heading: heading, ways: (cache?.ways ?? []) + offline)
    }

    /// Feed every GPS fix. Matching is local and instant; a network fetch only happens for a new area.
    func observe(_ fix: LocationSample) {
        guard fix.isValid, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 60 else { return }
        if let last = lastFix {
            let moved = TransportFeatures.haversine(last.latitude, last.longitude, fix.latitude, fix.longitude)
            if moved >= 6 {
                heading = RoadMatcher.bearing(fromLat: last.latitude, lon: last.longitude, toLat: fix.latitude, lon: fix.longitude)
                lastFix = fix
            }
        } else {
            lastFix = fix
        }
        if cache == nil || !covers(cache!, fix), let saved = store?.area(covering: fix, radius: Self.radius - Self.refetchMargin) {
            cache = saved
            roadsLoaded = saved.ways.count + offline.count
            status = .ready
        }
        current = match(fix)
        if let cache, covers(cache, fix) { return }
        if current != nil, !offline.isEmpty { return } // the trip pack covers this stretch
        fetch(around: fix)
    }

    func reset() {
        current = nil
        lastFix = nil
        heading = nil
    }

    private func covers(_ area: (lat: Double, lon: Double, ways: [RoadWay]), _ fix: LocationSample) -> Bool {
        TransportFeatures.haversine(area.lat, area.lon, fix.latitude, fix.longitude) < Self.radius - Self.refetchMargin
    }

    private func fetch(around fix: LocationSample) {
        guard !fetching, Date.now >= retryAfter else { return }
        fetching = true
        if cache == nil { status = .loading }
        // ~100 m rounding: enough for a 700 m area, less precise than the car's real position.
        let lat = (fix.latitude * 1000).rounded() / 1000, lon = (fix.longitude * 1000).rounded() / 1000
        let started = Date.now
        Task { [source] in
            do {
                let ways = try await source.roads(nearLat: lat, lon: lon, radiusMeters: Self.radius)
                Self.log.debug("roads: \(ways.count, privacy: .public) in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s")
                cache = (lat, lon, ways)
                store?.save(lat: lat, lon: lon, ways: ways)
                roadsLoaded = ways.count + offline.count
                status = .ready
                if let last = lastFix { current = match(last) }
            } catch {
                Self.log.debug("roads failed after \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s: \(error.localizedDescription, privacy: .public)")
                status = cache == nil ? .failed : status
                retryAfter = Date.now.addingTimeInterval(20)
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
