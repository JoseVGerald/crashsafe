"""Pulse conversation + Corey speech, offline: the network is a fake, so no keys or credits are used."""
import copy, datetime as dt, io, json, tempfile, threading, unittest, urllib.error, urllib.request
from pathlib import Path

import rag
from pulse_voice import COREY, PulseVoice


class FakeNetwork:
    """Stands in for urllib.request.urlopen: records requests, answers from a script."""
    def __init__(self, replies):
        self.replies = list(replies)
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append((req.full_url, json.loads(req.data), dict(req.header_items())))
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


if __name__ == "__main__":
    unittest.main()
