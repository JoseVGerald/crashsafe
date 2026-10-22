"""Writes tests/motion_golden.json: motion_intel outputs for synthetic signals that the iOS tests
(CoreTests/MotionIntelligenceTests.swift) regenerate with identical formulas, so the Swift and
Python implementations are checked against the same numbers. Run from Backend/rag."""
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import motion_intel as mi  # noqa: E402


def history(seconds, speed, accel, start=100.0):
    h = mi.SensorHistory()
    lat = 45.5
    for i in range(int(seconds * 100)):
        t = start + i / 100
        h.append_motion(t, accel(t), (0.0, 0.0, -1.0), (0.0, 0.0, 0.0))
        if i % 100 == 0:
            h.append_location(t, t, lat, -122.6, 5.0, speed(t), 0.5)
            lat += speed(t) / 111_320
    return h


def walk():
    return history(9, lambda t: 1.4,
                   lambda t: (0.05 * math.sin(2 * math.pi * 0.95 * t), 0.0, 0.25 * math.sin(2 * math.pi * 1.9 * t)))


def car():
    return history(9, lambda t: 20.0,
                   lambda t: (0.02 * math.sin(t * 13), 0.03 * math.sin(t * 7), 0.04 * math.sin(t * 17)))


IMPACT = 108.0


def crash():
    def accel(t):
        if IMPACT <= t <= IMPACT + 0.1:
            return (0.0, -10 * math.sin(math.pi * (t - IMPACT) / 0.1), 0.0)
        if IMPACT + 0.1 < t < IMPACT + 2.6:
            return (0.0, -0.38, 0.0)
        return (0.002, 0.0, 0.003)
    return history(18, lambda t: 15.6 if t < IMPACT else max(0.0, 9 - (t - IMPACT) * 3.6), accel)


def brake():
    return history(10, lambda t: 20.0 if t < 104 else max(10.0, 20 - (t - 104) * 5), lambda t: (0.0, 0.0, 0.0))


def mode_case(h):
    w = h.window(108.0, 5.0)
    f = mi.transport_features(w)
    return {"features": f, "probabilities": mi.feature_model_probabilities(f)}


def main():
    golden = {
        "walk": mode_case(walk()),
        "car": mode_case(car()),
        "crash_impact": mi.impact_report(crash(), IMPACT + 0.05),
        "brake_events": mi.harsh_events(brake().window(108.0, 5.0)),
    }
    out = Path(__file__).with_name("motion_golden.json")
    out.write_text(json.dumps(golden, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
