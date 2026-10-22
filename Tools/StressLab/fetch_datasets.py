"""Downloads the free datasets the virtual stress test uses into Backend/datasets/ (gitignored).

    python3 -I Tools/StressLab/fetch_datasets.py Backend/datasets

* NHTSA Vehicle Crash Test Database (public domain, US government): real accelerometer recordings
  from the vehicle floor in barrier, pole, side and rear crash tests. Each test's ISO-MME archive is
  downloaded, the cabin-floor accelerometer is converted to g and averaged into 10 ms bins (what a
  phone sampling at 100 Hz sees), and written as a small JSON clip.
* MotionSense (Malekzadeh et al., IoTDI'19): iPhone 6s Core Motion at 50 Hz, 24 people walking,
  jogging, using stairs, sitting and standing.
* driverBehaviorDataset (Ferreira et al., PLOS ONE 2017): Android phone in a car, ~80 min of real
  driving with labeled aggressive braking, turns and lane changes.

Only public test data is fetched; nothing about the user is sent anywhere.
"""
from __future__ import annotations

import io
import json
import re
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

API = "https://nrd.api.nhtsa.dot.gov/nhtsa/vehicle/api/v1"
UA = {"User-Agent": "CrashSafe stress test (Congressional App Challenge student project)"}
G = 9.80665

# (label, search query, how many)
NHTSA_GROUPS = [
    ("frontal_56kmh", "impactAngleFrom=0&impactAngleTo=0&closingSpeedFrom=55&closingSpeedTo=57.5&testDateFrom=2012-01-01", 5),
    ("frontal_40kmh", "impactAngleFrom=0&impactAngleTo=0&closingSpeedFrom=39&closingSpeedTo=41&testDateFrom=2012-01-01", 5),
    ("side_pole_32kmh", "impactAngleFrom=255&impactAngleTo=290&closingSpeedFrom=31&closingSpeedTo=33&testDateFrom=2012-01-01", 3),
    ("side_mdb", "impactAngleFrom=255&impactAngleTo=290&closingSpeedFrom=60&closingSpeedTo=63&testDateFrom=2012-01-01", 3),
    # NHTSA's rear tests instrument the striking car, so these are car-into-car frontal pulses.
    ("car_to_car_striking", "impactAngleFrom=175&impactAngleTo=185&closingSpeedFrom=45&closingSpeedTo=82&testDateFrom=2008-01-01", 3),
]
# Cabin-floor locations closest to where a phone rides (cup holder, console, mount), best first.
PREFERRED = ["REAR SEAT CROSSMEMBER", "REAR SILL", "VEHICLE CG", "CG", "FLOOR", "CONSOLE", "SILL", "INSTRUMENT PANEL"]
EXCLUDED = ["ENGINE", "CALIPER", "DOOR", "BUMPER", "RADIATOR", "TRUNK", "ROOF", "HEAD", "CHEST", "PELVIS",
            "FEMUR", "TIBIA", "NECK", "SPINE", "BARRIER", "STEERING", "SEAT TRACK", "IMPACTOR", "MDB"]


def get_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def get_bytes(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def parse_channel(text):
    header, values = {}, []
    for line in text.splitlines():
        if ":" in line and not values and not re.match(r"^\s*[-+0-9.eE]+\s*$", line):
            key, _, value = line.partition(":")
            header[key.strip()] = value.strip()
        elif line.strip():
            try:
                values.append(float(line))
            except ValueError:
                pass
    return header, values


def pick_channels(channels):
    """Per vehicle, the best cabin-floor accelerometer for each axis."""
    by_vehicle = {}
    for h, v in channels:
        if h.get("Dimension", "").lower() != "acceleration" or not v:
            continue
        comment = h.get("Comments", "").upper()
        if any(x in comment for x in EXCLUDED):
            continue
        rank = next((i for i, p in enumerate(PREFERRED) if p in comment), None)
        if rank is None:
            continue
        axis = {"longitudinal": "x", "lateral": "y", "vertical": "z"}.get(h.get("Direction", "").lower())
        if not axis:
            continue
        slot = by_vehicle.setdefault(h.get("Test object number", "1"), {})
        if axis not in slot or rank < slot[axis][0]:
            slot[axis] = (rank, h, v)
    # The vehicle with a longitudinal channel and the best rank wins.
    best = None
    for vehicle, axes in by_vehicle.items():
        if "x" not in axes and "y" not in axes:
            continue
        score = min(r for r, _, _ in axes.values())
        if best is None or score < best[0]:
            best = (score, vehicle, axes)
    return best


def to_g(header, values):
    unit = header.get("Unit", "").lower().replace(" ", "")
    if unit in ("m/(s*s)", "m/s2", "m/s**2", "m/s^2"):
        return [x / G for x in values]
    return values  # already g


def bin_100hz(header, values, start=-0.02, end=None):
    dt = float(header["Sampling interval"])
    t0 = float(header["Time of first sample"])
    end = end if end is not None else t0 + dt * len(values)
    out, k = [], 0
    t = start
    while t + 0.01 <= end + 1e-9:
        lo, hi = int(round((t - t0) / dt)), int(round((t + 0.01 - t0) / dt))
        chunk = values[max(lo, 0):max(min(hi, len(values)), 0)]
        out.append(sum(chunk) / len(chunk) if chunk else 0.0)
        t += 0.01
        k += 1
    return out


def delta_v(header, values_g):
    dt = float(header["Sampling interval"])
    t0 = float(header["Time of first sample"])
    # Remove the pre-impact offset, then integrate (m/s).
    pre = [x for i, x in enumerate(values_g) if t0 + i * dt < 0] or [0.0]
    bias = sum(pre) / len(pre)
    total, lowest = 0.0, 0.0
    for x in values_g:
        total += (x - bias) * G * dt
        lowest = min(lowest, total)
    return total, lowest


def fetch_nhtsa(root: Path):
    out = root / "nhtsa"
    (out / "clips").mkdir(parents=True, exist_ok=True)
    for label, query, wanted in NHTSA_GROUPS:
        found = 0
        listing = get_json(f"{API}/vehicle-database-test-results/by-search?{query}&count=40")
        seen = set()
        for test in listing.get("results", []):
            if found >= wanted:
                break
            number = test["testNo"]
            if number in seen:
                continue
            seen.add(number)
            clip = out / "clips" / f"v{number:05d}.json"
            if clip.exists():
                found += 1
                continue
            try:
                docs = get_json(f"{API}/vehicle-documents/test-no/{number}")["results"][0]
                raw = get_bytes(docs["isoFiles"])
            except Exception as exc:
                print(f"{label} {number}: download failed ({exc})")
                continue
            folder = out / "raw" / str(number)
            folder.mkdir(parents=True, exist_ok=True)
            (folder / "iso.zip").write_bytes(raw)
            channels = []
            with zipfile.ZipFile(io.BytesIO(raw)) as z:
                for name in z.namelist():
                    if re.search(r"\.\d{3}$", name):
                        channels.append(parse_channel(z.read(name).decode("latin-1")))
            best = pick_channels(channels)
            if not best:
                print(f"{label} {number}: no cabin-floor accelerometer")
                continue
            _, vehicle, axes = best
            first = next(iter(axes.values()))[1]
            t0 = float(first["Time of first sample"])
            end = min(float(h["Time of first sample"]) + float(h["Sampling interval"]) * len(v) for _, h, v in axes.values())
            data, dv, sources = {}, {}, {}
            for axis in "xyz":
                if axis in axes:
                    _, h, v = axes[axis]
                    g = to_g(h, v)
                    data[axis] = bin_100hz(h, g, start=max(t0, -0.02), end=end)
                    dv[axis] = delta_v(h, g)
                    sources[axis] = h.get("Comments")
            n = min(len(x) for x in data.values())
            clip.write_text(json.dumps({
                "test": number, "group": label, "title": test.get("contractorStudyTitle"),
                "configuration": test.get("testConfiguration"), "closing_kmh": test.get("closingSpeed"),
                "impact_angle": test.get("impactAngle"), "vehicle": vehicle, "channels": sources,
                "hz": 100, "start": max(t0, -0.02),
                "x": data.get("x", [0.0] * n)[:n], "y": data.get("y", [0.0] * n)[:n], "z": data.get("z", [0.0] * n)[:n],
                "delta_v_mps": {k: round(v[0], 3) for k, v in dv.items()},
                "source": "NHTSA Vehicle Crash Test Database (public domain)",
            }, separators=(",", ":")))
            found += 1
            print(f"{label} {number}: {test.get('contractorStudyTitle')} | {', '.join(f'{k}={v}' for k, v in sources.items())} | "
                  f"dv={ {k: round(v[0], 1) for k, v in dv.items()} }")
            time.sleep(1)  # be polite
        print(f"{label}: {found} clips")


def fetch_motionsense(root: Path):
    folder = root / "motionsense"
    if (folder / "A_DeviceMotion_data").exists():
        print("motionsense: present")
        return
    folder.mkdir(parents=True, exist_ok=True)
    raw = get_bytes("https://github.com/mmalekzadeh/motion-sense/raw/master/data/A_DeviceMotion_data.zip")
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        z.extractall(folder, [n for n in z.namelist() if not n.startswith("__MACOSX")])
    print("motionsense: downloaded")


def fetch_driver_behavior(root: Path):
    folder = root / "driver-behavior"
    if folder.exists():
        print("driver-behavior: present")
        return
    subprocess.run(["git", "clone", "-q", "--depth", "1",
                    "https://github.com/jair-jr/driverBehaviorDataset.git", str(folder)], check=True)
    print("driver-behavior: downloaded")


if __name__ == "__main__":
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "Backend/datasets")
    fetch_motionsense(root)
    fetch_driver_behavior(root)
    fetch_nhtsa(root)
