# Pulse core (from the team's voice assistant)

Copied from https://github.com/udaykamboj/pulse-voice-assistant at commit 85af5f8
(`pulse_agent/core/core.md`, `pulse_agent/core/hard_lines.md`, `pulse_agent/guardrails/sentence_filter.py`), unchanged.

- `core.md`: Pulse's persona and safety rules (calm first, 911 first when there is danger, one step at a time,
  no medication doses, no false "help is on the way").
- `hard_lines.md`: never delay emergency help, never certify someone is fine, never diagnose.
- `sentence_filter.py`: deterministic check on every sentence before it is spoken.

Used by `pulse_voice.py` for `POST /v1/converse` and `POST /v1/tts`.
