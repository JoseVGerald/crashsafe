"""Rolling sensor history and event analysis for the Pulse agent.

The same algorithms as the iOS app (CrashSafe/Services/Sensors/SensorHistory.swift,
CrashDetection/ImpactAnalysis.swift, Intelligence/TransportMode.swift, Intelligence/HarshEvents.swift),
kept in step by shared golden values (tests/motion_golden.json). Standard library only, like the server.

Transport mode follows the basis of udaykamboj/multi-placement-transportation-mode-classification-ML-system:
8 SHL classes, 50 Hz x 250-sample windows, damped per-window normalization, and the 12 per-window GPS
features of scripts/parse_shl_gps.py. Its trained network is not used (checkpoints ship without their
normalization statistics); a transparent feature model fills that slot and says so in model_id.

Privacy: the app sends only derived observations with an incident or question. Raw windows reach the
server only through the opt-in /v1/analyze-window developer endpoint, and are never stored or logged.
"""
from __future__ import annotations

import bisect
import math
from collections import deque

G = 9.80665
CONTRACT_HZ = 50.0
CONTRACT_SAMPLES = 250
CLASSES = ("still", "walk", "run", "bicycle", "car", "bus", "train", "subway")
MODEL_ID = "crashsafe-shl8-features-v3"
ACCEPTANCE = 0.8


def _finite(*xs):
    return all(type(x) in (int, float) and math.isfinite(x) for x in xs)


def _mag(v):
    return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])


def _lerp(a, b, f):
    return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f)


class SensorHistory:
    """Bounded, synchronized motion (acceleration g, gravity g, rotation rad/s) and GPS history."""

    MOTION_CAPACITY = 3200   # ~32 s at 100 Hz
    LOCATION_CAPACITY = 240  # ~4 min at 1 Hz

    def __init__(self):
        self.motion = deque(maxlen=self.MOTION_CAPACITY)
        self.locations = deque(maxlen=self.LOCATION_CAPACITY)

    def append_motion(self, uptime, acc, gravity, rotation):
        if not (_finite(uptime, *acc, *gravity, *rotation) and uptime >= 0 and len(acc) == len(gravity) == len(rotation) == 3):
            return False
        if self.motion and uptime <= self.motion[-1][0]:
            return False
        self.motion.append((float(uptime), tuple(acc), tuple(gravity), tuple(rotation)))
        return True

    def append_location(self, uptime, date, lat, lon, h_acc, speed, speed_acc):
        if not (_finite(uptime, date, lat, lon, h_acc, speed, speed_acc) and uptime >= 0
                and -90 <= lat <= 90 and -180 <= lon <= 180):
            return False
        if self.locations and uptime <= self.locations[-1]["uptime"]:
            return False
        self.locations.append({"uptime": float(uptime), "date": float(date), "lat": float(lat), "lon": float(lon),
                               "h_acc": float(h_acc), "speed": float(speed), "speed_acc": float(speed_acc)})
        return True

    def motion_between(self, start, end):
        return [m for m in self.motion if start <= m[0] <= end]

    def locations_between(self, start, end):
        return [f for f in self.locations if start <= f["uptime"] <= end]

    def window(self, end, duration, hz=CONTRACT_HZ, maximum_gap=0.25):
        """Uniform resample ending at `end`; None when not fully covered or gapped (fails closed)."""
        if hz <= 0 or duration <= 0:
            return None
        count = int(round(duration * hz))
        start = end - (count - 1) / hz
        samples = self.motion_between(start - maximum_gap, end + maximum_gap)
        if not samples or samples[0][0] > start + 0.5 / hz or samples[-1][0] < end - 0.5 / hz:
            return None
        if any(b[0] - a[0] > maximum_gap for a, b in zip(samples, samples[1:])):
            return None
        linear, gravity, rotation = [], [], []
        j = 0
        for i in range(count):
            t = start + i / hz
            while j + 1 < len(samples) and samples[j + 1][0] < t:
                j += 1
            a, b = samples[j], samples[min(j + 1, len(samples) - 1)]
            span = b[0] - a[0]
            f = min(max((t - a[0]) / span, 0.0), 1.0) if span > 0 else 0.0
            la = _lerp(a[1], b[1], f)
            linear.append((la[0] * G, la[1] * G, la[2] * G))
            gravity.append(_lerp(a[2], b[2], f))
            rotation.append(_lerp(a[3], b[3], f))
        fixes = self.locations_between(start - 3, end + 0.5)
        speeds = [speed_at(start + i / hz, fixes) for i in range(count)]
        return {"hz": hz, "start": start, "linear": linear, "gravity": gravity, "rotation": rotation,
                "speed": speeds, "fixes": [f for f in fixes if start - 0.5 <= f["uptime"] <= end + 0.5]}


def reliable(fix):
    return fix["speed"] >= 0 and 0 <= fix["speed_acc"] <= 3 and 0 <= fix["h_acc"] <= 50


def speed_at(t, fixes):
    good = [f for f in fixes if reliable(f)]
    before = [f for f in good if f["uptime"] <= t]
    after = [f for f in good if f["uptime"] >= t]
    if before and after and after[0]["uptime"] - before[-1]["uptime"] <= 3:
        b, a = before[-1], after[0]
        span = a["uptime"] - b["uptime"]
        f = (t - b["uptime"]) / span if span > 0 else 0.0
        return b["speed"] + (a["speed"] - b["speed"]) * f
    if not good:
        return None
    nearest = min(good, key=lambda f: abs(f["uptime"] - t))
    return nearest["speed"] if abs(nearest["uptime"] - t) <= 2 else None


# ---------------------------------------------------------------- statistics (numpy-compatible)

def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def std(xs):
    if not xs:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / len(xs))


def percentile(xs, q):
    if not xs:
        return 0.0
    s = sorted(xs)
    pos = (len(s) - 1) * q / 100
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def median(xs):
    if not xs:
        return None
    s = sorted(xs)
    mid = len(s) // 2
    return (s[mid - 1] + s[mid]) / 2 if len(s) % 2 == 0 else s[mid]


# ---------------------------------------------------------------- transport mode

def haversine(a_lat, a_lon, b_lat, b_lon):
    """Identical to scripts/parse_shl_gps.py."""
    r = 6371000.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = math.radians(b_lat - a_lat), math.radians(b_lon - a_lon)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2.0 * r * math.asin(min(1.0, math.sqrt(h)))


def gps_features(fixes, duration_ms):
    """Port of window_gps_features (scripts/parse_shl_gps.py); fixes carry date in seconds."""
    fl = sorted(fixes, key=lambda f: f["date"])
    if len(fl) < 2:
        return None
    span = (fl[-1]["date"] - fl[0]["date"]) * 1000
    if span <= 0:
        return None
    dist, speed, bears = [], [], []
    for a, b in zip(fl, fl[1:]):
        d = haversine(a["lat"], a["lon"], b["lat"], b["lon"])
        dt = max((b["date"] - a["date"]) * 1000, 1.0)
        dist.append(d)
        speed.append(d / (dt / 1000.0))
        bears.append(math.atan2(b["lon"] - a["lon"], b["lat"] - a["lat"]))
    hd = []
    for a, b in zip(bears, bears[1:]):
        x = abs(b - a)
        hd.append(min(x, 2 * math.pi - x))
    total = sum(dist)
    return [mean(speed), max(speed), std(speed), percentile(speed, 50), percentile(speed, 90),
            total, total / max(span / 1000.0, 1e-3),
            mean(hd) if hd else 0.0, std(hd) if hd else 0.0, max(hd) if hd else 0.0,
            float(len(fl)), span / duration_ms]


def damped_perwin(channels, floor, clip):
    """Port of damped_perwin + clip (scripts/train_shl.py). Floors must come from the model's training stats."""
    if not channels or len(channels) != len(floor) or clip <= 0 or any(f <= 0 for f in floor):
        return None
    out = []
    for c, xs in enumerate(channels):
        m, s = mean(xs), max(std(xs), floor[c])
        out.append([min(max((x - m) / s, -clip), clip) for x in xs])
    return out


def dominant_period(xs, hz):
    m = mean(xs)
    c = [x - m for x in xs]
    energy = sum(x * x for x in c)
    if energy <= 1e-9:
        return 0.0, 0.0
    min_lag, max_lag = max(1, int(hz / 4)), min(len(c) - 1, int(hz / 0.7))
    if min_lag >= max_lag:
        return 0.0, 0.0
    best_lag, best_r = 0, 0.0
    for lag in range(min_lag, max_lag + 1):
        r = sum(c[i] * c[i + lag] for i in range(len(c) - lag)) / energy
        if r > best_r:
            best_lag, best_r = lag, r
    return (hz / best_lag, min(best_r, 1.0)) if best_lag else (0.0, 0.0)


def transport_features(w):
    accel = [_mag(a) for a in w["linear"]]
    gyro = [_mag(r) for r in w["rotation"]]
    vertical = []
    for a, g in zip(w["linear"], w["gravity"]):
        gm = _mag(g)
        vertical.append((a[0] * g[0] + a[1] * g[1] + a[2] * g[2]) / gm if gm > 0 else 0.0)
    cadence, strength = dominant_period(vertical, w["hz"])
    speeds = [s for s in w["speed"] if s is not None]
    n = len(w["linear"])
    return {"gps": gps_features(w["fixes"], n / w["hz"] * 1000),
            "accel_mean": mean(accel), "accel_std": std(accel), "accel_max": max(accel) if accel else 0.0,
            "gyro_mean": mean(gyro), "gyro_std": std(gyro), "cadence_hz": cadence, "cadence_strength": strength,
            "median_speed": median(speeds) if len(speeds) >= n // 3 else None}


def _band(x, lo, hi, soft):
    if x is None:
        return 0.0
    if lo <= x <= hi:
        return 1.0
    d = lo - x if x < lo else x - hi
    return max(0.0, 1 - d / soft)


def feature_model_probabilities(f):
    """Same scores as FeatureTransportModel in TransportMode.swift."""
    gps = f["gps"]
    speed = f["median_speed"] if f["median_speed"] is not None else (gps[3] if gps else None)
    straight = gps[7] < 0.15 if gps else False
    # Hand: step rate. Front pocket: stride rate, half of it (MotionSense: walk ~0.95 Hz, jog ~1.35 Hz).
    # Car vibration is faintly rhythmic at most (median strength 0.26) and doesn't swing the phone around.
    walk_rate = max(_band(f["cadence_hz"], 0.75, 1.15, 0.25), _band(f["cadence_hz"], 1.5, 2.4, 0.3))
    run_rate = max(_band(f["cadence_hz"], 1.2, 1.7, 0.25), _band(f["cadence_hz"], 2.4, 3.6, 0.5))
    # Only a gait rate counts: a gentle 3 Hz rhythm is road vibration, not a run.
    gait_rate = max(walk_rate, run_rate if f["accel_std"] > 3 else 0)
    rhythmic = f["cadence_strength"] > 0.4 and gait_rate > 0 and f["accel_std"] > 0.5
    swinging = f["accel_std"] > 1.5 and f["gyro_mean"] > 0.8 and f["cadence_strength"] > 0.15
    stepping = rhythmic or swinging
    vigorous = f["accel_std"] > 5.5
    quiet = _band(f["accel_std"], 0, 0.25, 0.5)
    s = [0.0] * 8
    s[0] = 3 * quiet * _band(f["gyro_mean"], 0, 0.15, 0.3) + (0 if speed is None else (1.5 if speed < 0.4 else -4 if speed > 1.5 else -1))
    s[1] = ((2.5 * max(walk_rate, 0 if rhythmic else 0.8) * (0.4 if vigorous else 1)) if stepping else 0) + _band(f["accel_std"], 0.8, 5.5, 1.5) \
        + _band(speed, 0.5, 2.3, 1) - (3 if speed is not None and speed > 4 else 0)
    s[2] = ((2.5 * run_rate * (1 if vigorous else 0.5)) if stepping and f["accel_std"] > 3 else 0) + _band(f["accel_std"], 5.5, 15, 1.5) \
        + _band(speed, 2.3, 6.5, 1.5) - (3 if speed is not None and speed > 8 else 0)
    # Without a speed, only pedalling says "bike"; road vibration alone looks much the same.
    pedalling = rhythmic and 0.8 <= f["cadence_hz"] <= 1.8 and f["gyro_mean"] > 0.5
    bike_motion = _band(f["gyro_std"], 0.15, 0.8, 0.4) + _band(f["accel_std"], 0.6, 3, 1)
    s[3] = 1.6 * _band(speed, 3, 9, 2) + bike_motion * (0.4 if speed is None and not pedalling else 1) \
        - (1.5 if stepping and f["cadence_hz"] > 1.4 else 0)
    riding = 0.6 if speed is None and not stepping and f["gyro_mean"] < 0.3 else 0
    s[4] = 2.6 * _band(speed, 6, 45, 4) + _band(f["accel_std"], 0.05, 1.2, 1) - (1.5 if stepping else 0) + (0 if straight else 0.3) + riding
    s[5] = 1.4 * _band(speed, 3, 22, 4) + 0.6 * _band(f["accel_std"], 0.1, 1.2, 1) - (1.5 if stepping else 0)
    s[6] = 1.2 * _band(speed, 22, 90, 8) + (0.6 if straight else 0) + 0.4 * _band(f["accel_std"], 0.05, 0.6, 0.5) - (2 if stepping else 0)
    coverage = gps[11] if gps else 0.0
    s[7] = (0.8 if gps is None or coverage < 0.3 else -1) * _band(f["accel_std"], 0.1, 0.8, 0.5) \
        + 0.5 * _band(f["gyro_mean"], 0, 0.1, 0.2) - (2 if stepping else 0)
    m = max(s)
    e = [math.exp((x - m) / 0.45) for x in s]
    total = sum(e)
    return [x / total for x in e]


def observation(probabilities, model_id=MODEL_ID):
    best = max(range(8), key=lambda i: probabilities[i])
    p = probabilities[best]
    return {"label": CLASSES[best] if p >= ACCEPTANCE else "unknown", "basis": "model", "probability": p, "model_id": model_id}


# ---------------------------------------------------------------- harsh events (src/behavior/events.py)

def harsh_events(w, brake_lo=0.25, brake_hi=0.45, accel_lo=0.30, accel_hi=0.50, min_dur=1.0, merge_gap=1.5):
    n, hz = len(w["linear"]), w["hz"]
    if n <= 2:
        return []
    half = max(1, int(hz / 2))
    events, active = [], None

    def sev(x, lo, hi):
        return min(max((x - lo) / max(hi - lo, 1e-6), 0.0), 1.0)

    def close(t):
        nonlocal active
        if active is None:
            return
        active["end"] = t
        if active["end"] - active["start"] >= min_dur:
            events.append(active)
        active = None

    for i in range(n):
        t = i / hz
        kind, severity = None, 0.0
        lo, hi = max(0, i - half), min(n - 1, i + half)
        a, b = w["speed"][lo], w["speed"][hi]
        if a is not None and b is not None:
            dt = (hi - lo) / hz
            signed = (b - a) / dt / G if dt > 0 else 0.0
            if signed <= -brake_lo:
                kind, severity = "harsh_brake", sev(-signed, brake_lo, brake_hi)
            elif signed >= accel_lo:
                kind, severity = "harsh_accel", sev(signed, accel_lo, accel_hi) * 0.8
        if kind:
            if active and active["kind"] == kind:
                active["end"] = t
                active["severity"] = max(active["severity"], severity)
            else:
                close(t)
                active = {"kind": kind, "start": t, "end": t, "severity": severity}
        else:
            close(t)
    close(n / hz)
    merged = []
    for e in events:
        if merged and merged[-1]["kind"] == e["kind"] and e["start"] - merged[-1]["end"] <= merge_gap:
            merged[-1]["end"] = e["end"]
            merged[-1]["severity"] = max(merged[-1]["severity"], e["severity"])
        else:
            merged.append(e)
    return merged


# ---------------------------------------------------------------- impact (ImpactAnalysis.swift)

MODERATE_DELTA_V = 3.0
SEVERE_DELTA_V = 7.0


def settle_time(after):
    window = []
    for sample in after:
        window.append(sample)
        window = [s for s in window if sample[0] - s[0] <= 1]
        if sample[0] - window[0][0] < 0.9:
            continue
        rms = math.sqrt(sum(_mag(s[1]) ** 2 for s in window) / len(window))
        if rms < 0.08:
            return window[0][0]
    return None


def impact_report(history, t, simulated=False):
    samples = history.motion_between(t - 1, t + 10)
    around = [s for s in samples if abs(s[0] - t) <= 0.5]
    if not around or not any(s[0] >= t + 1 for s in samples):
        return None
    peak = max(around, key=lambda s: _mag(s[1]))
    peak_g = _mag(peak[1])
    threshold = max(0.8, peak_g * 0.2)
    k = samples.index(peak)
    lo = hi = k
    while lo > 0 and _mag(samples[lo - 1][1]) >= threshold:
        lo -= 1
    while hi + 1 < len(samples) and _mag(samples[hi + 1][1]) >= threshold:
        hi += 1
    pulse = samples[max(lo - 1, 0):min(hi + 1, len(samples) - 1) + 1]
    dv = [0.0, 0.0, 0.0]
    for a, b in zip(pulse, pulse[1:]):
        dt = b[0] - a[0]
        for i in range(3):
            dv[i] += (a[1][i] + b[1][i]) * 0.5 * dt * G
    if len(pulse) == 1:
        dv = [x * 0.01 * G for x in peak[1]]
    pulse_duration = max(pulse[-1][0] - pulse[0][0], 0.01)
    pulse_end = pulse[-1][0]
    fixes = history.locations_between(t - 6, t + 30)
    pre = median([f["speed"] for f in fixes if t - 4 <= f["uptime"] <= t - 0.2 and reliable(f)])
    post = median([f["speed"] for f in fixes if t + 2 <= f["uptime"] <= t + 8 and reliable(f)])
    time_to_stop = basis = None
    stopped = next((f for f in fixes if f["uptime"] > t and reliable(f) and f["speed"] < 0.5), None)
    if stopped:
        time_to_stop, basis = max(stopped["uptime"] - t, pulse_duration), "gps"
    else:
        settled = settle_time([s for s in samples if s[0] > pulse_end])
        if settled is not None:
            time_to_stop, basis = max(settled - t, pulse_duration), "motion"
    decel = pre / time_to_stop / G if pre and time_to_stop and time_to_stop > 0 and pre > 0.5 else None
    delta_v = _mag(dv)
    severity = "severe" if delta_v >= SEVERE_DELTA_V or peak_g >= 20 else \
        "moderate" if delta_v >= MODERATE_DELTA_V or peak_g >= 8 else "minor"
    return {"peak_g": peak_g, "pulse_duration_s": pulse_duration, "delta_v_mps": delta_v,
            "pre_impact_speed_mps": pre, "post_impact_speed_mps": post, "time_to_stop_s": time_to_stop,
            "stop_basis": basis, "average_stop_deceleration_g": decel, "severity": severity, "is_simulated": simulated}


# ---------------------------------------------------------------- packet validation for the agent

IMPACT_FIELDS = {"peak_g": 200, "pulse_duration_s": 10, "delta_v_mps": 100, "pre_impact_speed_mps": 120,
                 "post_impact_speed_mps": 120, "time_to_stop_s": 120, "average_stop_deceleration_g": 50}


def normalize_impact(raw):
    """Validated impact summary from the app (derived numbers only)."""
    if raw is None:
        return None
    if not isinstance(raw, dict) or set(raw) - set(IMPACT_FIELDS) - {"stop_basis", "severity", "is_simulated"}:
        raise ValueError("Invalid impact summary")
    out = {}
    for key, hi in IMPACT_FIELDS.items():
        value = raw.get(key)
        if value is None:
            if key in ("peak_g", "delta_v_mps", "pulse_duration_s"):
                raise ValueError("Impact summary needs peak_g, delta_v_mps and pulse_duration_s")
            continue
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= hi:
            raise ValueError("Invalid " + key)
        out[key] = value
    if raw.get("severity") not in ("minor", "moderate", "severe"):
        raise ValueError("Invalid impact severity")
    if raw.get("stop_basis") not in (None, "gps", "motion"):
        raise ValueError("Invalid stop basis")
    if type(raw.get("is_simulated", False)) is not bool:
        raise ValueError("Invalid simulation flag")
    out.update(severity=raw["severity"], stop_basis=raw.get("stop_basis"), is_simulated=raw.get("is_simulated", False),
               authority="phone_sensor_estimate",
               caveat="Estimated from the phone's accelerometer and GPS, not a vehicle crash recorder; "
                      "it does not establish injury or fault.")
    return out


def describe_impact(impact):
    mph = impact["delta_v_mps"] * 2.23694
    parts = [f"Phone sensors estimated a {impact['severity']} impact: about {impact['peak_g']:.0f} g "
             f"and a speed change of roughly {mph:.0f} mph"]
    if impact.get("time_to_stop_s") is not None:
        parts.append(f"the vehicle stopped about {impact['time_to_stop_s']:.1f} s later")
    return ", and ".join(parts) + ". This is an estimate, not a medical assessment."


def normalize_activity(raw):
    """What the driver is doing right now, for questions outside an incident."""
    if raw is None:
        return None
    if not isinstance(raw, dict) or set(raw) - {"transport", "harsh_brakes_10min", "harsh_accels_10min"}:
        raise ValueError("Invalid activity")
    transport = raw.get("transport")
    if not isinstance(transport, dict) or set(transport) - {"label", "basis", "probability", "model_id"}:
        raise ValueError("Invalid activity transport")
    label, prob, model_id = transport.get("label"), transport.get("probability"), transport.get("model_id")
    if label not in CLASSES + ("unknown",) or transport.get("basis") != "model":
        raise ValueError("Invalid activity mode")
    if type(prob) not in (int, float) or not math.isfinite(prob) or not 0 <= prob <= 1:
        raise ValueError("Invalid activity probability")
    if not isinstance(model_id, str) or not 1 <= len(model_id) <= 120:
        raise ValueError("Model provenance required")
    out = {"transport": {"label": label, "basis": "model", "probability": prob, "model_id": model_id,
                         "accepted": label != "unknown" and prob >= ACCEPTANCE,
                         "caveat": "Softmax score is not calibrated confidence."}}
    for key in ("harsh_brakes_10min", "harsh_accels_10min"):
        value = raw.get(key, 0)
        if type(value) is not int or not 0 <= value <= 1000:
            raise ValueError("Invalid " + key)
        out[key] = value
    return out


def analyze_window(payload):
    """POST /v1/analyze-window: opt-in analysis of an exported synchronized window.

    samples: [[uptime, ax, ay, az, gx, gy, gz, rx, ry, rz], ...] (acceleration and gravity in g, rotation rad/s)
    fixes:   [[uptime, unix_date, lat, lon, horizontal_accuracy_m, speed_mps, speed_accuracy_mps], ...]
    impact_uptime: optional
    """
    if not isinstance(payload, dict) or set(payload) - {"samples", "fixes", "impact_uptime"}:
        raise ValueError("Unsupported fields")
    samples, fixes = payload.get("samples"), payload.get("fixes", [])
    if not isinstance(samples, list) or not 2 <= len(samples) <= SensorHistory.MOTION_CAPACITY:
        raise ValueError("Expected 2-3200 motion samples")
    if not isinstance(fixes, list) or len(fixes) > SensorHistory.LOCATION_CAPACITY:
        raise ValueError("Too many fixes")
    history = SensorHistory()
    for row in samples:
        if not isinstance(row, list) or len(row) != 10 or not history.append_motion(row[0], row[1:4], row[4:7], row[7:10]):
            raise ValueError("Invalid or out-of-order motion sample")
    for row in fixes:
        if not isinstance(row, list) or len(row) != 7 or not history.append_location(*row):
            raise ValueError("Invalid or out-of-order fix")
    end = history.motion[-1][0]
    result = {"transport": None, "harsh_events": [], "impact": None,
              "note": "Derived from the submitted window only; nothing is stored."}
    w = history.window(end, CONTRACT_SAMPLES / CONTRACT_HZ)
    if w:
        result["transport"] = observation(feature_model_probabilities(transport_features(w)))
        result["harsh_events"] = harsh_events(w)
    t = payload.get("impact_uptime")
    if t is not None:
        if not _finite(t):
            raise ValueError("Invalid impact_uptime")
        result["impact"] = impact_report(history, t)
    return result
