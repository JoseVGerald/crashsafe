"""Runs the team's Pulse agent (udaykamboj/pulse-voice-assistant, pulse_agent/) on 127.0.0.1:7862 for pulse_voice.py.

    python run_pulse_agent.py setup   # once: clone the pinned commit, install its dependencies, build its indexes
    python run_pulse_agent.py         # run it (loopback only), with OPENROUTER_API_KEY and PULSE_AUTH_SECRET from .env

The agent's code stays in Backend/external/ (git-ignored) exactly as the team wrote it; nothing here edits it.
Keys are passed in the environment, never on the command line or into the team's checkout.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from pulse_voice import load_env

REPO = "https://github.com/udaykamboj/pulse-voice-assistant"
COMMIT = "85af5f8"  # The version this backend was built and tested against.
CHECKOUT = Path(__file__).resolve().parents[1] / "external" / "pulse-voice-assistant"
AGENT = CHECKOUT / "pulse_agent"
PYTHON = CHECKOUT / ".venv" / "bin" / "python"


def setup():
    if not CHECKOUT.exists():
        subprocess.run(["git", "clone", REPO, str(CHECKOUT)], check=True)
    subprocess.run(["git", "-C", str(CHECKOUT), "checkout", "--quiet", COMMIT], check=True)
    if not PYTHON.exists():
        subprocess.run([sys.executable, "-m", "venv", str(CHECKOUT / ".venv")], check=True)
    subprocess.run([str(PYTHON), "-m", "pip", "install", "-q", "-r", str(AGENT / "requirements.txt")], check=True)
    for script in ("build_core.py", "build_knowledge.py", "build_index.py"):
        subprocess.run([str(PYTHON), str(AGENT / "scripts" / script)], cwd=AGENT, env=agent_env({}), check=True)


def agent_env(env):
    (AGENT / "runtime" / "tmp").mkdir(parents=True, exist_ok=True)
    # The same paths the team's Makefile sets.
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", ""),
            "PYTHONPATH": f"{CHECKOUT}:{AGENT}", "TMPDIR": str(AGENT / "runtime" / "tmp"), **env}


def run():
    values = load_env()
    secret, key = values.get("PULSE_AUTH_SECRET", ""), values.get("OPENROUTER_API_KEY", "")
    if len(secret) < 32 or not key:
        sys.exit("Set OPENROUTER_API_KEY and PULSE_AUTH_SECRET (32+ characters) in Backend/rag/.env")
    if not PYTHON.exists():
        sys.exit("Run `python run_pulse_agent.py setup` first")
    env = agent_env({"OPENROUTER_API_KEY": key, "PULSE_AUTH_SECRET": secret})
    os.chdir(AGENT)
    os.execve(str(PYTHON), [str(PYTHON), "-m", "pulse_agent.service"], env)


if __name__ == "__main__":
    setup() if sys.argv[1:] == ["setup"] else run()
