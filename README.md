# CrashSafe (working name)

Congressional App Challenge 2026 project. Other apps detect crashes; this one guides the driver through **what happens next**, even with no signal.

CrashSafe is a mobile app for **iOS and Android**: onboarding, a live Home dashboard, a map trip planner, the crash check-in and post-crash help hub, the Pulse assistant, and a driving coach with CarPlay and Android Auto integrations. This repo contains native SwiftUI and Kotlin/Jetpack Compose implementations, sensor acquisition, and an experimental offline crash-evidence evaluator. AI and family alerts remain behind protocols with mock implementations.

**Platforms:** iOS 17+ and Android 8.0+ (API 26). See the [Android guide](android/README.md) for setup, tests, and platform-specific integrations.

**Real today:** source-linked offline assistant cards, optional RAG backend integration, location, live weather, map search/routing (Apple Maps on iOS; OpenStreetMap-based services on Android), nearby hospitals/police/tow search, offline trip packs, shared timestamped acceleration/rotation/GPS acquisition, experimental crash evidence evaluation during active trips, rules-based coaching with spoken prompts.
**Mocked today:** voice input, family alert delivery, auth (offline mock unless Firebase is set up). *Test crash* still demonstrates the check-in without a physical impact.

Crash thresholds are experimental and have not been validated against real crashes. Background monitoring and battery use require device testing. See [sensor acquisition and crash evaluation](docs/crash-detection.md) for architecture, defaults, tests, step 4 integration, and remaining work.

## Run it

### iOS

Requirements: Xcode 26+ (iOS 17+ target), [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change `project.yml`. Xcode fetches one Swift package on first build: [ThinkingOrbsKit](https://github.com/Jakubantalik/Libraries.dev) (MIT) for Pulse's animated orb, pinned in `Package.resolved`.

1. Open `CrashSafe.xcodeproj`.
2. Pick an iPhone simulator and press **Run** (⌘R).

It runs with zero setup. Auth is the offline mock, so create any account (or tap **Sign in with Apple** for a demo user).

**On a real iPhone:** select the `CrashSafe` target → Signing & Capabilities → choose your Team (or set `DEVELOPMENT_TEAM` in `project.yml`), then run on your device.

**Tests:** ⌘U, or

```bash
xcodebuild test -project CrashSafe.xcodeproj -scheme CrashSafe -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

**After adding/removing files**, regenerate the project:

```bash
xcodegen
```

### Android

Requirements: JDK 17 and the Android SDK (platform 35, build-tools 35). Open `android/` in Android Studio and press **Run**, or build from that directory:

```bash
./gradlew :app:assembleDebug
```

On Windows, use `gradlew.bat :app:assembleDebug`. Install the resulting `android/app/build/outputs/apk/debug/app-debug.apk` on an Android device or emulator. Auth uses the offline mock; create any account or tap **Continue with Google** for a demo user. See the [Android guide](android/README.md) for installation, tests, keys, and Android Auto setup.

## Demo script

Set a simulator or emulator location first (e.g. 47.6101, -122.2015 for Bellevue). In the iOS Simulator, use **Features → Location → Custom Location**; in the Android Emulator, use **Extended controls → Location**.

1. **Create account** → onboarding: pick a coaching style (Facts or Heart), add one or more vehicles, medical info, insurance, a family contact, allow permissions.
2. **Home**: hold the Pulse mic to talk (proof of concept), see live weather and how to drive in it, then **Try a demo drive** to see "You vs. conditions".
3. **Trips**: From uses your current location; for To, search for a destination or **Choose on map** to drop a pin. Save — the route and offline trip pack (real hospitals, police, tow along the route) download automatically.
4. **Home → Test crash**: answer **I need help** or **I'm OK** (or let the 30 s countdown run out) to open the help hub — 911, Pulse, crash location, nearby help with call buttons, share location, responder card, family, scene checklist, insurance.
5. **Driving coach**: open **Home → CarPlay** on iOS or **Profile → Testing → Drive mode** on Android. Switch demo scenarios (forest at night, city rush hour, highway in rain) and switch Profile → Facts/Heart to hear the two coaching styles.

## Project layout

```
CrashSafe/          Native iOS app
  App/              CrashSafeApp, AppEnvironment (service container + session + router), RootView, MainTabView
  DesignSystem/     Theme, button styles, cards, banners
  Models/           SwiftData models (Profile, FamilyContact, Trip, CheckInRecord) + AuthUser, ChatMessage
  Services/         Live services, protocols and mocks (see table below)
  Features/
    Launch/         Animated splash
    Auth/           Landing, sign up (strength meter), sign in, forgot password
    Onboarding/     6-step safety profile setup
    Home/           Pulse hold-to-talk, conditions + driving advice, speed gauge, trips, quick actions
    Trips/          Map planner (current location, search, drop a pin, route), trip detail + trip pack
    CheckIn/        Full-screen "Are you OK?" countdown
    Recovery/       Post-crash help hub (also Home → Nearby help)
    Assistant/      Pulse chat, mic button, suggestions
    Profile/        Coaching style, vehicles, medical, insurance, family, drive monitoring
    CarPlay/        Phone CarPlay mode + native CarPlay scene (templates)
  Support/          PreviewData (mock data for SwiftUI previews)
  Resources/        Assets (placeholder app icon, AccentColor, Danger)
CrashSafeTests/     Swift Testing unit tests
android/           Native Android app (Kotlin + Jetpack Compose)
  app/src/main/    Screens, services, core logic, resources and manifest
  app/src/test/    Core logic tests, shared fixtures and screenshot tests
Backend/rag/       Python assistant backend used by both platforms
```

**iOS architecture:** SwiftUI + MVVM with `@Observable` view models, Swift Concurrency, SwiftData for local storage (profile and trips never leave the phone). Every screen has `#Preview`s with mock data.

**Android architecture:** Kotlin + Jetpack Compose, observable services in `AppEnvironment`, and local JSON storage in `AppStore`. Crash evaluation, coaching and Pulse logic are ported to Kotlin with shared test fixtures. See the [platform mapping](android/README.md#what-maps-to-what) for native service differences.

## Where the stubs live

On iOS, every service is swapped in one place: `AppEnvironment.live()` in [`CrashSafe/App/AppEnvironment.swift`](CrashSafe/App/AppEnvironment.swift). The table below describes the iOS services. Android services are wired in [`android/app/src/main/java/org/cac/crashsafe/app/AppEnvironment.kt`](android/app/src/main/java/org/cac/crashsafe/app/AppEnvironment.kt).

| Team | Protocol | Mock today | What to build |
|---|---|---|---|
| Detection | `CrashDetector` — `Services/CrashDetection/CrashDetector.swift` | `CoreMotionCrashDetector`: shared sensor acquisition, bounded history, experimental evidence evaluation; mocks remain in previews | Validate/calibrate rules and integrate the transportation classifier and team's step 4 candidate detector. See [implementation notes](docs/crash-detection.md). |
| AI | `AssistantService` — `Services/Assistant/AssistantService.swift` | `DirectPulseService` (OpenRouter from the phone, see "Pulse without a server"), falling back to `RAGAssistantService` (local source cards and optional RAG backend) | For a public release, route the model through our server so no keys ship in the app; on-device assistant (Apple Foundation Models + trip pack) when offline. |
| AI | `VoiceInputService` — `Services/Assistant/VoiceInputService.swift` | `MockVoiceInputService` (canned phrases) | On-device speech-to-text. Add mic + speech usage descriptions to the Info.plist settings in `project.yml`. |
| Maps | `TripPackService` — `Services/TripPack/TripPackService.swift` | `MockTripPackService` (fake tow companies/hospitals) | `MKLocalSearch` along the route; persist packs to disk for airplane mode. |
| Backend | `EmergencyAlertService` — `Services/Alerts/EmergencyAlertService.swift` | `MockEmergencyAlertService` (`.sent` online, `.queued` offline) | Push/SMS via our backend; persist a queue when offline. 911 stays with Apple's built-in Crash Detection. |
| — | `ConnectivityMonitor` — `Services/Connectivity/` | Real (`NWPathMonitor`) | — |
| — | `WeatherService` — `Services/Weather/` | Real (`OpenMeteoWeatherService`) | — |
| Detection / AI | `DrivingMonitor`, `DrivingAdvice`, `CoachingEngine`, `DriveCoach` — `Services/Driving/` | Real sensors + rules-based coaching; speed limits only in demo scenarios | Speed-limit data source; swap `CoachingEngine.message` for a model (same inputs/outputs). |

## Switching from mock auth to Firebase on iOS

The `FirebaseAuthService` (email/password + Sign in with Apple) is already written in `Services/Auth/FirebaseAuthService.swift`. It's wrapped in `#if canImport(FirebaseAuth)`, so it compiles only once the SDK is added.

1. Create a Firebase project, add an iOS app with bundle ID `org.cac.crashsafe`, and enable **Email/Password** and **Apple** sign-in providers.
2. Download `GoogleService-Info.plist` into `CrashSafe/`. **Never commit it.** It's already in `.gitignore`.
3. In `project.yml`, uncomment the `Firebase` entry under `packages:` and the two Firebase lines under the target's `dependencies:`, then run `xcodegen`.
4. For Sign in with Apple: in Xcode, target → Signing & Capabilities → **+ Sign in with Apple** (needs a paid Apple Developer team).
5. Run. `AppEnvironment` automatically uses Firebase when the SDK is linked **and** the plist is bundled; otherwise it falls back to the mock.

Using Supabase instead? Write a `SupabaseAuthService: AuthService` and return it from `AppEnvironment.makeAuthService()`. Nothing else changes.

## CarPlay

The iOS integration has two pieces. For the Android car integration, see [Android Auto](android/README.md#android-auto).

- **CarPlay mode (phone)** — `Features/CarPlay/CarPlayModeView.swift`. A full-screen driving dashboard on the phone: speed gauge, limit vs. "safe now" speed, Pulse's advice, g-force, hard brakes, road type. Works anywhere, no approval needed.
- **Native CarPlay** — `Features/CarPlay/CarPlaySceneDelegate.swift`. A real CarPlay scene using Apple's templates (an information screen + alert pop-ups for warnings), driven by the same `DriveCoach`. CarPlay apps can't draw custom UI, so it's simpler than the phone version.
  - **Simulator:** run the app, then in Simulator choose **I/O → External Displays → CarPlay**. The entitlement is applied to simulator builds only.
  - **Real car / App Store:** request the **CarPlay Driving Task** entitlement from Apple (developer.apple.com/carplay). After approval, add `com.apple.developer.carplay-driving-task` to the device entitlements and provisioning profile.

Coaching runs whenever a drive is active (not only on the CarPlay screen). With **Profile → Watch every drive** on, Core Motion's automotive activity starts live monitoring automatically, and the `location` + `audio` background modes keep spoken coaching going with the phone locked.

## Design notes

The details below describe the iOS design system; Android uses Jetpack Compose with the same brand palette and corresponding native components.

- Brand palette: **night blue** (`#2563EB`) with a **signal teal** accent (`#0E7C86`), dark navy canvas with a soft blue/teal glow in dark mode. All defined in `DesignSystem/Brand.swift`.
- Apple-style layout: pill buttons, 20pt rounded cards, 4/8/16/24/48 spacing, fade-up entrances, spring press feedback, haptics.
- High contrast: emergency buttons use fixed dark fills so white text stays readable (≥ 4.5:1) in light and dark mode.
- Primary actions are ≥ 60pt tall; the check-in's answers sit in the bottom half of the screen with **I'm OK** as the biggest target, so it works one-handed.
- Dynamic Type, SF Symbols, dark mode and VoiceOver labels throughout.
- Insurance wording is facts-only ("report promptly, don't guess or admit fault", "not legal advice").

## Apple standards checklist

**In place**
- Human Interface Guidelines: system fonts, SF Symbols, Dynamic Type (layouts restack at accessibility sizes), dark mode, 44pt+ tap targets, ≥ 4.5:1 text contrast, VoiceOver labels, haptics.
- Sign in with Apple uses Apple's own `ASAuthorizationAppleIDButton` (guideline 4.8).
- In-app **Delete account** removes the account and all on-device data (5.1.1(v)).
- `PrivacyInfo.xcprivacy`: no tracking; approximate location (~1 km) sent to Open-Meteo for weather; UserDefaults reason CA92.1.
- Purpose strings for location, background location and motion.
- Safety notice: not an emergency service, doesn't replace 911 / Crash Detection (1.4.1).
- Data attribution: Apple Maps logo + Legal stay visible; "Weather data: Open-Meteo" (CC BY 4.0).

**Before an App Store submission** (not needed for CAC)
- Validate the experimental crash detector, replace AI/alert mocks, and review demo-only UI ("Test crash", demo drives, "(demo)" labels) — 2.1 completeness.
- Real auth backend (Firebase) — the mock stores accounts on-device.
- Be ready to justify `location` (always) + `audio` background modes in review notes (2.5.4).
- CarPlay Driving Task entitlement from Apple; keep phone CarPlay mode voice-first while moving.
- App Store privacy "nutrition label" matching the privacy manifest; a privacy policy URL.
- Final app icon (current one is a placeholder).

## AI use disclosure

Several CAC districts require disclosing AI use. Keep a running list here. Starting entry: the app shell (project setup, screens, mocks, tests and this README) was generated with Claude Code from the team's build prompt, then reviewed and tested by the team.

Shared sensor acquisition and experimental crash-evidence evaluation, their tests, the macOS/iOS verification workflow, and implementation notes were developed with OpenAI Codex. Automated core and iPhone simulator tests were run through GitHub Actions. Real-device and crash-dataset validation remain to be done by the team.


## Pulse without a server

Pulse needs no Mac and no server: the phone asks OpenRouter (free models, with the team's Pulse core prompt,
the app's verified evidence cards and the team's sentence filter) and has Cartesia speak the reply as "Corey".
911 rules run on the phone first. OpenRouter's free plan allows 50 requests a day (adding $10 of credit raises
that to 1,000); past the limit, or with no signal, Pulse answers with the phone's own Apple Intelligence model using
the team's short prompt (`core_mini`), and without that the on-device guides and an Apple voice answer.

That on-device model fallback is specific to iOS. Android uses local guide cards and the phone's text-to-speech voice when cloud services are unavailable; both platforms can use OpenRouter and Cartesia when configured.

To build with the keys (they stay out of git):

```
Tools/Pulse/write_app_keys.sh   # Backend/rag/.env -> Config/Pulse.xcconfig.local (git-ignored)
xcodegen
```

The Android build reads the same git-ignored `Config/Pulse.xcconfig.local`; see its [key setup](android/README.md#run-it).

The keys are readable inside builds made this way, so keep those builds on your own phones. For public distribution on either platform, leave the keys out and deploy `Backend/` (Dockerfile) so the keys stay on a server.

## Source-backed assistant integration

Pulse now uses RAGAssistantService with local evidence fallback. See [integration details](docs/rag-integration.md) for backend startup, incident provenance, profile mapping and remaining validation. The detector still uses experimental rules; no new crash accuracy is claimed. The transport checkpoint is not activated without its missing preprocessing metadata.

The Python backend is included under [Backend/rag](Backend/rag). Run its tests and start the local server there. Repository documentation is indexed separately from driver safety guidance.
