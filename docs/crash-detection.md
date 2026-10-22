# Sensor acquisition and crash evidence evaluation

This implements step 2 (shared sensor acquisition) and step 5 (evaluation of a candidate crash), with the bounded history and replaceable candidate gate needed to connect them. It runs offline during an active trip. It is an experimental prototype; the thresholds below have not been validated against real crashes. Passing software tests does not establish detection accuracy or emergency reliability.

## Data flow

```text
CoreMotionSource ─┐                 ┌─ DrivingMonitor → dashboard / coach
                 ├─ SensorHub ────┤
LocationService ─┘                 └─ CoreMotionCrashDetector
                                      ├─ bounded sensor history
                                      ├─ prototype impact gate OR external step 4 candidate
                                      ├─ CrashEvidenceEvaluator
                                      └─ suspected CrashEvent → existing check-in / recovery UI
```

`AppEnvironment.live()` creates one sensor hub and the live detector. Previews keep their mock detector. A planned or quick trip starts the detector; ending the trip or signing out releases it. Automatic drive coaching alone does not start crash detection. Each sensor consumer owns a lease, so stopping the dashboard does not stop an active detector and stopping the detector does not stop the dashboard. Location updates also continue to serve maps and weather.

## Step 2: acquisition

- Request 100 Hz processed device motion using an arbitrary horizontal reference frame with vertical gravity alignment. Actual delivery is hardware and operating-system dependent; `SensorHealth.measuredHz` measures received samples over approximately one-second intervals.
- Preserve acceleration without gravity and the gravity vector in **g**, and rotation rate in **radians/second**. Do not clip, normalize, or replace large impact readings. A future transport classifier must apply its training preprocessing to a separate copy.
- Use Core Motion's monotonic seconds since boot for durations. Convert GPS measurement dates into the same clock at receipt; retain the original date, coordinates, horizontal accuracy, speed in **meters/second**, and speed accuracy. Dates are retained for display, not elapsed-time calculations. Large wall-clock adjustments can affect GPS alignment and must be covered in device testing.
- Copy Core Motion framework objects into immutable values on a serial acquisition queue, then deliver values on the main actor. Ignore callbacks from a stopped acquisition generation.
- Reject invalid, nonfinite, repeated, reversed, excessively old, and future readings. Count rejected readings. Motion older than 0.5 seconds and GPS older than five seconds at delivery are discarded; a 0.05-second future-clock tolerance accommodates timestamp conversion.
- Report unavailable hardware, denied motion access, interrupted or stale motion, measured sampling rate, sample gaps, and location availability. The Home screen displays monitoring limitations during live driving. The watchdog cannot run while iOS suspends the process; on resumption timestamp gaps remain visible.
- Raw sensor history stays in bounded memory. No sensor logs are automatically written or uploaded.

The collector does not require internet. GPS and motion are independent: losing GPS does not stop motion collection. A negative speed or speed accuracy is preserved as unavailable instead of being interpreted as zero.

## Step 5: evaluation

`CrashEvidenceEvaluator.evaluate(candidate:motion:locations:)` is a pure function. `CrashPipeline` holds at most 2,048 motion samples and 64 GPS fixes, rejects invalid or reversed inputs, accepts one pending candidate, and waits for the post-impact evidence window. A watchdog also advances pending evaluations if motion stops. An incomplete recording becomes **inconclusive**, rather than remaining pending forever.

The default prototype gate creates a candidate when linear acceleration magnitude reaches 3 g. It does not itself emit a crash. It exists to make the pipeline functional until the team's step 4 implementation supplies candidates.

Default evaluation settings are centralized in `CrashEvaluationConfiguration`:

| Setting | Default |
| --- | --- |
| Candidate acceleration | 3 g |
| Strong impact | 6 g |
| Minimum consecutive impact duration | 0.01 seconds |
| Rapid rotation | 2 rad/s |
| Minimum reliable speed loss | 4 m/s and 25% of pre-impact speed |
| Settled post-impact acceleration RMS | At most 0.15 g |
| Pre-impact / post-impact windows | 2 / 3 seconds |
| Delivery grace after the evidence window | 0.5 seconds |
| Maximum acceptable intersample motion gap | 0.15 seconds |
| Cooldown after a suspected crash | 15 seconds after evaluation |

The evaluator checks impact duration, peak acceleration, rotation around the impact, pre/post speed, post-impact acceleration RMS, and a possible phone-drop pattern. Total acceleration near zero for at least 0.06 seconds immediately before impact is a free-fall indicator. This is supporting evidence, not proof that a phone was dropped.

GPS corroboration requires fresh fixes with horizontal accuracy at most 50 m, speed accuracy between 0 and 3 m/s, and valid speed. The pre-impact fix must be no more than two seconds old. The median reliable post-impact speed resists a single noisy fix. Speed loss must exceed both fixes' reported uncertainties in addition to the configured minimum. A single available post-impact fix is accepted, so GPS noise remains a validation concern.

Decision rules:

1. Missing baseline, insufficient post-impact motion, or a gap within the evidence window → **inconclusive**.
2. No sustained impact → **rejected**. A lone high acceleration sample cannot establish duration.
3. Sustained impact plus reliable speed loss → **suspected crash**. Stillness and rotation are not required.
4. If reliable GPS comparison is missing, sustained strong impact plus rapid rotation plus post-impact settling, without the free-fall pattern → **suspected crash**.
5. Strong/rotational events or a possible drop without enough corroboration → **inconclusive**. Continued travel alone does not rule out a crash.
6. Remaining uncorroborated moderate events → **rejected**.

These conservative rules can miss real crashes, including brief impacts and moving or low-speed collisions. Motion-only confirmation can also misidentify phone handling or drops. The three decisions describe the detector's evidence, not injury severity, consciousness, or certainty about whether a collision occurred. There is no invented probability score.

Only `suspectedCrash` produces a non-simulated `CrashEvent` for the existing 30-second check-in. `lastAssessment` exposes every completed evaluation, with evidence, data issues, peak motion, speed measurements, candidate context, and available location. Unknown speed drop is `nil`, never fabricated as zero. Each suspected event starts a cooldown; rejected/inconclusive events have a one-second retry delay. Stopping/restarting monitoring clears pending evidence and cooldown state.

## Connect the team's candidate detector

Disable the prototype gate and submit a candidate on the same sensor clock:

```swift
let detector = CoreMotionCrashDetector(sensors: sensors, automaticCandidates: false)
detector.startMonitoring(carType: .sedan)

// Called by step 4 while processing a shared motion reading.
detector.submitCandidate(CrashCandidate(
    uptime: sample.uptime,
    date: sample.date,
    transportationMode: .car
))
```

Candidates must be within 0.25 seconds of the latest received motion sample. Duplicate or overlapping submissions and submissions during cooldown are refused. Submit from the main actor after the detector has ingested the corresponding reading, or use `CrashPipeline` directly in a coordinated consumer. Step 4 should not create another Core Motion manager.

The transport classifier is not integrated in this change. `TransportationMode` is deliberately separate from the saved vehicle-body `CarType`. The live adapter maps motorcycle/other/remaining body types to motorcycle/unknown/car metadata. Bicycle can be supplied by an external candidate. All modes currently use the same experimental settings; there are no claims of calibrated motorcycle/bicycle detection. Pass a validated configuration to the detector constructor once one is available.

## Build and automated verification

Open the checked-in `CrashSafe.xcodeproj` with Xcode 26+; new source files are included. `project.yml` still discovers the complete app and test folders if regenerated with XcodeGen.

```sh
# Fast platform-independent detection logic and sensor-value tests (Swift 6.2+)
swift test

# Full iOS app + integration tests on a Mac; substitute an installed simulator
xcodebuild test -project CrashSafe.xcodeproj -scheme CrashSafe \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The GitHub workflow selects an installed Xcode 26 and available iPhone automatically, runs both suites, and uploads the build log, test-result bundle, and a zipped simulator app. The ZIP preserves the app bundle and executable permissions. This is a simulator build, not a device-signed IPA. Device signing is not required for simulator builds. New tests cover sensor fan-out, independent lease release, bad data, stale/recovered streams, GPS quality, motion interruptions, isolated spikes, braking, free fall, missing GPS, continued movement, cooldown, bounded memory, external candidates, serialization, and the real sensor-to-event integration. Test traces are synthetic software fixtures, not measured crashes.

## Required real-device validation

Before depending on automatic detection, test foreground, screen lock, app switching, location/motion permission changes, location loss, interruptions, long trips, and low-power mode on supported iPhones. Confirm sustained sample delivery and battery/CPU use; background location permission is not proof of unrestricted background motion execution. Force-quitting or suspension can stop monitoring.

Then replay appropriately licensed and labeled crash/non-crash recordings, preserving device placement, actual sample rate, and physical units. Evaluate held-out devices and trips, false alerts per driving hour, missed crashes, detection latency, and each transportation mode. Do not perform dangerous maneuvers or stage a collision. A sensor recording/export UI and a validated crash dataset are separate follow-up work.

Family-alert delivery and the voice assistant remain mocks. This change does not implement emergency-service calling, real SMS delivery, or durable offline alert queues. A sensor-generated check-in still reaches the existing demo response services.
