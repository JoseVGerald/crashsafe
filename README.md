# CrashSafe (working name)

Congressional App Challenge 2026 project. Other apps detect crashes; this one guides the driver through **what happens next**, even with no signal.

This repo is the iOS app: onboarding, a live Home dashboard, a map trip planner, the crash check-in and post-crash help hub, the Pulse assistant, and a CarPlay driving coach. AI, crash detection and family alerts are still behind protocols with mock implementations so each team can plug in the real thing without touching the UI.

**Real today:** location, live weather (Open-Meteo, no key), Apple Maps search/routing, nearby hospitals/police/tow search, offline trip packs, speed + accelerometer monitoring, rules-based coaching with spoken prompts.
**Mocked today:** crash detection (use *Test crash*), the AI replies and voice input, family alert delivery, auth (offline mock unless Firebase is set up).

## Run it

Requirements: Xcode 26+ (iOS 17+ target), [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change `project.yml`.

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

## Demo script

In the simulator, set a location first: **Features → Location → Custom Location** (e.g. 47.6101, -122.2015 for Bellevue).

1. **Create account** → onboarding: pick a coaching style (Facts or Heart), add one or more vehicles, medical info, insurance, a family contact, allow permissions.
2. **Home**: hold the Pulse mic to talk (proof of concept), see live weather and how to drive in it, then **Try a demo drive** to see "You vs. conditions".
3. **Trips**: From uses your current location; for To, search Apple Maps or **Choose on map** to drop a pin. Save — the route and offline trip pack (real hospitals, police, tow along the route) download automatically.
4. **Home → Test crash**: answer **I need help** or **I'm OK** (or let the 30 s countdown run out) to open the help hub — 911, Pulse, crash location, nearby help with call buttons, share location, responder card, family, scene checklist, insurance.
5. **Home → CarPlay**: the driving coach. Switch demo scenarios (forest at night, city rush hour, highway in rain) and switch Profile → Facts/Heart to hear the two coaching styles.

## Project layout

```
CrashSafe/
  App/              CrashSafeApp, AppEnvironment (service container + session + router), RootView, MainTabView
  DesignSystem/     Theme, button styles, cards, banners
  Models/           SwiftData models (Profile, FamilyContact, Trip, CheckInRecord) + AuthUser, ChatMessage
  Services/         Protocols + mocks (see table below)
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
```

Architecture: SwiftUI + MVVM with `@Observable` view models, Swift Concurrency, SwiftData for local storage (profile and trips never leave the phone). Every screen has `#Preview`s with mock data.

## Where the stubs live

Every service is swapped in one place: `AppEnvironment.live()` in [`CrashSafe/App/AppEnvironment.swift`](CrashSafe/App/AppEnvironment.swift).

| Team | Protocol | Mock today | What to build |
|---|---|---|---|
| Detection | `CrashDetector` — `Services/CrashDetection/CrashDetector.swift` | `MockCrashDetector` (only `simulateCrash()` fires) | `CoreMotionCrashDetector`: accelerometer + GPS speed drop, tuned by `CarType`. Emit a `CrashEvent` on the `events` stream; the check-in screen appears automatically. |
| AI | `AssistantService` — `Services/Assistant/AssistantService.swift` | `MockAssistantService` (keyword canned replies) | Cloud assistant (calls **our server**; never ship API keys in the app) + on-device assistant (Apple Foundation Models + trip pack). Pick based on `ConnectivityMonitor.isOnline`. `AssistantContext` already carries profile, trip and scenario. |
| AI | `VoiceInputService` — `Services/Assistant/VoiceInputService.swift` | `MockVoiceInputService` (canned phrases) | On-device speech-to-text. Add mic + speech usage descriptions to the Info.plist settings in `project.yml`. |
| Maps | `TripPackService` — `Services/TripPack/TripPackService.swift` | `MockTripPackService` (fake tow companies/hospitals) | `MKLocalSearch` along the route; persist packs to disk for airplane mode. |
| Backend | `EmergencyAlertService` — `Services/Alerts/EmergencyAlertService.swift` | `MockEmergencyAlertService` (`.sent` online, `.queued` offline) | Push/SMS via our backend; persist a queue when offline. 911 stays with Apple's built-in Crash Detection. |
| — | `ConnectivityMonitor` — `Services/Connectivity/` | Real (`NWPathMonitor`) | — |
| — | `WeatherService` — `Services/Weather/` | Real (`OpenMeteoWeatherService`) | — |
| Detection / AI | `DrivingMonitor`, `DrivingAdvice`, `CoachingEngine`, `DriveCoach` — `Services/Driving/` | Real sensors + rules-based coaching; speed limits only in demo scenarios | Speed-limit data source; swap `CoachingEngine.message` for a model (same inputs/outputs). |

## Switching from mock auth to Firebase

The `FirebaseAuthService` (email/password + Sign in with Apple) is already written in `Services/Auth/FirebaseAuthService.swift`. It's wrapped in `#if canImport(FirebaseAuth)`, so it compiles only once the SDK is added.

1. Create a Firebase project, add an iOS app with bundle ID `org.cac.crashsafe`, and enable **Email/Password** and **Apple** sign-in providers.
2. Download `GoogleService-Info.plist` into `CrashSafe/`. **Never commit it.** It's already in `.gitignore`.
3. In `project.yml`, uncomment the `packages:` block and the target `dependencies:` block, then run `xcodegen`.
4. For Sign in with Apple: in Xcode, target → Signing & Capabilities → **+ Sign in with Apple** (needs a paid Apple Developer team).
5. Run. `AppEnvironment` automatically uses Firebase when the SDK is linked **and** the plist is bundled; otherwise it falls back to the mock.

Using Supabase instead? Write a `SupabaseAuthService: AuthService` and return it from `AppEnvironment.makeAuthService()`. Nothing else changes.

## CarPlay

There are two pieces:

- **CarPlay mode (phone)** — `Features/CarPlay/CarPlayModeView.swift`. A full-screen driving dashboard on the phone: speed gauge, limit vs. "safe now" speed, Pulse's advice, g-force, hard brakes, road type. Works anywhere, no approval needed.
- **Native CarPlay** — `Features/CarPlay/CarPlaySceneDelegate.swift`. A real CarPlay scene using Apple's templates (an information screen + alert pop-ups for warnings), driven by the same `DriveCoach`. CarPlay apps can't draw custom UI, so it's simpler than the phone version.
  - **Simulator:** run the app, then in Simulator choose **I/O → External Displays → CarPlay**. The entitlement is applied to simulator builds only.
  - **Real car / App Store:** request the **CarPlay Driving Task** entitlement from Apple (developer.apple.com/carplay). After approval, add `com.apple.developer.carplay-driving-task` to the device entitlements and provisioning profile.

Coaching runs whenever a drive is active (not only on the CarPlay screen). With **Profile → Watch every drive** on, Core Motion's automotive activity starts live monitoring automatically, and the `location` + `audio` background modes keep spoken coaching going with the phone locked.

## Design notes

- Brand palette: **night blue** (`#2563EB`) with a **signal teal** accent (`#0E7C86`), dark navy canvas with a soft blue/teal glow in dark mode. All defined in `DesignSystem/Brand.swift`.
- Apple-style layout: pill buttons, 20pt rounded cards, 4/8/16/24/48 spacing, fade-up entrances, spring press feedback, haptics.
- High contrast: emergency buttons use fixed dark fills so white text stays readable (≥ 4.5:1) in light and dark mode.
- Primary actions are ≥ 60pt tall; the check-in's answers sit in the bottom half of the screen with **I'm OK** as the biggest target, so it works one-handed.
- Dynamic Type, SF Symbols, dark mode and VoiceOver labels throughout.
- Insurance wording is facts-only ("report promptly, don't guess or admit fault", "not legal advice").

## AI use disclosure

Several CAC districts require disclosing AI use. Keep a running list here. Starting entry: the app shell (project setup, screens, mocks, tests and this README) was generated with Claude Code from the team's build prompt, then reviewed and tested by the team.
