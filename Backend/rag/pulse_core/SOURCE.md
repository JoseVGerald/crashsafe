# Pulse core (from the team's voice assistant)

Copied from https://github.com/udaykamboj/pulse-voice-assistant at commit 85af5f8
(`pulse_agent/core/core.md`, `pulse_agent/core/core_mini.md`, `pulse_agent/core/hard_lines.md`, `pulse_agent/guardrails/sentence_filter.py`), unchanged.

- `core.md`: Pulse's persona and safety rules (calm first, 911 first when there is danger, one step at a time,
  no medication doses, no false "help is on the way").
- `core_mini.md`: the short version the team wrote for the phone's own model. The app no longer uses it: on Apple's
  ~3B on-device model its packed rules and no examples gave replies like "You are hurt. Call 911." for a stubbed toe,
  so the app has its own prompt for that model (`CrashSafe/Resources/Pulse/pulse_on_device.txt`).
- `hard_lines.md`: never delay emergency help, never certify someone is fine, never diagnose.
- `sentence_filter.py`: deterministic check on every sentence before it is spoken.

Used by `pulse_voice.py` for `POST /v1/converse` and `POST /v1/tts`.
