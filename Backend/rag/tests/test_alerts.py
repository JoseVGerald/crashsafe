import io
import json
import unittest

import alerts
from tests.test_motion_intel import GOLDEN


class FakeResponse(io.BytesIO):
    status = 201
    def __enter__(self): return self
    def __exit__(self, *a): return False


class AlertTests(unittest.TestCase):
    def payload(self, **overrides):
        base = {"is_simulated": False, "outcome": "noResponse", "driver_name": "Jose",
                "recipients": [{"name": "Maria", "phone": "(206) 555-0100"}],
                "location": {"lat": 45.41, "lon": -122.70}, "impact": dict(GOLDEN["crash_impact"])}
        base.update(overrides)
        return base

    def test_dry_run_by_default_and_message_content(self):
        result = alerts.send_alert(self.payload(), provider=alerts.DryRunProvider())
        self.assertEqual(result["delivery"], "dry_run")
        self.assertIn("did not respond", result["message"])
        self.assertIn("maps.apple.com/?ll=45.41000,-122.70000", result["message"])
        self.assertIn("call 911", result["message"])
        self.assertEqual(result["actions"][0]["to"][-4:], "0100")
        self.assertNotIn("2065550100", json.dumps(result["actions"]))  # masked in the response
        self.assertEqual(result["emergency_services"], "not_contacted_by_server")

    def test_twilio_texts_and_calls_each_contact(self):
        sent = []
        def opener(req, timeout):
            sent.append((req.full_url, req.data.decode()))
            return FakeResponse(b"{}")
        provider = alerts.TwilioProvider("AC123", "secret", "+15005550006", opener=opener)
        result = alerts.send_alert(self.payload(), provider=provider)
        self.assertEqual(result["delivery"], "sent")
        self.assertTrue(sent[0][0].endswith("/Messages.json") and "To=%2B12065550100" in sent[0][1])
        self.assertTrue(sent[1][0].endswith("/Calls.json") and "Twiml=" in sent[1][1])

    def test_test_crashes_never_send(self):
        provider = alerts.TwilioProvider("AC123", "secret", "+15005550006", opener=lambda *a, **k: self.fail("sent"))
        result = alerts.send_alert(self.payload(is_simulated=True), provider=provider)
        self.assertEqual(result["delivery"], "dry_run")
        self.assertTrue(result["message"].startswith("[TEST"))

    def test_rejects_911_ok_outcome_and_extra_fields(self):
        with self.assertRaises(ValueError):
            alerts.send_alert(self.payload(recipients=[{"name": "x", "phone": "911"}]))
        with self.assertRaises(ValueError):
            alerts.send_alert(self.payload(outcome="ok"))
        with self.assertRaises(ValueError):
            alerts.send_alert(self.payload(medical_notes="asthma"))
        with self.assertRaises(ValueError):
            alerts.send_alert(self.payload(recipients=[{"name": "a", "phone": "2065550100"}] * 6))


if __name__ == "__main__":
    unittest.main()
