import Foundation

/// A spoken/visual nudge from Pulse while driving.
struct CoachingMessage: Equatable {
    enum Severity { case positive, caution, warning }

    let title: String
    let body: String
    let severity: Severity
}

/// Turns driving data + the driver profile into a short message in the style that works for them.
///
/// AI TEAM: this is the rules-based proof of concept. A model can replace `message(...)` later;
/// keep the same inputs (it's everything the model needs) and outputs.
enum CoachingEngine {
    struct Input {
        var snapshot: DrivingSnapshot
        var advice: DrivingAdvice
        var weather: WeatherSnapshot?
        var isNight: Bool
        var style: CoachingStyle
        var experience: DrivingExperience
        /// First family contact, used by the emotional style.
        var lovedOne: String?
    }

    static func message(for input: Input) -> CoachingMessage {
        let snapshot = input.snapshot
        let comparison = DrivingComparison.make(snapshot: snapshot, advice: input.advice, isDriving: true)
        let friction = input.weather?.condition.roadFriction ?? 0.7
        let place = (input.isNight ? "dark " : "") + snapshot.environment.label

        switch comparison.status {
        case .tooFast, .caution:
            guard let recommended = comparison.recommendedMaxMPH, snapshot.speedMPH > recommended + 2 else {
                return harshEvents(input)
            }
            let now = stoppingDistanceFeet(mph: snapshot.speedMPH, friction: friction)
            let safer = stoppingDistanceFeet(mph: recommended, friction: friction)
            let severity: CoachingMessage.Severity = comparison.status == .tooFast ? .warning : .caution
            switch input.style {
            case .logical:
                let delay = minutesLost(overMiles: 10, from: snapshot.speedMPH, to: recommended)
                var body = "At \(Int(snapshot.speedMPH)) mph on a \(place), you need about \(now) ft to stop"
                body += input.weather?.condition.isWet == true ? " on wet pavement" : ""
                body += input.isNight ? " — low beams only light ~200 ft." : "."
                body += " At \(Int(recommended)) mph that drops to \(safer) ft. Over 10 miles you'd lose about \(delay) min."
                return CoachingMessage(title: "Slow to \(Int(recommended)) mph", body: body, severity: severity)
            case .emotional:
                let who = input.lovedOne ?? "the people who love you"
                let body = "\(who.prefix(1).uppercased() + who.dropFirst()) would rather you get home a few minutes late. "
                    + "On a \(place), watch for \(snapshot.environment.hazard). Easing to \(Int(recommended)) mph gives you room to react."
                return CoachingMessage(title: "Let's take it easy", body: body, severity: severity)
            }
        case .noData, .onTrack:
            if snapshot.hardBrakes >= 3 { return harshEvents(input) }
            switch input.style {
            case .logical:
                return CoachingMessage(
                    title: "Right on target",
                    body: "\(Int(snapshot.speedMPH)) mph suits these conditions. Keep a \(input.advice.followingSeconds)-second gap to the car ahead.",
                    severity: .positive)
            case .emotional:
                return CoachingMessage(
                    title: "You're driving beautifully",
                    body: "Calm and steady — exactly how you make it home safe tonight.",
                    severity: .positive)
            }
        }
    }

    private static func harshEvents(_ input: Input) -> CoachingMessage {
        let count = input.snapshot.hardBrakes
        switch input.style {
        case .logical:
            return CoachingMessage(
                title: "\(count) hard brakes",
                body: "Hard braking means you're following too close. A \(input.advice.followingSeconds)-second gap gives you time to slow down smoothly.",
                severity: .caution)
        case .emotional:
            return CoachingMessage(
                title: "Give yourself some space",
                body: "A little more room ahead means fewer surprises — and a calmer drive for everyone in the car.",
                severity: .caution)
        }
    }

    /// Reaction distance (1.5 s) + braking distance v² / (2 μ g), in feet.
    static func stoppingDistanceFeet(mph: Double, friction: Double) -> Int {
        let v = mph * 0.44704
        let meters = v * 1.5 + (v * v) / (2 * friction * 9.81)
        return Int((meters * 3.28084 / 5).rounded() * 5)
    }

    static func minutesLost(overMiles miles: Double, from fast: Double, to slow: Double) -> Int {
        guard fast > 0, slow > 0 else { return 0 }
        return max(1, Int(((miles / slow - miles / fast) * 60).rounded()))
    }
}
