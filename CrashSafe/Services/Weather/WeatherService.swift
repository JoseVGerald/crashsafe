import CoreLocation
import Foundation

enum WeatherCondition: String, Sendable, CaseIterable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, heavyRain, freezingRain, snow, thunderstorm

    var label: String {
        switch self {
        case .clear: "Clear"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .freezingRain: "Freezing rain"
        case .snow: "Snow"
        case .thunderstorm: "Thunderstorm"
        }
    }

    func systemImage(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .freezingRain: "cloud.sleet.fill"
        case .snow: "cloud.snow.fill"
        case .thunderstorm: "cloud.bolt.rain.fill"
        }
    }

    /// Approximate tire–road friction used for stopping distances.
    var roadFriction: Double {
        switch self {
        case .clear, .partlyCloudy, .cloudy: 0.7
        case .fog, .drizzle: 0.55
        case .rain, .thunderstorm: 0.45
        case .heavyRain: 0.4
        case .snow: 0.25
        case .freezingRain: 0.15
        }
    }

    /// Share of the posted limit that's sensible in these conditions.
    var speedFactor: Double {
        switch self {
        case .clear, .partlyCloudy, .cloudy: 1
        case .drizzle: 0.9
        case .rain: 0.85
        case .fog, .heavyRain, .thunderstorm: 0.75
        case .snow: 0.6
        case .freezingRain: 0.5
        }
    }

    var isWet: Bool { roadFriction < 0.7 }

    /// WMO weather interpretation codes (used by Open-Meteo).
    init(wmoCode: Int) {
        switch wmoCode {
        case 0: self = .clear
        case 1, 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57, 66, 67: self = .freezingRain
        case 61, 63, 80, 81: self = .rain
        case 65, 82: self = .heavyRain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .thunderstorm
        default: self = .cloudy
        }
    }
}

struct WeatherSnapshot: Sendable, Equatable {
    var temperatureF: Double
    var condition: WeatherCondition
    var windMph: Double
    var visibilityMiles: Double?
    var isDay: Bool
    var fetchedAt: Date = .now
}

protocol WeatherService: AnyObject {
    func current(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot
}

/// Live conditions from Open-Meteo (free, no API key).
final class OpenMeteoWeatherService: WeatherService {
    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let is_day: Int
            let weather_code: Int
            let wind_speed_10m: Double
            let visibility: Double?
        }
        let current: Current
    }

    func current(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            // Rounded to ~1 km: weather doesn't need more, and less precise location leaves the phone.
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,is_day,weather_code,wind_speed_10m,visibility"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let current = try JSONDecoder().decode(Response.self, from: data).current
        return WeatherSnapshot(
            temperatureF: current.temperature_2m,
            condition: WeatherCondition(wmoCode: current.weather_code),
            windMph: current.wind_speed_10m,
            visibilityMiles: current.visibility.map { $0 / 1_609.34 },
            isDay: current.is_day == 1
        )
    }
}

/// Fixed conditions for previews and tests.
final class MockWeatherService: WeatherService {
    var snapshot = WeatherSnapshot(temperatureF: 48, condition: .rain, windMph: 9, visibilityMiles: 4, isDay: false)

    func current(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        snapshot
    }
}
