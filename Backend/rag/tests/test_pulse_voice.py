"""Pulse conversation + Corey speech, offline: the network is a fake, so no keys or credits are used."""
import copy, datetime as dt, io, json, tempfile, threading, unittest, urllib.error, urllib.request
from pathlib import Path

import rag
from pulse_voice import COREY, PulseAgentLink, PulseVoice, agent_context


class FakeNetwork:
    """Stands in for urllib.request.urlopen: records requests, answers from a script."""
    def __init__(self, replies):
        self.replies = list(replies)
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append((req.full_url, json.loads(req.data) if req.data else None, dict(req.header_items())))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return io.BytesIO(reply)


def chat(text):
    return json.dumps({"choices": [{"message": {"content": text}}]}).encode()


ENV = {"OPENROUTER_API_KEY": "test-openrouter", "CARTESIA_API_KEY": "test-cartesia"}


class PulseVoiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        corpus = copy.deepcopy(rag.read_json(rag.ROOT / "knowledge" / "corpus.json"))
        for c in corpus["cards"]:
            c["expires"] = (dt.date.today() + dt.timedelta(days=30)).isoformat()
        path = Path(self.temp.name) / "corpus.json"
        path.write_text(json.dumps(corpus), encoding="utf-8")
        db = Path(self.temp.name) / "test.sqlite3"
        rag.ingest(path, db)
        self.engine = rag.Engine(db)

    def tearDown(self):
        self.engine.close()
        self.temp.cleanup()

    def test_emergencies_skip_the_model_and_say_911_first(self):
        net = FakeNetwork([])
        voice = PulseVoice(self.engine, ENV, opener=net)
        r = voice.converse([{"role": "user", "text": "my car is on fire right now"}])
        self.assertEqual(r["status"], "emergency")
        self.assertTrue(r["answer"].startswith("Call 911"))
        self.assertEqual(net.requests, [])  # no model in the loop
        for said in ("my passenger isn't waking up", "my son is not breathing", "she won't respond", "he got knocked out"):
            self.assertEqual(voice.converse([{"role": "user", "text": said}])["status"], "emergency", said)
        self.assertEqual(net.requests, [])

    def test_model_reply_uses_pulse_core_evidence_and_the_sentence_filter(self):
        net = FakeNetwork([chat("I'm right here with you. Calm down. Take 400 mg of ibuprofen. "
                                "Help is on the way. Turn on your hazard lights if you can.")])
        voice = PulseVoice(self.engine, ENV, opener=net)
        r = voice.converse([{"role": "user", "text": "I got rear-ended and my neck hurts a little, what now?"},
                            {"role": "assistant", "text": "Are you somewhere safe?"},
                            {"role": "user", "text": "yes, pulled over. should I take something for the pain?"}],
                           stage="active", incident={"decision": "suspectedCrash"})
        self.assertEqual(r["status"], "answered")
        self.assertTrue(r["model_used"])
        self.assertEqual(r["model"], "nvidia/nemotron-3.5-lightning:free")
        spoken = " ".join(r["sentences"])
        self.assertNotIn("Calm down", spoken)              # banned phrase dropped
        self.assertNotIn("400", spoken)                     # dose rewritten
        self.assertIn("I can't give a medication dose.", r["sentences"])
        self.assertNotIn("on the way", spoken)              # unconfirmed action not claimed
        self.assertIn("I'm right here with you.", r["sentences"])
        url, body, headers = net.requests[0]
        self.assertEqual(url, "https://openrouter.ai/api/v1/chat/completions")
        system = body["messages"][0]["content"]
        self.assertIn("[PULSE_CORE]", system)               # the team's Core prompt
        self.assertIn("[EVIDENCE]", system)                 # our verified cards, as data
        self.assertIn("[INCIDENT]", system)
        self.assertEqual([m["role"] for m in body["messages"][1:]], ["user", "assistant", "user"])
        self.assertEqual(body["reasoning"], {"enabled": False})

    def test_free_fallback_model_then_verified_answer_when_models_fail(self):
        net = FakeNetwork([urllib.error.URLError("down"), chat("Exchange insurance details with the other driver.")])
        r = PulseVoice(self.engine, ENV, opener=net).converse([{"role": "user", "text": "what do I exchange with the other driver"}])
        self.assertEqual(r["model"], "openai/gpt-oss-20b:free")
        net = FakeNetwork([urllib.error.URLError("down"), urllib.error.URLError("down")])
        r = PulseVoice(self.engine, ENV, opener=net).converse([{"role": "user", "text": "what do I exchange with the other driver"}])
        self.assertFalse(r["model_used"])
        self.assertEqual(r["generation_mode"], "extractive_fallback")
        self.assertTrue(r["answer"])

    def test_corey_speech_is_requested_and_cached(self):
        audio = b"ID3" + b"\x00" * 4000
        net = FakeNetwork([audio])
        voice = PulseVoice(self.engine, ENV, opener=net)
        self.assertEqual(voice.tts("Are you okay?"), audio)
        self.assertEqual(voice.tts("Are you okay?"), audio)    # second time from cache
        self.assertEqual(len(net.requests), 1)
        url, body, headers = net.requests[0]
        self.assertEqual(url, "https://api.cartesia.ai/tts/bytes")
        self.assertEqual(body["voice"], {"mode": "id", "id": COREY})
        self.assertEqual(headers.get("X-api-key"), "test-cartesia")
        with self.assertRaises(ValueError):
            voice.tts("")
        with self.assertRaises(LookupError):
            PulseVoice(self.engine, {}, opener=net).tts("hi")

    def test_http_endpoints(self):
        audio = b"ID3" + b"\x00" * 4000
        voice = PulseVoice(self.engine, ENV, opener=FakeNetwork([chat("I'm here with you. Are you somewhere safe?"), audio]))
        server = rag.make_server(self.engine, 0, voice=voice)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            def post(path, payload):
                req = urllib.request.Request(base + path, json.dumps(payload).encode(), {"Content-Type": "application/json"})
                return urllib.request.urlopen(req, timeout=10)
            r = json.loads(post("/v1/converse", {"messages": [{"role": "user", "text": "I just hit a pole"}]}).read())
            self.assertEqual(r["sentences"], ["I'm here with you.", "Are you somewhere safe?"])
            response = post("/v1/tts", {"text": "I'm here with you."})
            self.assertEqual(response.headers["Content-Type"], "audio/mpeg")
            self.assertEqual(response.read(), audio)
            with self.assertRaises(urllib.error.HTTPError) as bad:
                post("/v1/converse", {"messages": [], "secret": 1})
            self.assertEqual(bad.exception.code, 400)
        finally:
            server.shutdown()


def sse(*events):
    """The agent service's stream: keepalives between `data:` events."""
    return "".join(": keepalive\n\n" + "data: " + json.dumps(e) + "\n\n" for e in events).encode()


SECRET = "s" * 40


class PulseAgentTests(PulseVoiceTests):
    """The team's agent service, faked at the HTTP level (its own 70 tests cover the agent itself)."""

    def test_conversation_goes_to_one_agent_session_that_remembers_it(self):
        net = FakeNetwork([json.dumps({"session_id": "S1"}).encode(),
                           sse({"type": "speech_sentence", "text": "I'm here with you."},
                               {"type": "speech_sentence", "text": "Are you somewhere safe..."},
                               {"type": "turn_complete", "provider_model_ids": ["nvidia/nemotron-3.5-lightning:free"]}),
                           sse({"type": "speech_sentence", "text": "You said you were rear-ended."},
                               {"type": "turn_complete", "provider_model_ids": []})])
        voice = PulseVoice(self.engine, ENV, opener=net, agent=PulseAgentLink(SECRET, opener=net))
        incident = {"captured_at": "2026-10-22T10:00:00Z", "decision": "suspectedCrash",
                    "impact": {"severity": "moderate"}, "is_simulated": True}
        r = voice.converse([{"role": "user", "text": "I got rear-ended"}], incident=incident, conversation_id="conv-0001")
        self.assertEqual(r["generation_mode"], "pulse_agent")
        self.assertEqual(r["sentences"], ["I'm here with you.", "Are you somewhere safe,"])   # no spoken ellipses
        self.assertEqual(r["model"], "nvidia/nemotron-3.5-lightning:free")
        r = voice.converse([{"role": "user", "text": "I got rear-ended"}, {"role": "assistant", "text": r["answer"]},
                            {"role": "user", "text": "what did I say happened?"}], conversation_id="conv-0001")
        self.assertEqual(r["answer"], "You said you were rear-ended.")
        (start, _, headers), (turn1, body1, _), (turn2, body2, _) = net.requests
        self.assertEqual(start, "http://127.0.0.1:7862/sessions")
        self.assertEqual(turn1, turn2)                                     # same session: the agent keeps the history
        self.assertEqual(turn1, "http://127.0.0.1:7862/sessions/S1/turn")
        self.assertEqual(body2["text"], "what did I say happened?")         # only the new turn is sent
        self.assertEqual(body1["context"]["mode"], "crisis_support")
        self.assertEqual(body1["context"]["crash"]["severity"], "moderate")
        self.assertTrue(body1["context"]["crash"]["simulated"])
        self.assertTrue(headers["Authorization"].startswith("Bearer "))

    def test_the_agent_service_accepts_our_tokens(self):
        import run_pulse_agent, subprocess
        if not run_pulse_agent.PYTHON.exists():
            self.skipTest("team agent not set up (python run_pulse_agent.py setup)")
        link = PulseAgentLink(SECRET)
        verify = "import sys; from pulse_agent.service.api import Auth; print(Auth(sys.argv[1]).verify(sys.argv[2]))"
        owners = [subprocess.run([str(run_pulse_agent.PYTHON), "-c", verify, SECRET, link._token(c)], capture_output=True,
                                 text=True, env=run_pulse_agent.agent_env({}), timeout=60).stdout.strip()
                  for c in ("conv-0001", "conv-0002")]
        self.assertEqual(len(owners[0]), 64)
        self.assertNotEqual(owners[0], owners[1])  # each conversation is its own owner in the agent

    def test_tool_requests_reach_the_app_as_actions(self):
        net = FakeNetwork([json.dumps({"session_id": "S1"}).encode(),
                           sse({"type": "emergency_prompt_offer", "action": "emergency_call_prompt", "reason": "possible_self_harm"},
                               {"type": "tool_start", "action": "find_tow"},
                               {"type": "tool_result", "action": "find_tow", "success": False, "pending": True},
                               {"type": "speech_sentence", "text": "I'm right here with you."},
                               {"type": "turn_complete", "provider_model_ids": []})])
        voice = PulseVoice(self.engine, ENV, opener=net, agent=PulseAgentLink(SECRET, opener=net))
        r = voice.converse([{"role": "user", "text": "I can't do this anymore"}], conversation_id="conv-0002")
        self.assertEqual(r["actions"], [{"action": "emergency_call_prompt", "status": "offered", "reason": "possible_self_harm"},
                                        {"action": "find_tow", "status": "app_action_requested"}])

    def test_emergencies_never_wait_for_the_agent(self):
        net = FakeNetwork([])
        voice = PulseVoice(self.engine, ENV, opener=net, agent=PulseAgentLink(SECRET, opener=net))
        r = voice.converse([{"role": "user", "text": "my car is on fire"}], conversation_id="conv-0003")
        self.assertEqual(r["status"], "emergency")
        self.assertEqual(r["actions"][0]["action"], "emergency_call_prompt")
        self.assertEqual(net.requests, [])

    def test_restarted_agent_gets_a_new_session_and_a_down_agent_falls_back(self):
        gone = urllib.error.HTTPError("http://127.0.0.1:7862/sessions/S1/turn", 404, "Unknown session", {}, None)
        net = FakeNetwork([json.dumps({"session_id": "S1"}).encode(), sse({"type": "speech_sentence", "text": "One."}),
                           gone, json.dumps({"session_id": "S2"}).encode(), sse({"type": "speech_sentence", "text": "Two."})])
        link = PulseAgentLink(SECRET, opener=net)
        voice = PulseVoice(self.engine, ENV, opener=net, agent=link)
        voice.converse([{"role": "user", "text": "hello"}], conversation_id="conv-0004")
        self.assertEqual(voice.converse([{"role": "user", "text": "still there?"}], conversation_id="conv-0004")["answer"], "Two.")
        self.assertEqual(net.requests[-1][0], "http://127.0.0.1:7862/sessions/S2/turn")
        # Agent not running: the direct Pulse core path answers instead.
        net = FakeNetwork([urllib.error.URLError("refused"), chat("I'm here with you.")])
        voice = PulseVoice(self.engine, ENV, opener=net, agent=PulseAgentLink(SECRET, opener=net))
        r = voice.converse([{"role": "user", "text": "hello"}], conversation_id="conv-0005")
        self.assertEqual(r["generation_mode"], "pulse_core")
        with self.assertRaises(ValueError):
            voice.converse([{"role": "user", "text": "hi"}], conversation_id="../../etc")

    def test_context_modes(self):
        self.assertEqual(agent_context("active", None, None)["mode"], "standby")
        self.assertEqual(agent_context("followup", {"captured_at": "x"}, None)["mode"], "aftermath")
        context = agent_context("active", {"captured_at": "bad", "impact": {"severity": "<script>"}}, None)
        self.assertEqual(context["crash"]["severity"], "unknown")
        self.assertIsNone(context["crash"]["seconds_since_crash"])


class LanAccessTests(PulseVoiceTests):
    def test_other_devices_need_the_lan_token(self):
        server = rag.make_server(self.engine, 0, lan_token="t" * 40, trusted=())  # treat even this Mac as "another device"
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_port}/health"
        try:
            with self.assertRaises(urllib.error.HTTPError) as denied:
                urllib.request.urlopen(url, timeout=5)
            self.assertEqual(denied.exception.code, 401)
            with self.assertRaises(urllib.error.HTTPError):
                urllib.request.urlopen(urllib.request.Request(url, headers={"X-Pulse-Token": "wrong"}), timeout=5)
            ok = urllib.request.urlopen(urllib.request.Request(url, headers={"X-Pulse-Token": "t" * 40}), timeout=5)
            self.assertEqual(ok.status, 200)
        finally:
            server.shutdown()

    def test_without_a_token_nothing_off_this_machine_gets_in(self):
        server = rag.make_server(self.engine, 0, trusted=())
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with self.assertRaises(urllib.error.HTTPError) as denied:
                urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{server.server_port}/health",
                                                              headers={"X-Pulse-Token": ""}), timeout=5)
            self.assertEqual(denied.exception.code, 401)
        finally:
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
