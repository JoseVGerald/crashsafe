"""Pre-records the crash check-in's fixed lines in a natural neural voice, so the most important
moment sounds human even when no Premium iOS voice is installed.

Kokoro-82M (Apache 2.0, https://huggingface.co/hexgrad/Kokoro-82M) via kokoro-onnx (MIT). Runs on a
Mac; only the small .m4a clips ship in the app.

    python -m venv venv && venv/bin/pip install kokoro-onnx soundfile
    # model files: https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0
    venv/bin/python Tools/Voice/render_prompts.py <model-dir> CrashSafe/Resources/Voice

Keep LINES in sync with CrashResponseCenter.promptText and escalate() (a unit test checks).
"""
import subprocess
import sys
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro

VOICE = "af_heart"
SPEED = 0.95
LINES = {
    "checkin-tap-ok": "Are you okay? Tap I'm OK if you're all right.",
    "checkin-10s": "Are you okay? If you don't answer in 10 seconds, I'll sound an alarm and call for help.",
    "checkin-5s": "Are you okay? 5 seconds.",
    "checkin-glad": "Okay. I'm glad you're okay.",
    "checkin-help": "Getting you help.",
}

model_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)
kokoro = Kokoro(str(model_dir / "kokoro-v1.0.onnx"), str(model_dir / "voices-v1.0.bin"))
for name, text in LINES.items():
    samples, rate = kokoro.create(text, voice=VOICE, speed=SPEED, lang="en-us")
    wav = out_dir / f"{name}.wav"
    sf.write(wav, samples, rate)
    m4a = out_dir / f"{name}.m4a"
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", str(wav), str(m4a)], check=True)
    wav.unlink()
    print(f"{name}: {len(samples) / rate:.1f} s")
