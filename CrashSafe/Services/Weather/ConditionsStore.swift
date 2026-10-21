import CoreLocation
import Foundation
import Observation

/// Current weather at the driver's location, refreshed when they move or every 15 minutes.
@Observable
final class ConditionsStore {
    private(set) var weather: WeatherSnapshot?
    private(set) var isLoading = false
    private(set) var failed = false

    @ObservationIgnored private let service: any WeatherService
    @ObservationIgnored private var lastFetch: (location: CLLocation, date: Date)?

    init(service: any WeatherService) {
        self.service = service
    }

    /// Night if the weather service says so, otherwise by the clock.
    var isNight: Bool {
        if let weather { return !weather.isDay }
        let hour = Calendar.current.component(.hour, from: .now)
        return hour < 6 || hour >= 20
    }

    var advice: DrivingAdvice {
        DrivingAdvice.make(weather: weather, isNight: isNight)
    }

    func refresh(for location: CLLocation?, force: Bool = false) async {
        guard let location else { return }
        if !force, let last = lastFetch,
           last.location.distance(from: location) < 5_000, Date.now.timeIntervalSince(last.date) < 15 * 60 {
            return
        }
        isLoading = weather == nil
        defer { isLoading = false }
        do {
            weather = try await service.current(at: location.coordinate)
            lastFetch = (location, .now)
            failed = false
        } catch {
            failed = weather == nil
        }
    }

    /// Demo scenarios supply their own conditions.
    func override(with snapshot: WeatherSnapshot?) {
        weather = snapshot
        lastFetch = nil
    }
}
