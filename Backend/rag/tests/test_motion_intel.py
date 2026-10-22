import datetime as dt
import importlib.util
import json
import math
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

import motion_intel as mi
import rag
from incident_context import assist, normalize_incident
from tests.make_motion_golden import IMPACT, brake, car, crash, mode_case, walk

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = json.loads((ROOT / "tests" / "motion_golden.json").read_text(encoding="utf-8"))
TRANSPORT_REPO = ROOT.parent / "transport-ml" / "project-root" / "scripts" / "parse_shl_gps.py"
try:
    import numpy as np
except ImportError:
    np = None


def close(a, b, tol=1e-9):
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(close(a[k], b[k], tol) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        return a is not None and b is not None and abs(a - b) <= tol * max(1.0, abs(b))
    return a == b


class MotionIntelTests(unittest.TestCase):
    def test_golden_values_are_current(self):
        """Swift checks itself against the same file (CoreTests/MotionIntelligenceTests.swift)."""
        self.assertTrue(close(mode_case(walk()), GOLDEN["walk"]))
        self.assertTrue(close(mode_case(car()), GOLDEN["car"]))
        self.assertTrue(close(mi.impact_report(crash(), IMPACT + 0.05), GOLDEN["crash_impact"]))
        self.assertTrue(close(mi.harsh_events(brake().window(108.0, 5.0)), GOLDEN["brake_events"]))

    def test_physics(self):
        impact = GOLDEN["crash_impact"]
        # Discrete trapezoid of a 10 g, 100 ms half-sine at 100 Hz: 10 g * 0.01 s * cot(pi/20).
        self.assertAlmostEqual(impact["delta_v_mps"], 10 * mi.G * 0.01 / math.tan(math.pi / 20), places=6)
        self.assertEqual(impact["severity"], "moderate")
        self.assertEqual(mi.observation(GOLDEN["walk"]["probabilities"])["label"], "walk")
        self.assertEqual(mi.observation(GOLDEN["car"]["probabilities"])["label"], "car")

    def test_window_contract_fails_closed(self):
        h = walk()
        self.assertIsNone(h.window(200.0, 5.0))
        self.assertEqual(len(h.window(108.0, 5.0)["linear"]), mi.CONTRACT_SAMPLES)
        self.assertFalse(h.append_motion(50.0, (0, 0, 0), (0, 0, -1), (0, 0, 0)))  # out of order
        self.assertIsNone(mi.damped_perwin([[1.0, 2.0]], [], 3.0))  # no invented floors

    @unittest.skipUnless(np is not None and TRANSPORT_REPO.exists(), "needs numpy and the transport repo clone")
    def test_gps_features_match_the_transport_repo(self):
        spec = importlib.util.spec_from_file_location("parse_shl_gps", TRANSPORT_REPO)
        repo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(repo)
        w = car().window(108.0, 5.0)
        fl = np.array([[f["date"] * 1000, f["lat"], f["lon"]] for f in w["fixes"]])
        expected = repo.window_gps_features(fl, 5000).tolist()
        ours = mi.gps_features(w["fixes"], 5000)
        for a, b in zip(ours, expected):
            self.assertAlmostEqual(a, b, delta=1e-4 * max(1, abs(b)))  # repo returns float32

    def test_impact_and_activity_validation(self):
        impact = dict(GOLDEN["crash_impact"])
        clean = mi.normalize_impact(impact)
        self.assertEqual(clean["authority"], "phone_sensor_estimate")
        with self.assertRaises(ValueError):
            mi.normalize_impact({**impact, "latitude": 45.5})  # no location in the summary
        with self.assertRaises(ValueError):
            mi.normalize_impact({**impact, "peak_g": float("nan")})
        activity = {"transport": {**mi.observation(GOLDEN["walk"]["probabilities"])}, "harsh_brakes_10min": 0}
        self.assertTrue(mi.normalize_activity(activity)["transport"]["accepted"])
        with self.assertRaises(ValueError):
            mi.normalize_activity({"transport": {"label": "car", "basis": "profile", "probability": 1, "model_id": "x"}})


class AgentIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        corpus = rag.read_json(rag.ROOT / "knowledge" / "corpus.json")
        for card in corpus["cards"]:
            card["expires"] = (dt.date.today() + dt.timedelta(days=30)).isoformat()
        p = Path(self.temp.name) / "corpus.json"
        p.write_text(json.dumps(corpus), encoding="utf-8")
        self.db = Path(self.temp.name) / "medical.sqlite3"
        rag.ingest(p, self.db)
        self.engine = rag.Engine(self.db)
        self.packet = {"schema_version": 1, "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                       "is_simulated": False, "decision": "suspectedCrash", "peak_g": 10.0,
                       "evidence": ["strongImpact"], "issues": [], "transport": {"label": "car", "basis": "profile"},
                       "impact": dict(GOLDEN["crash_impact"])}

    def tearDown(self):
        self.engine.close()
        self.temp.cleanup()

    def test_pulse_explains_the_measured_impact(self):
        result = assist(self.engine, "What should I document?", "WA", "followup", incident=self.packet)
        self.assertIn("speed change of roughly 14 mph", result["answer"])
        self.assertIn("not a medical assessment", result["answer"])
        self.assertEqual(result["incident_context"]["impact"]["severity"], "moderate")

    def test_impact_never_delays_an_emergency_instruction(self):
        result = assist(self.engine, "my chest hurts", "WA", "active", incident=self.packet)
        self.assertEqual(result["status"], "emergency")
        self.assertTrue(result["answer"].startswith("Call 911"))

    def test_activity_reaches_the_agent(self):
        activity = {"transport": mi.observation(GOLDEN["car"]["probabilities"]), "harsh_brakes_10min": 2}
        result = assist(self.engine, "How am I driving?", "WA", "followup", activity=activity)
        self.assertEqual(result["activity_context"]["transport"]["label"], "car")
        self.assertEqual(result["activity_context"]["harsh_brakes_10min"], 2)

    def test_analyze_window_endpoint(self):
        h = crash()
        samples = [[m[0], *m[1], *m[2], *m[3]] for m in h.motion]
        fixes = [[f["uptime"], f["date"], f["lat"], f["lon"], f["h_acc"], f["speed"], f["speed_acc"]] for f in h.locations]
        server = rag.make_server(self.engine, 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            body = json.dumps({"samples": samples[-1500:], "fixes": fixes, "impact_uptime": IMPACT + 0.05}).encode()
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/analyze-window", body,
                                         {"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                result = json.loads(r.read())
            self.assertAlmostEqual(result["impact"]["delta_v_mps"], GOLDEN["crash_impact"]["delta_v_mps"], places=6)
            self.assertIn("nothing is stored", result["note"])
            bad = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/analyze-window",
                                         json.dumps({"samples": [[1, 2]]}).encode(), {"Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(bad, timeout=10)
            self.assertEqual(error.exception.code, 400)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
