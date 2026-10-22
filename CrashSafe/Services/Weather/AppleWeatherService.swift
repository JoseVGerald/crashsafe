import CoreLocation
import Foundation
import WeatherKit

/// Where the current conditions came from (shown with the required attribution).
enum WeatherSource: String, Sendable, Equatable {
    case appleWeather
    case openMeteo
}

/// Conditions from Apple Weather (WeatherKit), with Open-Meteo as a fallback.
///
/// WeatherKit only answers apps signed by a paid Apple Developer team that has the WeatherKit
/// capability turned on (and the `com.apple.developer.weatherkit` entitlement). Until then, or if
/// Apple Weather can't be reached, conditions come from Open-Meteo and the attribution says so.
final class AppleWeatherService: CrashSafe.WeatherService {
    private let fallback: any CrashSafe.WeatherService
    private let timeout: Duration
    /// Source of the last successful fetch.
    private(set) var lastSource: WeatherSource?
    /// Apple's required attribution (logo + legal page), when Apple Weather supplied the data.
    private(set) var attribution: WeatherAttribution?

    init(fallback: any CrashSafe.WeatherService = OpenMeteoWeatherService(), timeout: Duration = .seconds(4)) {
        self.fallback = fallback
        self.timeout = timeout
    }

    func current(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        if let snapshot = await appleWeather(at: coordinate) {
            lastSource = .appleWeather
            return snapshot
        }
        let snapshot = try await fallback.current(at: coordinate)
        lastSource = .openMeteo
        return snapshot
    }

    private func appleWeather(at coordinate: CLLocationCoordinate2D) async -> WeatherSnapshot? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let timeout = timeout
        return await withTaskGroup(of: WeatherSnapshot?.self) { group in
            group.addTask {
                guard let current = try? await WeatherKit.WeatherService.shared.weather(for: location, including: .current) else {
                    return nil
                }
                return Self.snapshot(from: current)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first != nil {
                attribution = try? await WeatherKit.WeatherService.shared.attribution
            }
            return first
        }
    }

    nonisolated static func snapshot(from current: CurrentWeather) -> WeatherSnapshot {
        WeatherSnapshot(temperatureF: current.temperature.converted(to: .fahrenheit).value,
                        condition: condition(current.condition),
                        windMph: current.wind.speed.converted(to: .milesPerHour).value,
                        visibilityMiles: current.visibility.converted(to: .miles).value,
                        isDay: current.isDaylight)
    }

    nonisolated static func condition(_ condition: WeatherKit.WeatherCondition) -> CrashSafe.WeatherCondition {
        switch condition {
        case .clear, .mostlyClear, .hot, .frigid, .breezy, .windy: .clear
        case .partlyCloudy: .partlyCloudy
        case .mostlyCloudy, .cloudy: .cloudy
        case .foggy, .haze, .smoky, .blowingDust: .fog
        case .drizzle, .sunShowers: .drizzle
        case .rain: .rain
        case .heavyRain, .tropicalStorm, .hurricane: .heavyRain
        case .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms: .thunderstorm
        case .freezingDrizzle, .freezingRain, .sleet, .wintryMix, .hail: .freezingRain
        case .flurries, .snow, .heavySnow, .sunFlurries, .blizzard, .blowingSnow: .snow
        @unknown default: .cloudy
        }
    }
}
