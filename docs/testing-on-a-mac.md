# Testing sensors, speed and crashes on a Mac

The simulator has no accelerometer or gyroscope, and nobody should crash a car to test the app.
These are the ways to test everything from a computer.

## 1. Virtual stress test (about 10 seconds)

```sh
Tools/StressLab/run.sh
```

On the first run it downloads free datasets into `Backend/datasets/` (gitignored, ~300 MB):

| Dataset | What it is | License |
|---|---|---|
| NHTSA Vehicle Crash Test Database | Real cabin-floor accelerometer recordings from 19 crash tests (35 and 25 mph frontal barrier, side pole, side impact, car into car) | Public domain |
| MotionSense | 7.8 h of iPhone Core Motion at 50 Hz: 24 people walking, jogging, on stairs, sitting, standing | MIT |
| driverBehaviorDataset | 51 min of a phone in a car with labeled aggressive braking, turns and lane changes | Research data, local use only |

Then it runs the app's own crash pipeline (compiled from the same Swift files) on:

- 5,600 generated events: crashes and look-alikes (drops, potholes, speed bumps, door slams, emergency stops…) with random speeds, phone mounts, noise, GPS lag and GPS loss, at ±16 g and ±8 g sensor ranges;
- the real crash pulses, rotated into four phone mounts;
- the real walking and driving data (false alarms, and the walking/running classifier on people it was never tuned on);
- corrupted input (NaN, ∞, timestamps going backward, gaps).

It writes [stress-test-report.md](stress-test-report.md). Options: `--trials 500`, `--seed 7`.

## 2. Unit tests

```sh
swift test                                   # crash evidence, scenarios, sensor math, speed limits (macOS)
cd Backend/rag && .venv/bin/python -m unittest discover -s tests
xcodebuild test -project CrashSafe.xcodeproj -scheme CrashSafe -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`CoreTests/StressScenarioTests.swift` keeps two real NHTSA crashes and the real walking clip that once caused a false alarm as permanent regression tests.

## 3. Sensor lab in the simulator

Profile → Testing → **Sensor lab** shows tilt, acceleration, gyroscope, jolts, GPS speed, the road's speed limit, and what the crash detector would decide. In the simulator, **Choose a clip** plays motion through the real pipeline in real time:

- a real 35 mph crash (NHTSA test 7605), real walking and jogging (MotionSense);
- any generated crash or look-alike;
- your own recordings.

**Also run the real check-in** is off by default: replays never start a check-in or alert anyone. Turn it on during a drive to test the whole "Are you okay?" flow end to end. With it on, contacts **are** alerted if nobody answers.

## 4. GPS speed and speed limits in the simulator

```sh
# Warm the backend's OpenStreetMap cache for an area (Overpass can be slow):
cd Backend/rag && .venv/bin/python rag.py prefetch-roads --bbox 45.512,-122.690,45.578,-122.655
.venv/bin/python rag.py serve --port 8787
# Drive I-5 through Portland at 70 mph:
xcrun simctl location booted start --speed=31 --interval=1 - < Tools/StressLab/routes/portland_i5.txt
# Stop:
xcrun simctl location booted clear
```

Tap **Drive this car**: CarPlay mode opens with the live speed, the posted limit and spoken coaching when you're over it.

Where limits come from (all OpenStreetMap, no key):
- **Quick lookup** (Valhalla, `valhalla1.openstreetmap.de`): the road under the last few GPS points, in under a second. Used only while the phone has no road data for the area. A cold start showed the first limit 0.9 s after the first GPS fix.
- **Area download** (Overpass, all mirrors at once): the ~1 km around the car, saved on the phone for offline matching. It starts as soon as Home knows your location, but the public servers often take 30–90 s or fail, so it never blocks the limit.

Watch it live: `xcrun simctl spawn booted log stream --level debug --predicate 'category == "speed-limits"'` prints each lookup and "first speed limit after … s".

Google's Speed Limits API needs an enterprise Asset Tracking license, and Apple Maps gives apps no speed limits, so neither is used.

## 5. Real phone motion, replayed on the Mac

1. On the iPhone: Sensor lab → **Record 30 s** → **Share CSV** (AirDrop it to the Mac). The CSV has motion and GPS speed, never location.
2. Copy it into the simulator:
   ```sh
   cp pulse-*.csv "$(xcrun simctl get_app_container booted org.cac.crashsafe data)/Documents/Recordings/"
   ```
3. Sensor lab → Choose a clip → **Your recordings**.

## 6. Crash logs from the iPhone

```sh
xcrun devicectl device info files --device <device-id> --domain-type systemCrashLogs | grep CrashSafe
xcrun devicectl device copy from --device <device-id> --domain-type systemCrashLogs --source <file> --destination .
```

## 7. On a real iPhone (quiet, about 10 seconds)

With the phone plugged in and unlocked, this runs the motion path that used to crash on **Drive this car** on the real sensors: Core Motion at ~100 Hz, a live drive with crash monitoring, and the Sensor Lab replaying over live sensors. No speech, siren or alerts.

```sh
xcodebuild test -project CrashSafe.xcodeproj -scheme CrashSafe -destination 'id=<device-id>' \
  -only-testing:CrashSafeTests/OnDeviceSensorTests DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates
```

`xcrun devicectl list devices` shows the device ID. On the simulator these tests skip themselves.

## 8. The check-in voice

The crash check-in's fixed lines are pre-recorded with Kokoro-82M (Apache 2.0) by `Tools/Voice/render_prompts.py` into `CrashSafe/Resources/Voice/`. Whisper transcribed all five back word for word. If you change a line in `CrashResponseCenter`, re-render; `VoiceClipTests` fails until every spoken line has a clip.
