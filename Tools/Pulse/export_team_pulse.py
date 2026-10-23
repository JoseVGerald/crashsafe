"""Exports the team's Pulse agent data for the app, using the team's own code (pulse_agent at the pinned commit):

    CrashSafe/Resources/Pulse/pulse_knowledge.json   the 108 knowledge notes, rendered exactly as the agent injects
                                                     them, with exact token costs (tiktoken, as the agent counts)
    CrashSafe/Resources/Pulse/pulse_turn.json        mode paragraphs, offline focus and the data contract that
                                                     build_turn() puts in every [PULSE_TURN]
    CrashSafeTests/Fixtures/pulse_golden.json        build_turn() and Knowledge.search() outputs the Swift port
                                                     must reproduce exactly

Run with the team's environment (python Backend/rag/run_pulse_agent.py setup first):
    Backend/external/pulse-voice-assistant/.venv/bin/python Tools/Pulse/export_team_pulse.py
"""
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AGENT = REPO / "Backend/external/pulse-voice-assistant"
sys.path[:0] = [str(AGENT), str(AGENT / "pulse_agent")]

import yaml  # noqa: E402
from pulse_agent.context.schema import MODES, TurnContext, build_turn  # noqa: E402
from pulse_agent.knowledge.retrieve import Knowledge  # noqa: E402
from pulse_agent.scripts.common import tokens  # noqa: E402

TOOLS = [{"name": "emergency_call_prompt", "tier": "pre_approved"}, {"name": "find_tow", "tier": "pre_approved"}]


def main():
    knowledge = Knowledge(Path(tempfile.mkdtemp()) / "knowledge.sqlite")
    notes = []
    for ident, (item, rendered, cost) in knowledge.rendered.items():
        notes.append({"id": ident, "title": item["source_section"], "text": item["text"], "modes": item["applies_to_modes"],
                      "states": item["applies_to_states"], "kind": item["kind"], "priority": item["priority"],
                      "rendered": rendered, "cost": cost})
    notes.sort(key=lambda n: n["id"])
    header_cost = tokens("[PULSE_KNOWLEDGE]\n")

    sample = json.loads(build_turn(TurnContext(), "hello", TOOLS)[len("[PULSE_TURN]\n"):])
    turn = {"data_contract": sample["data_contract"], "tool_acknowledgment": sample["tool_acknowledgment"],
            "modes": {name: mode["paragraph"] for name, mode in MODES.items()}, "knowledge_header_cost": header_cost}

    cases = [("standby", "online", "I stubbed my toe", {}), ("standby", "online", "I think a bomb is coming towards me", {}),
             ("crisis_support", "online", "I just got rear-ended at a red light and I'm shaking", {"severity": "moderate", "seconds_since_crash": 40}),
             ("crisis_support", "online", "how much tylenol can I give my kid", {}),
             ("aftermath", "online", "the insurance adjuster wants a recorded statement", {}),
             ("crisis_support", "offline", "I want to die", {}), ("crash_check", "online", "are you there", {})]
    golden = []
    for mode, connectivity, text, crash in cases:
        context = TurnContext(mode=mode, connectivity=connectivity)
        context.crash.update(crash)
        golden.append({"mode": mode, "connectivity": connectivity, "text": text, "crash": context.crash,
                       "turn": build_turn(context, text, TOOLS), "knowledge_ids": knowledge.search(text, context)["ids"]})

    out = REPO / "CrashSafe/Resources/Pulse"
    (out / "pulse_knowledge.json").write_text(json.dumps(notes, ensure_ascii=False, indent=0) + "\n", encoding="utf-8")
    (out / "pulse_turn.json").write_text(json.dumps(turn, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    (REPO / "CrashSafeTests/Fixtures/pulse_golden.json").write_text(json.dumps(golden, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(notes)} notes, {len(turn['modes'])} modes, {len(golden)} golden cases")


if __name__ == "__main__":
    main()
