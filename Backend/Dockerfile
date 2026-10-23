# The Pulse backend as one cloud service: our API (rag/) and the team's Pulse agent, in one container.
# The agent's repository is private, so it is copied from the pinned checkout rather than cloned here:
#   python rag/run_pulse_agent.py setup     # once, with access to udaykamboj/pulse-voice-assistant
#   docker build -t pulse-backend .         # from Backend/
# Secrets come from the host at run time (see rag/cloud.py); none are in the image.
FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
# git: the agent pins LightAgent to a git commit.
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

# The agent's dependencies, in their own environment as in the team's setup.
COPY external/pulse-voice-assistant/pulse_agent/requirements.txt /tmp/agent-requirements.txt
RUN python -m venv /opt/agent && /opt/agent/bin/pip install --no-cache-dir -r /tmp/agent-requirements.txt

COPY external/pulse-voice-assistant/pulse_agent /app/agent/pulse_agent
WORKDIR /app/agent/pulse_agent
RUN mkdir -p runtime/tmp runtime/data \
 && for step in build_core build_knowledge build_index; do \
      PYTHONPATH=/app/agent:/app/agent/pulse_agent TMPDIR=/tmp /opt/agent/bin/python scripts/$step.py || exit 1; done

# Our API is standard-library Python; its evidence index is built from the verified cards.
COPY rag /app/rag
WORKDIR /app/rag
RUN python rag.py ingest

RUN useradd --create-home pulse && chown -R pulse /app/agent/pulse_agent/runtime /app/rag/data
USER pulse
EXPOSE 8080
CMD ["python", "cloud.py"]
