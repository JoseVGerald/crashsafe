import Foundation

/// A spoken/visual nudge from Pulse while driving.
struct CoachingMessage: Equatable {
    enum Severity { case positive, caution, warning }

    let title: String
    let body: String
    let severity: Severity
    /// Pulse only speaks out loud when the driver is over the speed limit; everything else is on screen only.
    var speaksAloud = false
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

    /// How far over the limit before Pulse speaks: a little room for speedometer/GPS wobble, more when
    /// the limit is only the typical one for that kind of road.
    static func speakingThreshold(limit: Double, isPosted: Bool) -> Double {
        limit + (isPosted ? 4 : 9)
    }

    static func message(for input: Input) -> CoachingMessage {
        let snapshot = input.snapshot
        if let limit = snapshot.speedLimitMPH,
           snapshot.speedMPH > speakingThreshold(limit: limit, isPosted: snapshot.speedLimitIsPosted) {
            return speeding(input, limit: limit)
        }
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

    /// "Imagine…" — what speeding would turn a near miss into, from the car's real speed and the road.
    static func speeding(_ input: Input, limit: Double) -> CoachingMessage {
        let snapshot = input.snapshot
        let speed = snapshot.speedMPH
        let friction = input.weather?.condition.roadFriction ?? 0.7
        let hazardDistance = stoppingDistanceFeet(mph: limit, friction: friction)
        let impact = impactSpeedMPH(from: speed, obstacleFeet: Double(hazardDistance), friction: friction)
        let limitText = snapshot.speedLimitIsPosted ? "a \(Int(limit))" : "a road that's usually \(Int(limit))"
        let place = (input.isNight ? "dark " : "") + snapshot.environment.label
        let over = speed - limit
        let severity: CoachingMessage.Severity = over >= max(7, limit * 0.15) ? .warning : .caution
        let title = "Slow to \(Int(limit)) mph"
        let what = Self.hazard(for: snapshot.environment)

        let consequence: String = switch snapshot.environment {
        case .city:
            "At \(Int(limit)) you'd stop in time. At \(Int(speed)) you'd still hit them at about \(impact) mph"
                + (impact >= 20 ? " — \(pedestrianRisk(impactMPH: Double(impact)))." : ".")
        case .highway, .forest:
            "At \(Int(limit)) you'd stop in time. At \(Int(speed)) you'd hit at about \(impact) mph — "
                + "like falling \(storiesEquivalent(impactMPH: Double(impact)))."
        }

        switch input.style {
        case .logical:
            let body = "You're doing \(Int(speed)) in \(limitText) on a \(place). Imagine \(what) \(hazardDistance) ft ahead. "
                + consequence + " You need \(stoppingDistanceFeet(mph: speed, friction: friction)) ft to stop at this speed."
            return CoachingMessage(title: title, body: body, severity: severity, speaksAloud: true)
        case .emotional:
            let who = input.lovedOne ?? "the people who love you"
            let body = "\(who.prefix(1).uppercased() + who.dropFirst()) is waiting for you to get home. "
                + "Imagine \(what) right now. At \(Int(limit)) you'd stop in time; at \(Int(speed)) you wouldn't. "
                + "Please ease back to \(Int(limit))."
            return CoachingMessage(title: title, body: body, severity: severity, speaksAloud: true)
        }
    }

    static func hazard(for environment: RoadEnvironment) -> String {
        switch environment {
        case .city: "a child running out from between parked cars"
        case .highway: "traffic stopped just past a curve"
        case .forest: "a deer stepping onto the road"
        }
    }

    /// Speed (mph) at which the car reaches an obstacle `obstacleFeet` ahead, after 1.5 s of reaction
    /// and hard braking at friction μ. 0 means it stops in time.
    static func impactSpeedMPH(from mph: Double, obstacleFeet: Double, friction: Double) -> Int {
        let v = mph * 0.44704
        let distance = obstacleFeet / 3.28084
        let braking = distance - v * 1.5
        guard braking > 0 else { return Int(mph.rounded()) }
        let squared = v * v - 2 * friction * 9.81 * braking
        return squared <= 0 ? 0 : Int((squared.squareRoot() / 0.44704).rounded())
    }

    /// Risk of death for a pedestrian struck at this speed (AAA Foundation, Tefft 2011:
    /// 10% at 23 mph, 25% at 32, 50% at 42, 75% at 50, 90% at 58).
    static func pedestrianRisk(impactMPH: Double) -> String {
        let curve: [(Double, Double)] = [(0, 0), (23, 10), (32, 25), (42, 50), (50, 75), (58, 90), (80, 98)]
        var risk = 98.0
        for (a, b) in zip(curve, curve.dropFirst()) where impactMPH <= b.0 {
            risk = a.1 + (b.1 - a.1) * (impactMPH - a.0) / (b.0 - a.0)
            break
        }
        let oneIn = max(1, Int((100 / max(risk, 1)).rounded()))
        return oneIn <= 1 ? "most people hit that hard don't survive" : "about 1 in \(oneIn) people hit that hard don't survive"
    }

    /// The fall with the same impact speed: h = v² / 2g, in stories (~3 m each).
    static func storiesEquivalent(impactMPH: Double) -> String {
        let v = impactMPH * 0.44704
        let stories = Int((v * v / (2 * 9.81) / 3).rounded())
        return stories <= 1 ? "off a one-story roof" : "off a \(stories)-story building"
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
