"""The Pulse backend as one cloud service (see ../Dockerfile): the team's Pulse agent on 127.0.0.1:7862 inside the
container, and our API (rag.py) on 0.0.0.0:$PORT for the app.

Configuration is the host's secrets, as environment variables:
    OPENROUTER_API_KEY, CARTESIA_API_KEY   model and Corey voice
    PULSE_AUTH_SECRET                      shared by our API and the agent (32+ characters)
    PULSE_APP_TOKEN                        what the app sends as X-Pulse-Token (32+ characters)
Every request needs the app token except GET /healthz (the host's liveness check). When either part stops,
this exits so the host restarts the whole service.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path

import rag

AGENT = Path(os.environ.get("PULSE_AGENT_DIR", "/app/agent/pulse_agent"))
AGENT_PYTHON = os.environ.get("PULSE_AGENT_PYTHON", "/opt/agent/bin/python")


def require(name):
    value = os.environ.get(name, "")
    if len(value) < (32 if name in ("PULSE_AUTH_SECRET", "PULSE_APP_TOKEN") else 1):
        sys.exit(f"Missing secret {name}")
    return value


def start_agent():
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp"),
           "PYTHONPATH": f"{AGENT.parent}:{AGENT}", "TMPDIR": "/tmp",
           "OPENROUTER_API_KEY": require("OPENROUTER_API_KEY"), "PULSE_AUTH_SECRET": require("PULSE_AUTH_SECRET")}
    agent = subprocess.Popen([AGENT_PYTHON, "-m", "pulse_agent.service"], cwd=AGENT, env=env)

    def watch():
        code = agent.wait()
        print(f"Pulse agent stopped ({code}); restarting the service", flush=True)
        os._exit(1)
    threading.Thread(target=watch, daemon=True).start()
    return agent


def main():
    token = require("PULSE_APP_TOKEN")
    for name in ("CARTESIA_API_KEY",):
        require(name)
    agent = start_agent()
    engine = rag.Engine(rag.ROOT / "data" / "knowledge.sqlite3")
    port = int(os.environ.get("PORT", "8080"))
    # Nothing is trusted by address: the host's proxy forwards every request, so every request shows its token.
    server = rag.make_server(engine, port, host="0.0.0.0", lan_token=token, trusted=())
    print(f"Pulse backend listening on :{port}", flush=True)
    try:
        server.serve_forever()
    finally:
        agent.terminate()
        server.server_close()
        engine.close()


if __name__ == "__main__":
    main()
