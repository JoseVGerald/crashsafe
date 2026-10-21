# CrashSafe (working name)

Congressional App Challenge 2026 project. Other apps detect crashes; this one guides the driver through **what happens next**, even with no signal.

This repo is the **iOS app shell**: launch, auth, and every client screen, with all AI, detection, maps and alerting behind protocols with mock implementations so each team can plug in the real thing without touching the UI.

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

1. Sign up → **Profile**: add medical notes, car, insurer and at least one family contact.
2. **Trips**: plan Seattle → Spokane, save, open it, **Download trip pack**.
3. **Home**: **Start a trip** (crash detection turns on), then **Debug → Simulate crash**.
4. Check-in: tap **I'm OK** → **Talk to the assistant** (try the mic button), or let the 30s countdown run out to show the unconscious path (family alert).

## Project layout

```
CrashSafe/
  App/              CrashSafeApp, AppEnvironment (service container + session + router), RootView, MainTabView
  DesignSystem/     Theme, button styles, cards, banners
  Models/           SwiftData models (Profile, FamilyContact, Trip, CheckInRecord) + AuthUser, ChatMessage
  Services/         Protocols + mocks (see table below)
  Features/
    Launch/         Animated splash
    Auth/           Sign in, sign up, forgot password, validation
    Home/           Start/end trip, current trip, last check-in, Debug → Simulate crash
    Trips/          Trip planner, saved trips, trip detail + trip pack download
    CheckIn/        Full-screen "Are you OK?" countdown and the three outcome paths
    Assistant/      Chat UI, mic button, suggestions
    Profile/        Medical, vehicle, insurance, family contacts, sign out
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

## Switching from mock auth to Firebase

The `FirebaseAuthService` (email/password + Sign in with Apple) is already written in `Services/Auth/FirebaseAuthService.swift`. It's wrapped in `#if canImport(FirebaseAuth)`, so it compiles only once the SDK is added.

1. Create a Firebase project, add an iOS app with bundle ID `org.cac.crashsafe`, and enable **Email/Password** and **Apple** sign-in providers.
2. Download `GoogleService-Info.plist` into `CrashSafe/`. **Never commit it.** It's already in `.gitignore`.
3. In `project.yml`, uncomment the `packages:` block and the target `dependencies:` block, then run `xcodegen`.
4. For Sign in with Apple: in Xcode, target → Signing & Capabilities → **+ Sign in with Apple** (needs a paid Apple Developer team).
5. Run. `AppEnvironment` automatically uses Firebase when the SDK is linked **and** the plist is bundled; otherwise it falls back to the mock.

Using Supabase instead? Write a `SupabaseAuthService: AuthService` and return it from `AppEnvironment.makeAuthService()`. Nothing else changes.

## Design notes

- Calm, high-contrast UI: one accent color, emergency buttons use fixed dark fills so white text stays readable (≥ 4.5:1) in light and dark mode.
- Primary actions are ≥ 60pt tall; the check-in's answers sit in the bottom half of the screen with **I'm OK** as the biggest target, so it works one-handed.
- Dynamic Type, SF Symbols, dark mode and VoiceOver labels throughout.
- Insurance wording is facts-only ("report promptly, don't guess or admit fault", "not legal advice").

## AI use disclosure

Several CAC districts require disclosing AI use. Keep a running list here. Starting entry: the app shell (project setup, screens, mocks, tests and this README) was generated with Claude Code from the team's build prompt, then reviewed and tested by the team.
