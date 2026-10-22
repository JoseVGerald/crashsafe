import Foundation

struct AlertRecipient: Sendable, Equatable {
    let name: String
    let phone: String
}

enum AlertDelivery: Sendable, Equatable {
    case sent
    /// No signal — will be sent when the phone reconnects.
    case queued
    /// The server ran without a texting/calling provider (or this was a test crash): nothing was sent.
    case dryRun
}

/// Notifies family contacts after a crash (unconscious path, or "I need help").
///
/// iOS can't send texts silently, so the real version is a push/SMS through our backend
/// when online and a persisted queue when offline. 911 stays with Apple's built-in Crash Detection.
protocol EmergencyAlertService: AnyObject {
    func alertFamily(_ recipients: [AlertRecipient], outcome: CheckInOutcome, event: CrashEvent, isOnline: Bool) async -> AlertDelivery
}

/// Pretends to send; reports `.queued` when offline.
final class MockEmergencyAlertService: EmergencyAlertService {
    func alertFamily(_ recipients: [AlertRecipient], outcome: CheckInOutcome, event: CrashEvent, isOnline: Bool) async -> AlertDelivery {
        try? await Task.sleep(for: .seconds(1))
        return isOnline ? .sent : .queued
    }
}

/// Sends the family alert through the CrashSafe backend (`POST /v1/alerts`), which texts each
/// contact and places an automated call that reads the message (Twilio when configured; a dry run
/// otherwise). The server never calls 911 — the phone starts that call itself.
final class BackendEmergencyAlertService: EmergencyAlertService {
    private let endpoint: URL?
    private let driverName: () -> String
    private let location: () -> (lat: Double, lon: Double)?
    private let session: URLSession

    init(endpoint: URL?, driverName: @escaping () -> String, location: @escaping () -> (lat: Double, lon: Double)?,
         session: URLSession = .shared) {
        self.endpoint = endpoint
        self.driverName = driverName
        self.location = location
        self.session = session
    }

    /// Same server as Pulse: an HTTPS `RAGEndpoint` from Info.plist, or the Mac running a Debug simulator.
    static func configured(driverName: @escaping () -> String,
                           location: @escaping () -> (lat: Double, lon: Double)?) -> BackendEmergencyAlertService {
        var endpoint: URL?
        if let configured = Bundle.main.object(forInfoDictionaryKey: "RAGEndpoint") as? String,
           let url = URL(string: configured), url.scheme == "https" {
            endpoint = url
        }
        #if DEBUG && targetEnvironment(simulator)
        endpoint = endpoint ?? URL(string: "http://127.0.0.1:8787")
        #endif
        return BackendEmergencyAlertService(endpoint: endpoint, driverName: driverName, location: location)
    }

    private nonisolated struct Request: Encodable {
        nonisolated struct Recipient: Encodable { let name: String; let phone: String }
        nonisolated struct Location: Encodable { let lat: Double; let lon: Double }
        let isSimulated: Bool
        let outcome: String
        let driverName: String
        let recipients: [Recipient]
        let location: Location?
        let impact: AssistantIncident.Impact?
    }

    private nonisolated struct Response: Decodable { let delivery: String }

    func alertFamily(_ recipients: [AlertRecipient], outcome: CheckInOutcome, event: CrashEvent, isOnline: Bool) async -> AlertDelivery {
        guard isOnline, let endpoint, !recipients.isEmpty, outcome != .ok else { return .queued }
        var request = URLRequest(url: endpoint.appending(path: "v1/alerts"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let here = location()
        request.httpBody = try? encoder.encode(Request(
            isSimulated: event.isSimulated, outcome: outcome.rawValue, driverName: driverName(),
            recipients: recipients.prefix(5).map { .init(name: $0.name, phone: $0.phone) },
            location: here.map { .init(lat: $0.lat, lon: $0.lon) }, impact: event.impact.map(AssistantIncident.Impact.init)))
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(Response.self, from: data) else { return .queued }
        switch result.delivery {
        case "sent", "partial": return .sent
        case "dry_run": return .dryRun
        default: return .queued
        }
    }
}
