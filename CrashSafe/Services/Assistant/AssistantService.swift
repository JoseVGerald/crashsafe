import Foundation

/// Why the assistant was opened — changes how it greets the driver.
enum AssistantScenario: Equatable, Sendable {
    case general
    /// Driver answered the check-in ("I'm OK") — the conscious path.
    case afterCrash(CheckInOutcome)
}

/// Everything the assistant may use to tailor answers. Built from the on-device profile.
struct AssistantContext: Sendable {
    var userName: String
    var isOnline: Bool
    var scenario: AssistantScenario
    var carDescription: String
    var insurer: String
    var medicalNotes: String
    var familyContactNames: [String]
    var currentTrip: String?
    var responseStyle = "practical"
    var jurisdiction = "UNKNOWN"
    var assistanceStage = "active"
    var incident: AssistantIncident? = nil
    /// What the phone's motion says the driver is doing now (transport mode, recent harsh events).
    var activity: AssistantActivity? = nil
    /// One per conversation, so Pulse's agent on the backend remembers earlier turns (random, not tied to the person).
    var conversationID: String? = nil
}

/// Derived from the rolling sensor history by `MotionIntelligence`; no raw telemetry.
nonisolated struct AssistantActivity: Codable, Sendable, Equatable {
    var transport: AssistantIncident.Transport
    var harshBrakes10min: Int
    var harshAccels10min: Int

    // Snake-case conversion doesn't split before digits; pin the backend's names.
    enum CodingKeys: String, CodingKey {
        case transport
        case harshBrakes10min = "harsh_brakes_10min"
        case harshAccels10min = "harsh_accels_10min"
    }
}

/// The conscious-path assistant.
///
/// AI TEAM: implement `CloudAssistantService` (online, calls *our* server — never put
/// API keys in the app) and `OnDeviceAssistantService` (Apple Foundation Models + trip pack),
/// then pick between them in `AppEnvironment` based on `ConnectivityMonitor.isOnline`.
protocol AssistantService: AnyObject {
    /// First message shown when the chat opens.
    func greeting(for context: AssistantContext) -> String
    /// Reply to the latest user message given the full history.
    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String
    /// What Pulse asked the app to offer with its last reply ("emergency_call_prompt", "find_tow"). The app only
    /// shows these as buttons; nothing happens until the person taps one.
    var requestedActions: [String] { get }
}

extension AssistantService {
    var requestedActions: [String] { [] }
}

/// Returns canned, safety-first replies based on simple keywords.
final class MockAssistantService: AssistantService {
    private let latency: Duration

    init(latency: Duration = .milliseconds(900)) {
        self.latency = latency
    }

    func greeting(for context: AssistantContext) -> String {
        let name = context.userName.split(separator: " ").first.map(String.init) ?? "there"
        switch context.scenario {
        case .general:
            return "Hi \(name). I'm here if anything happens on the road. Ask me about towing, insurance, or what to do after a crash."
        case .afterCrash(.ok):
            return "I'm glad you're responding, \(name). Take a slow breath. First things first: are you somewhere safe, away from traffic? If anyone is hurt, call 911 now."
        case .afterCrash(.needsHelp):
            return "Help comes first. If you haven't already, call 911 — the button is at the top of this screen. I cannot confirm family alert delivery. Tell me what's happening and I'll stay with you."
        case .afterCrash(.noResponse):
            return "No response was recorded. I cannot confirm family alert delivery. If you're awake now: are you hurt? If yes, call 911 first."
        }
    }

    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        try await Task.sleep(for: latency)
        let last = history.last(where: { $0.role == .user })?.text.lowercased() ?? ""
        let suffix = context.isOnline ? "" : "\n\n(Offline — using your saved trip pack.)"

        if last.containsAny("hurt", "pain", "bleed", "injur", "dizzy") {
            return "If you or anyone else is hurt, call 911 now — that comes before anything else. Don't move someone with neck or back pain unless there's fire or traffic danger." + suffix
        }
        if last.containsAny("tow", "stuck", "won't start", "wont start") {
            return "I found tow companies near you in your trip pack. I'd suggest calling the closest one yourself and asking for the total price before they hook up your car. Want me to show the list?" + suffix
        }
        if last.containsAny("insur", "claim") {
            let insurer = context.insurer.isEmpty ? "your insurer" : context.insurer
            return "Report it to \(insurer) promptly — most policies require it. Stick to facts: time, place, weather, what you saw. Don't guess or admit fault at the scene. (Not legal advice.)" + suffix
        }
        if last.containsAny("photo", "picture", "document", "record") {
            return "Once you're safe: photograph all vehicles from each corner, license plates, the road, signs, and anything like rain or darkness. Swap names, phone numbers, and insurance with the other driver." + suffix
        }
        if last.containsAny("scared", "panic", "shaking", "anxious", "nervous") {
            return "That's a normal reaction. Let's slow down together: breathe in for 4, hold for 4, out for 6. You don't need to decide anything right this second." + suffix
        }
        return "Got it. Here's the order I'd go in: 1) make sure everyone is safe, 2) call 911 if anyone's hurt, 3) document the scene, 4) arrange a tow, 5) notify your insurer. Which one should we start with?" + suffix
    }
}

private extension String {
    func containsAny(_ needles: String...) -> Bool {
        needles.contains { contains($0) }
    }
}


// MARK: - Source-backed local and server assistant

nonisolated struct AssistantIncident: Codable, Sendable {
    nonisolated struct Transport: Codable, Sendable, Equatable {
        var label: String
        var basis: String
        /// Set when `basis` is "model".
        var probability: Double? = nil
        var modelId: String? = nil
    }
    /// Matches the backend's behavior event schema (`incident_context.py`).
    nonisolated struct BehaviorEvent: Codable, Sendable, Equatable {
        var kind: String
        var start: Double
        var end: Double
        var severity: Double
    }
    /// Matches `motion_intel.normalize_impact` (snake_case on the wire).
    nonisolated struct Impact: Codable, Sendable, Equatable {
        var peakG: Double
        var pulseDurationS: Double
        var deltaVMps: Double
        var preImpactSpeedMps: Double?
        var postImpactSpeedMps: Double?
        var timeToStopS: Double?
        var stopBasis: String?
        var averageStopDecelerationG: Double?
        var severity: String
        var isSimulated: Bool

        init(_ r: ImpactReport) {
            peakG = r.peakG; pulseDurationS = r.pulseDuration; deltaVMps = r.deltaVMPS
            preImpactSpeedMps = r.preImpactSpeedMPS; postImpactSpeedMps = r.postImpactSpeedMPS
            timeToStopS = r.timeToStop; stopBasis = r.stopBasis; averageStopDecelerationG = r.averageStopDecelerationG
            severity = r.severity.rawValue; isSimulated = r.isSimulated
        }
    }
    var schemaVersion = 1
    var capturedAt: String
    var isSimulated: Bool
    var decision: String
    var evidence: [String]
    var issues: [String]
    var peakG: Double
    var speedDropMps: Double?
    var transport: Transport
    var behaviorEvents: [BehaviorEvent]? = nil
    var impact: Impact? = nil

    @MainActor static func make(event: CrashEvent) -> Self {
        let assessment = event.assessment
        return Self(capturedAt: event.date.ISO8601Format(),
                    isSimulated: event.isSimulated,
                    decision: assessment?.decision.rawValue ?? "inconclusive",
                    evidence: assessment?.evidence.map(\.rawValue) ?? [],
                    issues: assessment?.issues.map(\.rawValue) ?? [],
                    peakG: event.peakG,
                    speedDropMps: assessment?.speedDropMPS,
                    transport: Transport(label: assessment?.candidate.transportationMode.rawValue ?? "unknown",
                                         basis: assessment == nil ? "unknown" : "profile"),
                    impact: event.impact.map(Impact.init))
    }
}

private struct LocalKnowledgeCard: Sendable {
    let id: String
    let title: String
    let terms: String
    let body: String
    let scope: String
    let stage: String
    let expires: String
    let sources: [String]
}

/// Small bundled evidence cards; does not depend on a model, network or trip-pack availability.
final class LocalEvidenceAssistant: AssistantService {
    private static func words(_ value: String) -> Set<String> {
        let aliases = ["insurer": "insurance", "claims": "insurance", "claim": "insurance",
                       "scared": "panic", "shaking": "panic", "panicking": "panic",
                       "photos": "photographs", "pictures": "photographs",
                       "electric": "ev", "accident": "collision", "crash": "collision"]
        let stop: Set<String> = ["the","a","an","i","my","me","to","is","it","what","how","do","should",
                                 "can","of","for","and","you","after","about","have","are"]
        return Set(value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }.map { aliases[$0] ?? $0 })
    }

    /// Answers from the app's own measurements (rolling sensor history), never from guesses.
    static func motionReply(_ query: String, context: AssistantContext) -> String? {
        let text = query.lowercased()
        let asksImpact = ["how hard", "impact", "how fast was", "speed change", "how bad was", "g-force", "g force"]
            .contains(where: text.contains)
        let asksActivity = ["what am i doing", "am i driving", "am i walking", "what mode", "my activity", "detect"]
            .contains(where: text.contains)
        let asksDriving = ["brake", "braking", "how am i driving", "driving behavior", "accelerat"].contains(where: text.contains)
        if asksImpact, let impact = context.incident?.impact {
            let mph = Int((impact.deltaVMps * 2.23694).rounded())
            var answer = "Your phone measured a \(impact.severity) impact: a peak of about \(Int(impact.peakG.rounded())) g "
                + "and a speed change of roughly \(mph) mph over \(Int((impact.pulseDurationS * 1000).rounded())) ms."
            if let stop = impact.timeToStopS { answer += String(format: " The car stopped about %.1f s after the hit.", stop) }
            if impact.isSimulated { answer += " (This was a test crash with simulated data.)" }
            return answer + " It's an estimate from the phone's sensors, not a medical assessment — if anyone is hurt, call 911."
        }
        if asksActivity, let activity = context.activity {
            let mode = TransportClass.allCases.first { $0.label == activity.transport.label }
            guard let mode else {
                return "I can't tell yet — the last few seconds of motion don't clearly match one mode."
            }
            let score = Int(((activity.transport.probability ?? 0) * 100).rounded())
            return "From your phone's motion over the last few seconds, it looks like you're \(mode.title.lowercased()) "
                + "(model score \(score)%). That's a pattern match, not a certainty."
        }
        if asksDriving, let activity = context.activity {
            let brakes = activity.harshBrakes10min, accels = activity.harshAccels10min
            if brakes + accels == 0 { return "No harsh braking or acceleration in the last 10 minutes. Nice and smooth." }
            return "In the last 10 minutes: \(brakes) hard brake\(brakes == 1 ? "" : "s") and \(accels) hard acceleration\(accels == 1 ? "" : "s"). "
                + "Leaving a bigger gap ahead gives you more time to slow down gently."
        }
        return nil
    }

    static func emergencyReply(_ query: String) -> String? {
        let text = query.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let historical = ["last week","last month","years ago","yesterday","hypothetically","what if"]
            .contains { text.contains($0) }
        if historical && !text.contains("now") && !text.contains("currently") { return nil }
        if ["on fire","flames","smoke coming","car is burning"].contains(where: text.contains) {
            return "Call 911 now. If you can get out, move away from the burning vehicle and traffic. Do not return or try to fight the fire. [S10]"
        }
        let checked = text.replacingOccurrences(of: "nobody is unconscious", with: "")
            .replacingOccurrences(of: "no one is unconscious", with: "")
            .replacingOccurrences(of: "not unconscious", with: "")
        if ["not breathing","isn't breathing","won't wake","not waking up","unresponsive","unconscious","passed out",
            "can't breathe","cannot breathe","trouble breathing","chest hurts","chest pain",
            "bleeding heavily","severe bleeding","seizure","headache getting worse"].contains(where: checked.contains) {
            return "Call 911 now and follow the call-taker's instructions. Describe the symptoms. This assistant has not contacted emergency services. [S01, S03, S08]"
        }
        return nil
    }

    func greeting(for context: AssistantContext) -> String {
        switch context.scenario {
        case .general:
            return "I can help with crash procedures, documentation and insurance questions. Tell me what you need."
        case .afterCrash(.ok):
            return "I'm glad you can respond. Are you away from immediate danger? If anyone needs urgent help, call 911."
        case .afterCrash(.needsHelp):
            return "If you need urgent help, call 911 now. I cannot confirm that any family alert was delivered."
        case .afterCrash(.noResponse):
            return "No response was recorded. That does not establish unconsciousness or confirm that an alert was delivered. If you need urgent help, call 911."
        }
    }

    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        let query = history.last(where: { $0.role == .user })?.text ?? ""
        if let urgent = Self.emergencyReply(query) { return urgent }
        if let measured = Self.motionReply(query, context: context) { return measured }
        let today = String(Date().ISO8601Format().prefix(10))
        let terms = Self.words(query)
        let ranked = Self.cards.compactMap { card -> (LocalKnowledgeCard, Int)? in
            guard card.expires >= today,
                  card.scope == "US" || card.scope == context.jurisdiction,
                  card.stage == "any" || card.stage == context.assistanceStage else { return nil }
            let score = Self.words(card.title + " " + card.terms).intersection(terms).count * 3
                + Self.words(card.body).intersection(terms).count
            return score >= 3 ? (card, score) : nil
        }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        let cards = ranked.prefix(context.assistanceStage == "active" ? 1 : 2).map(\.0)
        guard !cards.isEmpty else {
            return "I don't have current, supported information for that question and location. If you are safe and need paperwork help, select follow-up mode. For urgent danger, call 911."
        }
        let intro = context.responseStyle == "supportive" ? "We can take this one step at a time.\n\n" : ""
        let bodies = cards.map { $0.body + " [" + $0.id + "]" }.joined(separator: "\n\n")
        let sources = Array(Set(cards.flatMap(\.sources))).sorted().compactMap { Self.sourceLinks[$0] }.joined(separator: "\n")
        return intro + bodies + "\n\nSources:\n" + sources
    }

    // Generated from the same editorial corpus as the server, with identical expiry and scope.
    // BEGIN GENERATED KNOWLEDGE
    private static let cards: [LocalKnowledgeCard] = [
        LocalKnowledgeCard(id: "CALL_911", title: "What to tell the emergency call-taker", terms: "911 emergency address location callback ambulance dispatcher", body: "Tell the 911 call-taker your location, callback number, what happened, and the injuries or hazards you can observe. Answer their questions, follow their instructions, and stay on the line until told to hang up. This assistant does not place the call or confirm dispatch.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S01"]),
        LocalKnowledgeCard(id: "TEXT_911", title: "Calling versus texting 911", terms: "text deaf hearing speech cannot call emergency", body: "Call 911 by voice if you can. Text-to-911 availability varies; do not assume it works at your location. If you cannot speak, use an available local emergency text option and provide the location and type of emergency.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S02"]),
        LocalKnowledgeCard(id: "MOVEMENT", title: "Possible neck back or head injury", terms: "neck back spine spinal hurt get out exit stand walk move injured", body: "With a possible head, neck or back injury, do not move the person simply to make them more comfortable. An immediate safety threat or essential lifesaving care can change what is necessary. Follow emergency-call instructions; do not use an automatic always-exit or always-stay rule.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S04", "S05"]),
        LocalKnowledgeCard(id: "BLEEDING", title: "Serious external bleeding", terms: "bleed blood wound bleeding pressure", body: "For life-threatening external bleeding, call 911 and follow emergency instructions. If it is safe to help, apply firm direct pressure to the wound. Do not remove an embedded object; pressure is applied around it. Advanced measures require appropriate training.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S06"]),
        LocalKnowledgeCard(id: "HEAD_INJURY", title: "Head injury symptoms and danger signs", terms: "head concussion headache vomiting dizzy dizziness confusion pupil seizure sleepy symptoms", body: "After a possible head injury, worsening headache, repeated vomiting, seizures, unusual confusion or difficulty waking require emergency medical care. Symptoms can appear later. Being able to talk does not establish that someone is uninjured.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S08"]),
        LocalKnowledgeCard(id: "FIRE", title: "Vehicle on fire", terms: "fire flames burning smoke car hood trunk", body: "If the vehicle catches fire, get out if you can, stay at least 100 feet away and away from traffic, and call 911. Do not return for belongings, fight the fire yourself or open a hood or trunk where you suspect fire.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S10"]),
        LocalKnowledgeCard(id: "EV", title: "Electric and hybrid vehicle damage and towing", terms: "electric hybrid ev high voltage battery tow towing", body: "Damaged electric or hybrid high-voltage systems may remain energized, and fire or hazardous gases can occur later. Do not touch exposed electrical parts or attempt repairs. Tell responders and towing personnel the vehicle type. Follow the correct owner's manual for towing requirements.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S11"]),
        LocalKnowledgeCard(id: "CAR_SEAT", title: "Car seat replacement after a collision", terms: "child infant baby booster car seat replace replacement", body: "NHTSA recommends replacing car seats after moderate or severe crashes. A minor-crash exception requires all five conditions: vehicle driven away; nearest door undamaged; no occupant injuries; no deployed airbags; no visible seat damage. Always follow the seat manufacturer's instructions.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S12"]),
        LocalKnowledgeCard(id: "CALM_SUPPORT", title: "Support when overwhelmed", terms: "panic scared afraid crying overwhelmed nervous terrified emotional kindness calm", body: "A frightening event can leave people anxious, upset or unable to concentrate. Once immediate safety needs are addressed, focus on one manageable task and consider contacting someone you trust. You do not have to recount the event in detail to receive practical help.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S16", "S13"]),
        LocalKnowledgeCard(id: "FOLLOWUP_EMOTION", title: "When to seek emotional support after a crash", terms: "nightmares sleep sleeping flashbacks anxiety trauma ptsd weeks mental health therapist", body: "If distress does not improve, worsens or interferes with daily life, talk with a qualified health professional. Supportive friends or relatives and ordinary routines can help during recovery. This assistant does not diagnose PTSD or provide trauma therapy.", scope: "US", stage: "followup", expires: "2027-01-19", sources: ["S16"]),
        LocalKnowledgeCard(id: "WA_EXCHANGE", title: "Washington required exchange of information", terms: "wa washington exchange details license policy number name address other driver", body: "In Washington, collision duties include exchanging name, address, insurance company and policy number, vehicle license number, and showing a driver's license as required by RCW 46.52.020. The law also describes stopping, remaining at the appropriate location and providing reasonable assistance to injured people.", scope: "WA", stage: "any", expires: "2027-01-19", sources: ["S21"]),
        LocalKnowledgeCard(id: "WA_MOVE", title: "Washington moving vehicles after property damage only", terms: "wa washington move moving vehicle traffic lane shoulder property damage only fender bender", body: "Washington's property-damage-only branch requires moving the vehicle from the roadway to a suitable location as soon as possible and remaining there to fulfill the required duties. The statute says moving the vehicle does not determine fault. Injury crashes have a separate branch; do not move an injured person just to reposition a car.", scope: "WA", stage: "any", expires: "2027-01-19", sources: ["S21"]),
        LocalKnowledgeCard(id: "WA_REPORT", title: "Washington collision report conditions and deadline", terms: "wa washington report reporting file deadline days four 4 1000 thousand officer police paperwork", body: "For qualifying Washington collisions, a driver report is generally due within four days unless a law-enforcement report is to be made. WSP's portal identifies injury or at least $1,000 damage to any one unit, with an exception when the officer indicates they will file. Confirm that an officer will submit it; attendance alone is not that confirmation.", scope: "WA", stage: "followup", expires: "2027-01-19", sources: ["S22", "S23"]),
        LocalKnowledgeCard(id: "DOCUMENT", title: "Information and photographs for an insurance claim", terms: "document documentation evidence photographs photos pictures witness weather dashcam plate damage", body: "Once it is safe, record the time, date, location, vehicle information, witness contacts and responding officer or report details. Photograph the scene and damage only from safe positions. Record what you actually observed and distinguish unknown details from estimates.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S29"]),
        LocalKnowledgeCard(id: "CLAIM_NOTICE", title: "Notify your insurer and keep a claim record", terms: "insurance notify notification report claim contact adjuster investigation notes receipts", body: "Notify your insurer as soon as possible and cooperate with the claim investigation. Keep notes of conversations, dates and decisions. Ask for written explanations when you do not understand a claim decision.", scope: "US", stage: "followup", expires: "2027-01-19", sources: ["S29"]),
        LocalKnowledgeCard(id: "STATEMENT", title: "Recorded statement and cooperation questions", terms: "recorded statement recording insurer adjuster refuse never must own other insurance", body: "Before answering a statement request, establish which insurer the person represents and check your own policy's cooperation requirements. A claims investigation may include a written or recorded statement. There is no universal rule to refuse every statement. If obligations or release terms are unclear, seek qualified advice.", scope: "US", stage: "followup", expires: "2027-01-19", sources: ["S29", "S30"]),
        LocalKnowledgeCard(id: "TRUTHFUL", title: "Accurate accounts and uncertain details", terms: "fault blame admit truth truthful lie lying hide phone using speed guess unsure remember don't know", body: "Describe what you actually saw and did. Do not invent a precise speed, guess at legal responsibility, hide relevant facts or exaggerate injuries. If you do not know a detail, say so; identify a genuine estimate as an estimate and correct mistakes when you discover them.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S29", "S30"]),
        LocalKnowledgeCard(id: "COVERAGE", title: "Coverage cannot be inferred from a generic guide", terms: "insurance coverage cover covered policy deductible rental rent tow medical reimbursement benefits", body: "Check the actual policy and endorsements for coverage, exclusions, limits, deductibles and duties after a loss. A generic guide cannot establish that towing, a rental vehicle, repairs or medical costs are covered. Ask the insurer to identify the applicable terms in writing.", scope: "US", stage: "followup", expires: "2027-01-19", sources: ["S30"]),
        LocalKnowledgeCard(id: "DISPUTE", title: "Disputed settlement or claim decision", terms: "settlement offer deny denied denial dispute unfair pay payout release sign written complaint", body: "You do not need to feel rushed into an insurance settlement you do not understand. Ask for a written explanation of the decision and review the relevant policy terms. If a claim-handling dispute remains unresolved, contact your state insurance department; legal questions may need a qualified lawyer.", scope: "US", stage: "followup", expires: "2027-01-19", sources: ["S29"]),
        LocalKnowledgeCard(id: "SILENCE", title: "No response does not prove unconsciousness", terms: "silence silent not responding microphone sensor unconscious unconsciousness detection passed out", body: "No response from a phone user does not establish that the person is unconscious. Communication can fail. This prototype cannot determine consciousness or automatically dispatch emergency services; a real system needs separately validated detection and escalation procedures.", scope: "US", stage: "any", expires: "2027-01-19", sources: ["S01", "S03"]),
        LocalKnowledgeCard(id: "CONCUSSION_RETURN", title: "Driving and work after a concussion", terms: "concussion driving return work school recovery written instructions", body: "After a suspected concussion, seek medical assessment. Ask your healthcare provider for written instructions about returning to driving, work and school. Tell them if symptoms worsen or are not improving; this assistant cannot clear you to drive.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S36"]),
        LocalKnowledgeCard(id: "AIRBAG_REPLACE", title: "Deployed air bags need replacement", terms: "airbag air bags deployed deployment replace drive repair", body: "Air bags work only once. Have deployed air bags replaced at an authorized repair center before driving again. Deployment can itself cause injuries; have medical concerns assessed rather than judging injury from vehicle appearance.", scope: "US", stage: "any", expires: "2027-01-20", sources: ["S37"]),
        LocalKnowledgeCard(id: "AIRBAG_LIMIT", title: "Air bag deployment does not measure injury", terms: "airbag did not deploy no deployment minor collision injury severity", body: "Whether air bags deploy depends on the crash and vehicle system. Air bags may deploy in some relatively minor crashes and may not deploy in others. Their deployment alone cannot establish whether someone is injured or needs medical care.", scope: "US", stage: "any", expires: "2027-01-20", sources: ["S37"]),
        LocalKnowledgeCard(id: "INTERNAL_BLEED", title: "Delayed or suspected internal bleeding", terms: "internal bleeding delayed abdomen abdominal swollen rigid bruising blood vomit urine", body: "Internal bleeding may become apparent hours or days after an injury. Suspected internal bleeding, including blood in vomit or urine, a tender swollen or rigid abdomen, or signs of shock, needs emergency medical help. Call 911 and describe what you observe; do not wait for visible external bleeding.", scope: "US", stage: "any", expires: "2027-01-20", sources: ["S38"]),
        LocalKnowledgeCard(id: "CHEST_INJURY", title: "Chest injury and breathing problems", terms: "chest rib ribs injury breathing painful severe bruising coughing blood", body: "After chest trauma, trouble breathing, severe pain or bruising, unusual chest movement, or coughing blood requires immediate emergency medical help. Call 911 and follow the call-taker's instructions. Do not assume these symptoms are anxiety.", scope: "US", stage: "any", expires: "2027-01-20", sources: ["S39"]),
        LocalKnowledgeCard(id: "ASK_SUPPORT", title: "Ask a trusted person for concrete help", terms: "trusted friend family support help tasks paperwork ride alone isolated", body: "Once immediate safety needs are addressed, consider asking someone you trust for a specific kind of help, such as company or help with paperwork. You can choose whom to involve and explain what would help; support does not require telling everyone the full story.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S40"]),
        LocalKnowledgeCard(id: "OPTIONAL_CALM", title: "Calming exercises should be optional", terms: "breathing exercise relaxation meditation makes worse distress stop calming", body: "In a safe setting after the emergency, relaxation may help some people but can initially increase distress for others. Choose a manageable approach and tell a clinician if it makes you feel worse. New physical symptoms after a crash still need medical assessment.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S40"]),
        LocalKnowledgeCard(id: "GROUNDING", title: "Present surroundings during a flashback", terms: "grounding flashback reliving memories present surroundings eyes open", body: "In a safe setting, if a memory feels as though it is happening again, keeping your eyes open and noticing your present surroundings may help orient you. Contact a trusted person or clinician for support. This is optional coping support, not a PTSD diagnosis or treatment.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S40"]),
        LocalKnowledgeCard(id: "AVOID_SELF_MEDICATING", title: "Alcohol and drugs are not a recovery plan", terms: "alcohol drugs drink sleep self medicate nightmares substance coping", body: "Using alcohol or drugs to escape traumatic memories or get to sleep can create further problems. If you are relying on them to cope, speak with a healthcare professional about support and safer treatment options. This assistant does not prescribe or change medication.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S41"]),
        LocalKnowledgeCard(id: "CHILD_SUPPORT", title: "Supporting a child after a crash", terms: "child children teenager teen crying scared parent caregiver trauma comfort", body: "After addressing safety and medical needs, offer a calm, supportive environment and familiar routines. Let a child cry or express feelings in words or drawings. Do not force them to recount the crash, demand bravery, or promise a recovery timeline you cannot know.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S20"]),
        LocalKnowledgeCard(id: "CHILD_FOLLOWUP", title: "When a child needs more emotional support", terms: "child nightmares bedwetting school withdrawn behavior weeks provider pediatrician", body: "Watch for new difficulties with sleep, school, behavior or withdrawal after a traumatic event. Contact the child's healthcare provider when new problems develop, especially when distressing reactions continue for weeks. Support is available without asking the app to diagnose the child.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S20"]),
        LocalKnowledgeCard(id: "OR_REPORT", title: "Oregon DMV collision report deadlines", terms: "Oregon DMV report reporting deadline 72 hours 2500 police separate", body: "In Oregon, file a DMV collision report within 72 hours for injury or death, damage to your vehicle over $2,500, damage to any vehicle over $2,500 with any vehicle towed, or nonvehicle property damage over $2,500. A police report does not replace this DMV report. If late, submit as soon as possible.", scope: "OR", stage: "followup", expires: "2027-01-20", sources: ["S42"]),
        LocalKnowledgeCard(id: "OR_FILE", title: "Submitting an Oregon collision report", terms: "Oregon DMV2U online paper form download copy report license ID", body: "Oregon DMV2U online collision reporting requires that you were an involved driver and have an Oregon license, permit or ID number. Otherwise use the paper process. Save a copy of your submitted report; Oregon DMV cannot provide you a copy under the cited rule.", scope: "OR", stage: "followup", expires: "2027-01-20", sources: ["S42"]),
        LocalKnowledgeCard(id: "OR_SCENE", title: "Oregon scene duties and police notification", terms: "Oregon stop exchange police notify scene information license address plate", body: "In Oregon, stop and exchange name, address, driver-license number, plate and insurance information. Immediately notify police when DMV reporting criteria are met; use a nonemergency number for nonemergencies and 911 for emergencies. Do not carelessly move injured people.", scope: "OR", stage: "any", expires: "2027-01-20", sources: ["S42"]),
        LocalKnowledgeCard(id: "CA_REPORT", title: "California SR-1 reporting deadline", terms: "California DMV SR1 SR-1 report deadline 10 days 1000 police separate", body: "In California, submit an SR-1 to DMV within 10 days when anyone is injured, however slightly, someone dies, or property damage exceeds $1,000. This report is separate from police, CHP and insurance reports. A driver, insurance agent, broker or legal representative may submit it.", scope: "CA", stage: "followup", expires: "2027-01-20", sources: ["S43"]),
        LocalKnowledgeCard(id: "CA_FILE", title: "Information for a California SR-1", terms: "California SR1 DMV form information VIN plate driver license insurance", body: "For California's SR-1, gather your driver-license or ID details, vehicle plate or VIN, insurance details and available information about the other party and vehicle. Use the official DMV process and keep your reporting obligations separate from your insurance claim.", scope: "CA", stage: "followup", expires: "2027-01-20", sources: ["S43"]),
        LocalKnowledgeCard(id: "WA_UNATTENDED", title: "Washington collision with an unattended car", terms: "Washington parked unattended unoccupied car note owner address", body: "In Washington, if you strike an unattended vehicle, stop immediately. Locate and notify its owner or operator, or leave a conspicuous written notice in the struck vehicle with the names and addresses of both the driver and owner of the striking vehicle. Other reporting duties may also apply.", scope: "WA", stage: "any", expires: "2027-01-20", sources: ["S44"]),
        LocalKnowledgeCard(id: "REPAIR_ESTIMATE", title: "Written repair estimates and authorization", terms: "repair body shop estimate authorization signed extra charges diagnostic second opinion", body: "Before authorizing repairs, ask for a signed written estimate identifying the repair, parts and labor charges. Ask that the shop obtain approval before exceeding an agreed amount. Ask about diagnostic fees and consider a second opinion for expensive or complicated work; specific legal rights vary by state.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S45"]),
        LocalKnowledgeCard(id: "REPAIR_PARTS", title: "Questions about replacement parts", terms: "repair parts OEM aftermarket used salvage remanufactured warranty", body: "Ask what replacement parts the shop proposes and what warranties cover parts and labor. New, remanufactured and salvage parts differ. A certification alone does not guarantee good work; ask about experience with your vehicle's make and model.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S45"]),
        LocalKnowledgeCard(id: "COLLISION_COVERAGE", title: "Collision versus liability coverage", terms: "collision liability comprehensive insurance own car damage other person", body: "Collision coverage generally addresses damage to your own car from a collision; liability coverage addresses covered harm you cause to others. Comprehensive coverage generally addresses other specified losses. Your policy, limits, deductibles and exclusions control the actual result; ask your insurer which coverage applies.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S46"]),
        LocalKnowledgeCard(id: "GAP_LOAN", title: "A total loss may leave an auto loan balance", terms: "GAP loan finance owe balance totaled total loss actual cash value", body: "A vehicle's value may be less than the loan balance. A vehicle-damage settlement may therefore leave money owed to the lender. Ask whether you purchased GAP coverage and what its terms cover; do not assume ordinary auto insurance pays the entire loan.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S46"]),
        LocalKnowledgeCard(id: "UM_UIM", title: "Uninsured and underinsured coverage questions", terms: "uninsured underinsured hit run UM UIM other driver no insurance", body: "Ask your insurer whether you have applicable uninsured or underinsured motorist coverage when the other driver has no insurance or insufficient insurance. Hit-and-run eligibility and reporting requirements depend on the policy and state. Coverage is not established by the other driver's insurance status alone.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S46"]),
        LocalKnowledgeCard(id: "RENTAL_TOW", title: "Rental and towing coverage are policy dependent", terms: "rental reimbursement tow towing roadside limits storage receipt coverage", body: "Rental reimbursement and roadside or towing coverage are separate coverage questions. Ask your insurer whether you purchased them, what limits and conditions apply, and what documentation is needed before assuming a bill will be reimbursed.", scope: "US", stage: "followup", expires: "2027-01-20", sources: ["S46"]),
        LocalKnowledgeCard(id: "WA_PIP", title: "Washington PIP is offered but can be rejected", terms: "Washington PIP personal injury protection offered optional written rejection", body: "Washington law requires PIP to be offered with new or renewed auto liability policies, subject to statutory exceptions. A named insured may reject it in writing, and that rejection may carry forward. Ask your insurer to confirm your coverage and any rejection; PIP is not automatically present on every policy.", scope: "WA", stage: "followup", expires: "2027-01-20", sources: ["S47"]),
        LocalKnowledgeCard(id: "WA_INSPECTION", title: "Washington photo estimate disagreement", terms: "Washington photo virtual inspection disagreement in person five business days estimate", body: "Under Washington's rule effective October 18, 2026, insurers cannot require a photo-only damage evaluation as a coverage condition. After virtual inspection, if there is a disagreement over the loss amount, they must accept a requested in-person inspection and inspect within five business days or another mutually agreed time.", scope: "WA", stage: "followup", expires: "2027-01-20", sources: ["S48"]),
        LocalKnowledgeCard(id: "WA_TOW_FEES", title: "Washington written towing and storage coverage explanation", terms: "Washington towing storage fees written explanation five business days first party", body: "Washington's rule effective October 18, 2026 requires an insurer to give a first-party claimant a clear written explanation of applicable storage and towing coverage within five business days of claim notification. This is an explanation requirement, not a promise that every charge is covered.", scope: "WA", stage: "followup", expires: "2027-01-20", sources: ["S48"]),
        LocalKnowledgeCard(id: "WA_REPAIR_DIFFERENCE", title: "Washington repair estimate differences", terms: "Washington repair estimate difference supplemental damage policy reasons written", body: "In Washington, when an insurer's repair amount differs from your repair estimate, ask for its reasons and relevant policy provisions. The current rule requires explanations for differences and consideration of additional crash-related damage. Choosing a more expensive repair facility may leave you responsible for amounts above the insurer's estimate.", scope: "WA", stage: "followup", expires: "2027-01-20", sources: ["S48"]),
    ]
    private static let sourceLinks: [String: String] = [
        "S01": "Calling 911: https://www.911.gov/calling-911/",
        "S02": "Frequently asked questions about calling 911: https://www.911.gov/calling-911/frequently-asked-questions/",
        "S03": "First Aid Steps: https://www.redcross.org/take-a-class/first-aid/performing-first-aid/first-aid-steps",
        "S04": "Head Neck and Spinal Injury: https://www.redcross.org/take-a-class/resources/learn-first-aid/head-neck-spinal-injury",
        "S05": "Unresponsive and Breathing Person: https://www.redcross.org/take-a-class/resources/learn-first-aid/unresponsive-and-breathing-person",
        "S06": "Life Threatening External Bleeding: https://www.redcross.org/take-a-class/resources/learn-first-aid/bleeding-life-threatening-external",
        "S07": "Shock: https://www.redcross.org/take-a-class/resources/learn-first-aid/shock",
        "S08": "Symptoms of Mild TBI and Concussion: https://www.cdc.gov/traumatic-brain-injury/signs-symptoms/index.html",
        "S09": "Signs and Symptoms of Concussion: https://www.cdc.gov/heads-up/signs-symptoms/index.html",
        "S10": "Vehicle Fire Safety: https://www.usfa.fema.gov/prevention/vehicle-fires/",
        "S11": "Electric and Hybrid Vehicles: https://www.nhtsa.gov/vehicle-safety/electric-and-hybrid-vehicles",
        "S12": "Car Seat Use After a Crash: https://www.nhtsa.gov/car-seats-and-booster-seats/car-seat-use-after-crash",
        "S13": "Psychological First Aid Guide for Field Workers: https://www.who.int/publications/i/item/9789241548205",
        "S14": "Psychological First Aid Field Operations Guide: https://www.ptsd.va.gov/disaster_events/for_providers/psychological_first_aid.asp",
        "S15": "Common Reactions After Trauma: https://www.ptsd.va.gov/understand/isitptsd/common_reactions.asp",
        "S16": "Coping With Traumatic Events: https://www.nimh.nih.gov/health/topics/coping-with-traumatic-events",
        "S17": "Trauma Informed Approaches and Programs: https://www.samhsa.gov/mental-health/trauma-violence/trauma-informed-approaches-programs",
        "S18": "Recommendations for PTSD NG116: https://www.nice.org.uk/guidance/ng116/chapter/recommendations",
        "S19": "Skills for Psychological Recovery Field Operations Guide: https://www.ptsd.va.gov/disaster_events/for_providers/skills_psych_recovery.asp",
        "S20": "Helping Children and Adolescents Cope With Traumatic Events: https://www.nimh.nih.gov/health/publications/helping-children-and-adolescents-cope-with-disasters-and-other-traumatic-events",
        "S21": "RCW 46.52.020 Duties After a Collision: https://app.leg.wa.gov/rcw/default.aspx?cite=46.52.020",
        "S22": "RCW 46.52.030 Accident Reports: https://app.leg.wa.gov/rcw/default.aspx?cite=46.52.030",
        "S23": "Online Motor Vehicle Collision Reporting: https://wrecr.wsp.wa.gov/omvcr",
        "S24": "Reporting Collision Damage: https://dol.wa.gov/driver-licenses-and-permits/driver-safety/reporting-collision-damage",
        "S25": "Filing an Auto Insurance Claim: https://www.insurance.wa.gov/insurance-resources/auto-insurance/auto-insurance-claims/filing-auto-insurance-claim",
        "S26": "Personal Injury Protection: https://www.insurance.wa.gov/insurance-resources/auto-insurance/how-auto-insurance-works/personal-injury-protection-pip",
        "S27": "What Happens After Your Car Gets Totaled: https://www.insurance.wa.gov/insurance-resources/auto-insurance/auto-insurance-claims/what-happens-after-your-car-gets-totaled",
        "S28": "File a Complaint or Check Complaint Status: https://www.insurance.wa.gov/complaints-appeals-fraud/complaints/file-complaint-or-check-your-complaint-status",
        "S29": "What You Should Know About Filing an Auto Claim: https://content.naic.org/article/what-you-should-know-about-filing-auto-claim",
        "S30": "So You Have Had an Accident What Is Next: https://www.insurance.ca.gov/01-consumers/105-type/95-guides/01-auto/hadaccident.cfm",
        "S31": "Auto Insurance: https://content.naic.org/insurance-topics/auto-insurance",
        "S32": "Car Repair Laws: https://www.atg.wa.gov/car-repair-laws",
        "S33": "Mobile Health App Developers FTC Best Practices: https://www.ftc.gov/business-guidance/resources/mobile-health-app-developers-ftc-best-practices",
        "S34": "Complying With the Health Breach Notification Rule: https://www.ftc.gov/business-guidance/resources/complying-ftcs-health-breach-notification-rule-0",
        "S35": "Protecting Washingtonians Personal Health Data and Privacy: https://www.atg.wa.gov/protecting-washingtonians-personal-health-data-and-privacy",
        "S36": "What to Do After a Mild TBI or Concussion: https://www.cdc.gov/traumatic-brain-injury/response/index.html",
        "S37": "Vehicle Air Bags and Injury Prevention: https://www.nhtsa.gov/vehicle-safety/air-bags",
        "S38": "Life-Threatening Internal Bleeding: https://www.redcross.org/take-a-class/resources/learn-first-aid/bleeding-life-threatening-internal",
        "S39": "Chest Injury: https://www.redcross.org/take-a-class/resources/learn-first-aid/chest-injury",
        "S40": "Coping with Traumatic Stress Reactions: https://www.ptsd.va.gov/gethelp/coping_stress_reactions.asp",
        "S41": "Negative Coping and PTSD: https://www.ptsd.va.gov/gethelp/negative_coping.asp",
        "S42": "Collision Reporting and Responsibilities: https://www.oregon.gov/odot/dmv/pages/driverid/accidentreport.aspx",
        "S43": "Report of Traffic Accident Occurring in California SR-1: https://www.dmv.ca.gov/portal/dmv-virtual-office/accident-reporting/",
        "S44": "Duty on striking unattended car or other property: https://app.leg.wa.gov/rcw/default.aspx?cite=46.52.010",
        "S45": "Auto Repair Basics: https://consumer.ftc.gov/articles/0211-auto-repair-basics",
        "S46": "What Does Auto Insurance Cover?: https://content.naic.org/article/what-you-should-know-about-auto-insurance-coverage",
        "S47": "Optional personal injury protection coverage and rejection: https://app.leg.wa.gov/rcw/default.aspx?cite=48.22.085",
        "S48": "Unfair motor vehicle claims settlement practices: https://app.leg.wa.gov/wac/default.aspx?cite=284-30-390",
    ]
    // END GENERATED KNOWLEDGE
}

/// Sends only the current question, tone, explicit jurisdiction/stage and minimal sensor summary.
/// Names, policy numbers, medical notes, contact names and precise location are not serialized.
final class RAGAssistantService: AssistantService {
    private let endpoint: URL?
    private let fallback = LocalEvidenceAssistant()
    private let session: URLSession
    private(set) var requestedActions: [String] = []

    init(endpoint: URL?, session: URLSession? = nil) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.injectedSession = session
    }
    private let injectedSession: URLSession?

    static func configured() -> RAGAssistantService {
        RAGAssistantService(endpoint: PulseBackend.endpoint())
    }

    /// Conversation takes a model turn (≈0.5–2 s, more when the free model is busy).
    private lazy var conversationSession: URLSession = injectedSession ?? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 9
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func greeting(for context: AssistantContext) -> String { fallback.greeting(for: context) }

    func reply(to history: [ChatMessage], context: AssistantContext) async throws -> String {
        let query = history.last(where: { $0.role == .user })?.text ?? ""
        requestedActions = []
        if let urgent = LocalEvidenceAssistant.emergencyReply(query) {
            requestedActions = ["emergency_call_prompt"]
            return urgent
        }
        // Questions about the phone's own measurements are answered from those measurements.
        if let measured = LocalEvidenceAssistant.motionReply(query, context: context) { return measured }
        guard context.isOnline, let endpoint else {
            return try await fallback.reply(to: history, context: context)
        }
        // Pulse as a companion (the team's Pulse core on the server), then the verified evidence answer.
        if let conversational = try await converse(history, context: context, endpoint: endpoint) {
            return conversational
        }
        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/assist"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            PulseBackend.authorize(&request)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(Request(query: query,
                jurisdiction: context.jurisdiction, stage: context.assistanceStage,
                persona: context.responseStyle, incident: context.incident, activity: context.activity))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count < 100_000 else { throw URLError(.badServerResponse) }
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard ["answered","emergency","insufficient_evidence","review_required"].contains(result.status),
                  !result.answer.isEmpty else { throw URLError(.cannotParseResponse) }
            let sources = result.citations.map { "\($0.title): \($0.url)" }.joined(separator: "\n")
            return result.answer + (sources.isEmpty ? "" : "\n\nSources:\n" + sources)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback.reply(to: history, context: context)
        }
    }

    /// `POST /v1/converse`: the last turns go along. With a conversation id the team's Pulse agent answers and keeps
    /// the conversation in its memory (30 idle minutes at most, never on disk); otherwise the server keeps nothing.
    private func converse(_ history: [ChatMessage], context: AssistantContext, endpoint: URL) async throws -> String? {
        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/converse"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            PulseBackend.authorize(&request)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let turns = history.suffix(12).map { ConverseRequest.Turn(role: $0.role == .user ? "user" : "assistant", text: $0.text) }
            request.httpBody = try encoder.encode(ConverseRequest(messages: turns, conversationId: context.conversationID,
                jurisdiction: context.jurisdiction, stage: context.assistanceStage,
                incident: context.incident, activity: context.activity))
            let (data, response) = try await conversationSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 100_000 else { return nil }
            let result = try JSONDecoder().decode(Response.self, from: data)
            guard ["answered", "emergency"].contains(result.status), !result.answer.isEmpty else { return nil }
            requestedActions = (result.actions ?? [])
                .filter { ["offered", "requested", "app_action_requested"].contains($0.status) }
                .map(\.action)
            let sources = result.citations.map { "\($0.title): \($0.url)" }.joined(separator: "\n")
            return result.answer + (sources.isEmpty ? "" : "\n\nSources:\n" + sources)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private nonisolated struct ConverseRequest: Encodable {
        nonisolated struct Turn: Encodable { let role: String; let text: String }
        let messages: [Turn]
        let conversationId: String?
        let jurisdiction: String
        let stage: String
        let incident: AssistantIncident?
        let activity: AssistantActivity?
    }

    private nonisolated struct Request: Encodable {
        let query: String
        let jurisdiction: String
        let stage: String
        let persona: String
        let incident: AssistantIncident?
        let activity: AssistantActivity?
    }
    private nonisolated struct Response: Decodable {
        nonisolated struct Citation: Decodable { let title: String; let url: String }
        nonisolated struct Action: Decodable { let action: String; let status: String }
        let status: String
        let answer: String
        let citations: [Citation]
        var actions: [Action]? = nil
    }
}
