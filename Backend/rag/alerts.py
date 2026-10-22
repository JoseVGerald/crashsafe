"""POST /v1/alerts: tell the driver's family contacts about a possible crash.

With TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN and TWILIO_FROM set, each contact gets a text and an
automated phone call that reads the message aloud. Without them it runs dry and returns what it
would send. Test (simulated) crashes always run dry.

It never calls 911: emergency services can't be reached through an automated calling service like
this. The driver's phone starts the 911 call itself (and iOS asks to confirm it). Phone numbers and
location are used for this one request; nothing is stored or logged.
"""
from __future__ import annotations

import base64
import json
import math
import os
import re
import urllib.parse
import urllib.request
from xml.sax.saxutils import escape

from motion_intel import normalize_impact

MAX_RECIPIENTS = 5


def _phone(raw):
    if not isinstance(raw, str):
        raise ValueError("Invalid phone")
    digits = re.sub(r"[^\d+]", "", raw)
    if digits.startswith("+"):
        number = "+" + re.sub(r"\D", "", digits)
    else:
        d = re.sub(r"\D", "", digits)
        number = "+1" + d if len(d) == 10 else "+" + d
    if not 8 <= len(number) <= 16 or number in ("+1911", "+911"):
        raise ValueError("Invalid phone")
    return number


def _masked(number):
    return number[:-4].replace(number[2:-4], "•" * len(number[2:-4])) + number[-4:] if len(number) > 6 else "•••"


def normalize_alert(raw):
    if not isinstance(raw, dict) or set(raw) - {"is_simulated", "outcome", "driver_name", "recipients", "location", "impact"}:
        raise ValueError("Unsupported alert fields")
    if type(raw.get("is_simulated")) is not bool:
        raise ValueError("is_simulated required")
    if raw.get("outcome") not in ("noResponse", "needsHelp"):
        raise ValueError("Alerts are only for no response or a request for help")
    name = raw.get("driver_name", "")
    if not isinstance(name, str) or len(name) > 60:
        raise ValueError("Invalid driver name")
    recipients = raw.get("recipients")
    if not isinstance(recipients, list) or not 1 <= len(recipients) <= MAX_RECIPIENTS:
        raise ValueError(f"Expected 1-{MAX_RECIPIENTS} recipients")
    clean = []
    for r in recipients:
        if not isinstance(r, dict) or set(r) - {"name", "phone"} or not isinstance(r.get("name"), str) or len(r["name"]) > 60:
            raise ValueError("Invalid recipient")
        clean.append({"name": r["name"].strip() or "Contact", "phone": _phone(r.get("phone"))})
    location = raw.get("location")
    if location is not None:
        if not isinstance(location, dict) or set(location) != {"lat", "lon"} or \
                any(type(location[k]) not in (int, float) or not math.isfinite(location[k]) for k in location) or \
                not -90 <= location["lat"] <= 90 or not -180 <= location["lon"] <= 180:
            raise ValueError("Invalid location")
    return {"is_simulated": raw["is_simulated"], "outcome": raw["outcome"], "driver_name": name.strip() or "Your contact",
            "recipients": clean, "location": location, "impact": normalize_impact(raw.get("impact"))}


def message_for(alert):
    who = alert["driver_name"]
    what = (f"{who}'s phone detected a possible car crash and {who} did not respond"
            if alert["outcome"] == "noResponse" else f"{who} may have been in a car crash and asked for help")
    text = f"CrashSafe: {what}."
    if alert["impact"]:
        text += f" It looked {alert['impact']['severity']}."
    if alert["location"]:
        text += f" Location: https://maps.apple.com/?ll={alert['location']['lat']:.5f},{alert['location']['lon']:.5f}"
    text += f" Please call {who} now. If you can't reach them, call 911 and give that location."
    if alert["is_simulated"]:
        text = "[TEST — no crash happened] " + text
    return text


class DryRunProvider:
    name = "dry_run"

    def send(self, to, body):
        return "not_sent"

    def call(self, to, body):
        return "not_called"


class TwilioProvider:
    name = "twilio"

    def __init__(self, sid, token, sender, opener=urllib.request.urlopen):
        self.sid, self.sender, self.opener = sid, sender, opener
        self.auth = "Basic " + base64.b64encode(f"{sid}:{token}".encode()).decode()

    def _post(self, resource, fields):
        url = f"https://api.twilio.com/2010-04-01/Accounts/{self.sid}/{resource}.json"
        req = urllib.request.Request(url, urllib.parse.urlencode(fields).encode(),
                                     {"Authorization": self.auth, "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with self.opener(req, timeout=8) as r:
                return "queued" if 200 <= r.status < 300 else "failed"
        except Exception:
            return "failed"

    def send(self, to, body):
        return self._post("Messages", {"From": self.sender, "To": to, "Body": body})

    def call(self, to, body):
        spoken = escape(body.replace("https://", "").split(" Location:")[0])
        twiml = f'<Response><Say voice="alice">{spoken}</Say><Pause length="1"/><Say voice="alice">{spoken}</Say></Response>'
        return self._post("Calls", {"From": self.sender, "To": to, "Twiml": twiml})


def configured_provider(env=os.environ):
    sid, token, sender = env.get("TWILIO_ACCOUNT_SID"), env.get("TWILIO_AUTH_TOKEN"), env.get("TWILIO_FROM")
    return TwilioProvider(sid, token, sender) if sid and token and sender else DryRunProvider()


def send_alert(payload, provider=None):
    alert = normalize_alert(payload)
    provider = DryRunProvider() if alert["is_simulated"] else (provider or configured_provider())
    body = message_for(alert)
    actions = []
    for r in alert["recipients"]:
        actions.append({"to": _masked(r["phone"]), "name": r["name"],
                        "text": provider.send(r["phone"], body), "call": provider.call(r["phone"], body)})
    if provider.name == "dry_run":
        delivery = "dry_run"
    elif all(a["text"] == "queued" and a["call"] == "queued" for a in actions):
        delivery = "sent"
    elif any(a["text"] == "queued" or a["call"] == "queued" for a in actions):
        delivery = "partial"
    else:
        delivery = "failed"
    return {"delivery": delivery, "provider": provider.name, "actions": actions, "message": body,
            "emergency_services": "not_contacted_by_server",
            "note": "Texts and automated calls to family only. 911 must be called from the phone."}
