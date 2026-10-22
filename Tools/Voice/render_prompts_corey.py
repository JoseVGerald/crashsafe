"""Re-records the crash check-in's fixed lines in Pulse's voice, Cartesia "Corey - Supportive Buddy", so
the check-in sounds the same as Pulse even offline and locked (the clips ship in the app; no key does).

    python3 -I Tools/Voice/render_prompts_corey.py Backend/rag/.env CrashSafe/Resources/Voice

Reads CARTESIA_API_KEY from the given .env (git-ignored). Same lines and file names as render_prompts.py
(the Kokoro version, kept as an offline alternative).
"""
import json, subprocess, sys, urllib.request
from pathlib import Path

COREY = "630ed21c-2c5c-41cf-9d82-10a7fd668370"
LINES = {
    "checkin-tap-ok": "Are you okay? Tap I'm OK if you're all right.",
    "checkin-10s": "Are you okay? If you don't answer in 10 seconds, I'll sound an alarm and call for help.",
    "checkin-5s": "Are you okay? 5 seconds.",
    "checkin-glad": "Okay. I'm glad you're okay.",
    "checkin-help": "Getting you help.",
}

env = dict(l.strip().split("=", 1) for l in open(sys.argv[1]) if "=" in l and not l.startswith("#"))
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
for name, text in LINES.items():
    req = urllib.request.Request("https://api.cartesia.ai/tts/bytes", json.dumps({
        "model_id": "sonic-3", "transcript": text, "language": "en", "voice": {"mode": "id", "id": COREY},
        "output_format": {"container": "wav", "encoding": "pcm_s16le", "sample_rate": 44100}}).encode(),
        {"X-API-Key": env["CARTESIA_API_KEY"], "Cartesia-Version": "2025-04-16", "Content-Type": "application/json"})
    wav = out / f"{name}.wav"
    wav.write_bytes(urllib.request.urlopen(req, timeout=30).read())
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", str(wav), str(out / f"{name}.m4a")], check=True)
    wav.unlink()
    print(name, "ok")
