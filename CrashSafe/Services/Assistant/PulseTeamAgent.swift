import Foundation
import SQLite3

/// The team's Pulse agent prompt, assembled on the phone exactly as pulse_agent builds each model request
/// (hooks/always_core.py `prepend`):
///   system 1  core.md (the Core; it already contains the hard lines)
///   system 2  [PULSE_TURN]       context/schema.py `build_turn`: mode, mode focus, app flags, data contract
///   system 3  [PULSE_KNOWLEDGE]  knowledge/retrieve.py `Knowledge.search`: their FTS5 notes (optional)
///   then the conversation, trimmed to their 5,000-token budget.
/// The data comes from the team's code via Tools/Pulse/export_team_pulse.py, and CrashSafeTests compare this
/// port's output with theirs.
enum PulseTeamAgent {
    /// The two tools the app can offer (the team's tiers: pre-approved prompts, never actions).
    static let tools: [[String: String]] = [["name": "emergency_call_prompt", "tier": "pre_approved"],
                                            ["name": "find_tow", "tier": "pre_approved"]]
    static let core = resource("pulse_core", "txt") ?? ""
    static let coreMini = resource("pulse_core_mini", "txt") ?? ""

    private static let data: (contract: String, acknowledgment: [String: Any], modes: [String: String], headerCost: Int) = {
        let json = resource("pulse_turn", "json").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        return (json?["data_contract"] as? String ?? "", json?["tool_acknowledgment"] as? [String: Any] ?? [:],
                json?["modes"] as? [String: String] ?? [:], json?["knowledge_header_cost"] as? Int ?? 7)
    }()

    /// Tokens of the "[PULSE_KNOWLEDGE]" header, as the team's tokenizer counts it.
    static var knowledgeHeaderCost: Int { data.headerCost }

    // MARK: [PULSE_TURN]

    /// The team's mode for this moment: crisis support after a detected crash, aftermath for follow-up help,
    /// otherwise standby (their "normal assistant" mode).
    static func mode(stage: String, incident: AssistantIncident?) -> String {
        stage == "followup" ? "aftermath" : incident != nil ? "crisis_support" : "standby"
    }

    static func crash(from incident: AssistantIncident?, now: Date = .now) -> [String: Any] {
        var crash: [String: Any] = ["severity": "unknown", "seconds_since_crash": NSNull(), "location": NSNull(),
                                    "location_source": "unknown"]
        guard let incident else { return crash }
        if let severity = incident.impact?.severity, ["minor", "moderate", "severe"].contains(severity) {
            crash["severity"] = severity
        }
        if let at = try? Date(incident.capturedAt, strategy: .iso8601) {
            crash["seconds_since_crash"] = max(0, Int(now.timeIntervalSince(at).rounded()))
        }
        if incident.isSimulated { crash["simulated"] = true }
        return crash
    }

    /// `build_turn`: the per-turn context block, byte for byte as the team's code writes it.
    static func turn(text: String, mode: String, connectivity: String, crash: [String: Any]) -> String {
        let flags = signals(text)
        var payload: [String: Any] = [
            "mode": mode, "mode_focus": data.modes[mode] ?? "",
            "condition": Dictionary(uniqueKeysWithValues: ["injury_risk", "distress", "clarity", "engagement",
                                                           "environmental_danger", "ability_to_act"].map { ($0, "unknown") }),
            "profile": [String: Any](), "crash": crash, "connectivity": connectivity, "tools": tools,
            "app_flags": ["possible_self_harm": flags.selfHarm, "medication_question": flags.medication],
            "tool_acknowledgment": data.acknowledgment, "data_contract": data.contract]
        if connectivity == "offline" { payload["offline_focus"] = data.modes["offline_overlay"] ?? "" }
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "[PULSE_TURN]\n" + json
    }

    /// `signals`: the team's conservative app flags (never a risk score).
    static func signals(_ text: String) -> (selfHarm: Bool, medication: Bool) {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let harm = #"kill myself|hurt myself|end (?:my life|it all)|want to die|didn't make it|did not make it|better off dead|wish i (?:was|were) dead|jok(?:e|ing).{0,30}(?:die|kill myself)"#
        let dosing = #"dose|dosage|how much.{0,50}(?:tylenol|medicine|kid|child)|(?:take|give).{0,20}(?:ibuprofen|aspirin|tylenol|pills|tablets)"#
        return (t.range(of: harm, options: .regularExpression) != nil, t.range(of: dosing, options: .regularExpression) != nil)
    }

    // MARK: The request

    /// `prepend`: Core, turn and knowledge as app-owned system messages, then the conversation. Over the
    /// 5,000-token budget, optional knowledge goes first, then the oldest complete turns. (Sizes here are
    /// estimated at 4 characters per token; the team counts with tiktoken.)
    static func messages(history: [ChatMessage], turn: String, knowledge: String) -> [[String: Any]] {
        var conversation: [[String: Any]] = history.suffix(40).compactMap { message in
            let text = (message.role == .user ? message.text : PulseSpeaker.spokenPart(of: message.text))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ["role": message.role == .user ? "user" : "assistant", "content": String(text.prefix(2000))]
        }
        var prefix: [[String: Any]] = [["role": "system", "content": core], ["role": "system", "content": turn]]
        if !knowledge.isEmpty { prefix.append(["role": "system", "content": knowledge]) }
        func size() -> Int {
            let json = (try? JSONSerialization.data(withJSONObject: prefix + conversation)).map(\.count) ?? 0
            return (json + 1_100) / 4  // + the tool definitions
        }
        if size() > 5000 && prefix.count > 2 { prefix = Array(prefix.prefix(2)) }
        while size() > 5000, conversation.filter({ $0["role"] as? String == "user" }).count > 1,
              let next = conversation.indices.dropFirst().first(where: { conversation[$0]["role"] as? String == "user" }) {
            conversation = Array(conversation[next...])
        }
        return prefix + conversation
    }

    /// What the team's agent says when every model sentence was filtered out.
    static func localFallback(medication: Bool) -> String {
        medication ? "I can't give a medication dose." : "I'm here. What do you need right now?"
    }

    static func resource(_ name: String, _ ext: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// The team's knowledge index (knowledge/retrieve.py): their 108 notes in SQLite FTS5 with the porter
/// tokenizer, the same bm25 weights, mode/state filters, relevance cut-off, two-example limit and 1,500-token
/// budget. iOS's own SQLite runs their query unchanged.
final class PulseKnowledgeIndex {
    static let shared = PulseKnowledgeIndex()
    private static let stopWords = Set("""
        a an the and or but i me my we us our you your they their he she it its
        is am are was were be been being do does did have has had can could would should will
        what which who how when where why this that these those of to for from at in on into
        off with without after before about as if then just so not no anyone everyone nobody
        someone something anything tell say ask please need want once first also very really
        synthetic test testing crash accident pulse pulled over minor reports
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    private struct Note { let rendered: String; let text: String; let kind: String; let cost: Int }
    private var db: OpaquePointer?  // In memory, for the life of the app (one shared index).
    private var notes: [String: Note] = [:]

    init(json: String? = PulseTeamAgent.resource("pulse_knowledge", "json")) {
        guard let json, let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]],
              sqlite3_open(":memory:", &db) == SQLITE_OK else { return }
        exec("""
            CREATE TABLE chunks(id TEXT PRIMARY KEY, modes TEXT, states TEXT, kind TEXT, priority INTEGER);
            CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED,title,text,tokenize='porter unicode61');
            """)
        for row in rows {
            guard let id = row["id"] as? String, let text = row["text"] as? String, let title = row["title"] as? String,
                  let rendered = row["rendered"] as? String, let kind = row["kind"] as? String,
                  let cost = row["cost"] as? Int, let priority = row["priority"] as? Int,
                  let modes = row["modes"], let states = row["states"],
                  let modesJSON = try? JSONSerialization.data(withJSONObject: modes),
                  let statesJSON = try? JSONSerialization.data(withJSONObject: states) else { continue }
            notes[id] = Note(rendered: rendered, text: text, kind: kind, cost: cost)
            run("INSERT INTO chunks VALUES(?,?,?,?,?)", [id, String(decoding: modesJSON, as: UTF8.self),
                                                        String(decoding: statesJSON, as: UTF8.self), kind, priority])
            run("INSERT INTO search VALUES(?,?,?)", [id, title, text])
        }
    }

    /// `Knowledge.search`: the notes for this turn as one [PULSE_KNOWLEDGE] block, best first.
    func search(_ text: String, mode: String, connectivity: String, cap: Int = 1500) -> (text: String, ids: [String]) {
        if ["crash_check", "unresponsive_escalation"].contains(mode) || connectivity == "offline" { return ("", []) }
        var seenWords = Set<String>()
        let words = text.lowercased().matches(of: /[^\W_]+/).map { String($0.output) }
            .filter { seenWords.insert($0).inserted && !Self.stopWords.contains($0) }.prefix(16)
        let query = words.filter { $0.count > 2 }.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
        guard !query.isEmpty else { return ("", []) }
        let rows = run("""
            SELECT c.id,bm25(search,0,8,1) AS relevance FROM search s JOIN chunks c ON c.id=s.id
            WHERE search MATCH ? AND EXISTS(SELECT 1 FROM json_each(c.modes) WHERE value=?)
            AND EXISTS(SELECT 1 FROM json_each(c.states) WHERE value IN (SELECT value FROM json_each(?)))
            ORDER BY relevance, c.priority, c.id LIMIT 100
            """, [query, mode, #"["steady"]"#])
        var chosen: [String] = [], seenText = Set<String>(), examples = 0
        var used = PulseTeamAgent.knowledgeHeaderCost
        let best = -(rows.first?.score ?? 0)
        for row in rows {
            guard -row.score >= best * 0.6, let note = notes[row.id] else { continue }  // no weak, incidental matches
            let body = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if seenText.contains(body) || (note.kind == "example" && examples >= 2) || used + note.cost + 2 > min(cap, 1500) { continue }
            chosen.append(row.id)
            seenText.insert(body)
            used += note.cost + 2
            if note.kind == "example" { examples += 1 }
        }
        guard !chosen.isEmpty else { return ("", []) }
        return ("[PULSE_KNOWLEDGE]\n" + chosen.compactMap { notes[$0]?.rendered }.joined(separator: "\n\n"), chosen)
    }

    // MARK: SQLite

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    @discardableResult
    private func run(_ sql: String, _ values: [Any]) -> [(id: String, score: Double)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            if let text = value as? String { sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient) }
            if let number = value as? Int { sqlite3_bind_int64(statement, Int32(index + 1), Int64(number)) }
        }
        var rows: [(String, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_count(statement) == 2 {
            rows.append((String(cString: sqlite3_column_text(statement, 0)), sqlite3_column_double(statement, 1)))
        }
        return rows
    }
}
