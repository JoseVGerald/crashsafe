import Foundation

/// How to drive right now, given weather and light. Pure logic — easy to test and to tune.
struct DrivingAdvice: Equatable {
    struct Tip: Equatable, Identifiable {
        let systemImage: String
        let text: String
        var id: String { text }
    }

    let headline: String
    /// Why the headline matters right now, in one plain sentence.
    let reason: String
    let speedFactor: Double
    let followingSeconds: Int
    let tips: [Tip]

    var speedReductionPercent: Int { Int(((1 - speedFactor) * 100).rounded()) }

    static func make(weather: WeatherSnapshot?, isNight: Bool) -> DrivingAdvice {
        let condition = weather?.condition ?? .clear
        var factor = condition.speedFactor
        if isNight { factor -= 0.05 }
        if let visibility = weather?.visibilityMiles, visibility < 1 { factor -= 0.1 }
        factor = max(0.45, factor)

        var following = 3
        if condition.isWet { following = condition.roadFriction < 0.3 ? 8 : 5 }
        if isNight { following += 1 }

        var tips: [Tip] = []
        if factor < 1 {
            tips.append(Tip(systemImage: "gauge.with.dots.needle.33percent",
                            text: "Drive about \(Int(((1 - factor) * 100).rounded()))% under the limit"))
        } else {
            tips.append(Tip(systemImage: "gauge.with.dots.needle.50percent", text: "Normal speeds are fine"))
        }
        tips.append(Tip(systemImage: "car.rear.and.tire.marks", text: "Keep a \(following)-second gap"))
        if isNight || condition == .fog || condition.isWet {
            tips.append(Tip(systemImage: "headlight.low.beam.fill", text: "Headlights on"))
        }
        if condition == .snow || condition == .freezingRain {
            tips.append(Tip(systemImage: "snowflake", text: "Brake early and gently"))
        } else if condition.isWet, condition != .fog {
            tips.append(Tip(systemImage: "drop.fill", text: "Avoid sudden braking"))
        } else if condition == .fog {
            tips.append(Tip(systemImage: "eye.fill", text: "Low beams, not high beams"))
        }
        if let wind = weather?.windMph, wind > 25 {
            tips.append(Tip(systemImage: "wind", text: "Strong gusts — both hands on the wheel"))
        }

        let light = isNight ? " at night" : ""
        let headline: String = switch condition {
        case .clear, .partlyCloudy, .cloudy: isNight ? "Dark roads — stay alert" : "Good driving conditions"
        case .fog: "Low visibility\(light)"
        case .drizzle, .rain: "Wet roads\(light)"
        case .heavyRain, .thunderstorm: "Heavy rain\(light) — slow down"
        case .snow: "Snow on the roads"
        case .freezingRain: "Ice risk — drive only if you must"
        }

        var reason: String = switch condition {
        case .clear, .partlyCloudy, .cloudy:
            isNight ? "It's dark out, so people, animals and debris are harder to see and other drivers react later."
                : "Roads look clear and dry. Keep your eyes up and your phone down."
        case .fog: "Fog cuts how far ahead you can see, so hazards appear with less warning."
        case .drizzle, .rain: "Wet pavement takes longer to stop on, especially in the first rain after a dry spell."
        case .heavyRain, .thunderstorm: "Heavy rain hides lane lines and can make tires hydroplane on standing water."
        case .snow: "Snow hides lane lines and makes stopping and turning slower than usual."
        case .freezingRain: "Ice can form where you can't see it, especially on bridges and in shade."
        }
        if isNight, condition != .clear, condition != .partlyCloudy, condition != .cloudy {
            reason += " Darkness makes it harder still."
        }

        return DrivingAdvice(headline: headline, reason: reason, speedFactor: factor, followingSeconds: following, tips: tips)
    }
}

/// How the driver's actual behavior compares to the advice.
struct DrivingComparison: Equatable {
    enum Status: Equatable {
        case noData, onTrack, caution, tooFast

        var label: String {
            switch self {
            case .noData: "Not driving"
            case .onTrack: "On track"
            case .caution: "Ease up"
            case .tooFast: "Too fast"
            }
        }
    }

    let status: Status
    let recommendedMaxMPH: Double?
    let message: String

    static func make(snapshot: DrivingSnapshot, advice: DrivingAdvice, isDriving: Bool) -> DrivingComparison {
        guard isDriving else {
            return DrivingComparison(status: .noData, recommendedMaxMPH: nil,
                                     message: "Start a trip to compare your driving with today's conditions.")
        }
        let recommended = snapshot.speedLimitMPH.map { (($0 * advice.speedFactor) / 5).rounded() * 5 }
        // Small buffers so normal speedometer wobble doesn't trigger a nag.
        if let recommended, snapshot.speedMPH > recommended + 7 {
            return DrivingComparison(status: .tooFast, recommendedMaxMPH: recommended,
                                     message: "You're at \(Int(snapshot.speedMPH)) mph. In these conditions, aim for \(Int(recommended)) or less.")
        }
        if let recommended, snapshot.speedMPH > recommended + 2 {
            return DrivingComparison(status: .caution, recommendedMaxMPH: recommended,
                                     message: "A little over the \(Int(recommended)) mph we'd suggest right now.")
        }
        if snapshot.hardBrakes >= 3 {
            return DrivingComparison(status: .caution, recommendedMaxMPH: recommended,
                                     message: "\(snapshot.hardBrakes) hard brakes this drive — leave more room ahead.")
        }
        let limitNote = recommended == nil ? " (speed limit data not available here)" : ""
        return DrivingComparison(status: .onTrack, recommendedMaxMPH: recommended,
                                 message: "Smooth and steady — matches the conditions\(limitNote).")
    }
}
