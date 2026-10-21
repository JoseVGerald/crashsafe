import Foundation
import Network
import Observation

/// Publishes whether the phone currently has a usable network path.
/// The assistant and alert services use this to pick online vs. offline behavior.
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init(start: Bool = true) {
        guard start else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "ConnectivityMonitor"))
    }

    deinit {
        monitor.cancel()
    }
}
