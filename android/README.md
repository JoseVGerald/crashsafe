# CrashSafe for Android

CrashSafe supports iOS and Android. This directory contains the native Android app, written in Kotlin with Jetpack Compose; the SwiftUI iOS app lives in `../CrashSafe`. Both implementations provide onboarding, trips, crash check-in, post-crash help, Pulse and driving coaching. The core logic (crash evidence, impact analysis, transport mode, speed limits, coaching, Pulse's knowledge search and sentence filter) is a line-by-line port, and the iOS test fixtures run against it unchanged. See the [main README](../README.md) for the project overview.

## Run it

Requirements: JDK 17 and the Android SDK (platform 35, build-tools 35). Android Studio has both. From the command line:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
```

```bash
./gradlew :app:assembleDebug
```

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Or open this folder in Android Studio and press **Run**. The minimum version is Android 8.0 (API 26), and the target is API 35. Auth is the offline mock (the same as iOS), so create any account or tap **Continue with Google** for a demo user.

**Keys:** the build reads the shared git-ignored `../Config/Pulse.xcconfig.local` (OpenRouter, Cartesia, TomTom, RAG endpoint) into `BuildConfig`. Without that file, Pulse falls back to its offline guide cards, speech falls back to the phone's own voice, and speed limits come from OpenStreetMap.

## Tests

```bash
./gradlew :app:testDebugUnitTest
```

- **Logic (71 tests):** crash evidence and the stress scenarios, including the real NHTSA pulses and zero check-ins on everyday look-alikes; parity with the backend to 1e-9; speed-limit matching; Pulse's filter, agent and knowledge search; coaching; and reports. The fixtures are in `app/src/test/resources/fixtures/`.
- **Screens (16 screenshot tests):** `ScreenshotTest` renders every screen on the JVM (Robolectric native graphics + Roborazzi) with mock services and writes PNGs to `app/build/outputs/roborazzi/`. These cover splash, sign-in, onboarding, Home, Trips, Pulse Voice, the Pulse call, Assistant, Profile, Drive mode (portrait and landscape), the crash check-in, Recovery, the impact report, and the Sensor lab replaying a generated crash.

## What maps to what

| iOS | Android |
| --- | --- |
| SwiftUI + `@Observable` | Jetpack Compose + `mutableStateOf` services (`AppEnvironment`) |
| SwiftData | One JSON document (`AppStore`, `files/store.json`), saved after each change |
| Core Motion | `SensorManager` linear acceleration, gravity and gyroscope, converted to Core Motion's units and signs (`AndroidMotionSource`) |
| Core Motion activity ("Watch every drive") | Play services Activity Recognition transitions (`DriveAutoDetector`) |
| Background location + audio modes | A location foreground service plus a partial wake lock while a drive is watched (`DriveMonitorService`) |
| Apple Maps search, routing, places | Photon search, OSRM routes, Overpass hospitals/police/tow, osmdroid maps (dark tiles, attributed) |
| WeatherKit | Open-Meteo |
| SFSpeechRecognizer / AVSpeechSynthesizer | `SpeechRecognizer` (on-device on Android 13+) / `TextToSpeech`; Corey (Cartesia) when online |
| SQLite FTS5 knowledge search | BM25 + Porter stemmer in Kotlin (`PulseKnowledgeIndex`), same weights |
| Lock-screen check-in | Full-screen-intent notification with **I'm OK** / **I need help**, shown over the lock screen |
| CarPlay scene | Android Auto `CarAppService` (`services/carapp`), IoT category, pane template + warning toasts |
| CarPlay mode (phone) | Drive mode (Profile → Testing) |
| Sign in with Apple | Continue with Google (mock, like Apple on iOS) |
| HealthKit fill-in | Not available on Android; the medical editor is typed in |

## Android Auto

Run the app's car screen in the Desktop Head Unit: enable developer mode in the Android Auto app, turn on **Unknown sources**, start the head unit server, and run `desktop-head-unit`. Debug builds accept any host; release builds accept only Google's Android Auto and Automotive template hosts (`res/values/car_hosts.xml`). Publishing to real cars needs Google's review for the IoT category.

## Not verified yet

These checks were build-only (no emulator or device was used):

- Real sensors, GPS, background drive watching with the screen off, and battery use.
- Speech recognition, text-to-speech, Corey audio, and the check-in alarm sound.
- Notifications, including the full-screen check-in over the lock screen.
- Android Auto in the head unit.
- The R8-minified release APK at runtime (keep rules are in `proguard-rules.pro`).
- Live network services (Photon, OSRM, Overpass, Open-Meteo, TomTom, OpenRouter). The screenshot tests use mocks, so their maps show osmdroid's offline placeholder grid.
