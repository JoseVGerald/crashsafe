import CoreLocation
import SwiftData
import SwiftUI

struct ProfileView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Query private var profiles: [Profile]

    init(user: AuthUser) {
        self.user = user
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile = profiles.first {
                    ProfileContent(user: user, profile: profile)
                } else {
                    ProgressView()
                }
            }
            .background(BrandBackground())
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct ProfileContent: View {
    let user: AuthUser
    @Bindable var profile: Profile
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var addingVehicle = false
    @State private var editingVehicle: Vehicle?
    @State private var addingContact = false
    @State private var editingMedical = false
    @State private var editingInsurance = false
    @State private var showingNearbyHelp = false
    @State private var copiedPolicy = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var delayedCrashSeconds: Int?
    @State private var showingSensorLab = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                pageHeader("Your safety profile",
                           "Key information to keep you safe on the road and help in an emergency.")
                    .padding(.top, Space.lg)
                    .fadeUp()

                vehicles.fadeUp(delay: 0.04)
                medical.fadeUp(delay: 0.08)

                pageHeader("Support details",
                           "Insurance and emergency contacts, so the right people can be reached quickly.")
                    .padding(.top, Space.sm)
                    .fadeUp(delay: 0.1)

                insurance.fadeUp(delay: 0.12)
                contacts.fadeUp(delay: 0.16)
                privacyNote.fadeUp(delay: 0.18)

                section("Driving") {
                    Toggle(isOn: $profile.autoDetectDrives) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch every drive").font(.body.weight(.medium)).foregroundStyle(Brand.textPrimary)
                            Text("Keeps coaching and crash checks running in the background during trips.")
                                .font(.footnote).foregroundStyle(Brand.textSecondary)
                        }
                    }
                    .tint(Brand.blue)
                    .onChange(of: profile.autoDetectDrives) { _, on in
                        // Watching drives that start while the app is closed needs "Always" location.
                        if on, !env.location.hasAlwaysAccess, env.location.canPromptForAlways {
                            env.location.requestAlwaysPermission()
                        }
                    }
                    Divider().overlay(Brand.stroke)
                    permissionRow("Background location", systemImage: "location.fill",
                                  status: locationStatus.text, ok: env.location.hasAlwaysAccess,
                                  action: locationStatus.action) {
                        if !env.location.requestAlwaysPermission() && !env.location.hasAlwaysAccess {
                            PermissionCenter.openSettings()
                        }
                    }
                    Divider().overlay(Brand.stroke)
                    permissionRow("Motion & Fitness", systemImage: "figure.walk.motion",
                                  status: motionStatus, ok: env.permissions.motionGranted,
                                  action: env.permissions.motionDenied ? "Open Settings" : "Allow") {
                        Task { await env.permissions.requestMotion() }
                    }
                    Divider().overlay(Brand.stroke)
                    permissionRow("Notifications", systemImage: "bell.badge.fill",
                                  status: notificationStatus, ok: env.permissions.notificationsGranted,
                                  action: env.permissions.notificationsDenied ? "Open Settings" : "Allow") {
                        Task { await env.permissions.requestNotifications() }
                    }
                    if !env.permissions.notificationsGranted {
                        Text("Without notifications, a crash check-in can't reach you while the phone is locked.")
                            .font(.footnote)
                            .foregroundStyle(Brand.amberInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if profile.autoDetectDrives && !env.location.hasAlwaysAccess {
                        Text("Without “Always”, Pulse can only watch drives while CrashSafe is open or recently used.")
                            .font(.footnote)
                            .foregroundStyle(Brand.amberInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SafetyNotice()
                    .padding(.horizontal, Space.xs)

                account

                testing
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.lg)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Tidy numbers saved before formatting existed.
            let tidy = PhoneFormat.display(profile.insurerPhone)
            if tidy != profile.insurerPhone { profile.insurerPhone = tidy }
        }
        .sheet(isPresented: $addingVehicle) { VehicleEditorView(profile: profile) }
        .sheet(item: $editingVehicle) { VehicleEditorView(profile: profile, vehicle: $0) }
        .sheet(isPresented: $addingContact) { ContactEditorView(profile: profile) }
        .sheet(isPresented: $editingMedical) { MedicalEditorView(profile: profile) }
        .sheet(isPresented: $editingInsurance) { InsuranceEditorView(profile: profile) }
        .fullScreenCover(isPresented: $showingNearbyHelp) { RecoveryView(user: user, outcome: nil) }
        .fullScreenCover(isPresented: $showingSensorLab) { SensorLabView() }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete account and data", role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text("This permanently deletes your account, profile, vehicles, contacts, trips and check-ins from this phone.")
        }
        .confirmationDialog("Sign out of CrashSafe?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { env.session.signOut() }
        } message: {
            Text("Your profile and trips stay saved on this phone.")
        }
    }

    // MARK: Safety profile

    private var vehicles: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Vehicles", action: "Add vehicle", icon: "plus.circle") { addingVehicle = true }
            if profile.vehicles.isEmpty {
                emptyRow("Add the cars you drive.", icon: "car.fill") { addingVehicle = true }
            }
            ForEach(profile.sortedVehicles) { vehicle in
                Button {
                    editingVehicle = vehicle
                } label: {
                    VehicleCard(vehicle: vehicle)
                }
                .buttonStyle(.pressable)
                .contextMenu {
                    if !vehicle.isPrimary {
                        Button("Make primary", systemImage: "star") { withAnimation { profile.makePrimary(vehicle) } }
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) { withAnimation { remove(vehicle) } }
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: profile.vehicles.count)
    }

    private var medical: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Medical information", action: "Edit", icon: "pencil") { editingMedical = true }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    editingMedical = true
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: "staroflife.fill")
                            .font(.title)
                            .foregroundStyle(Brand.blueInk)
                            .frame(width: 40)
                        Text(medicalSummary ?? "Add allergies, conditions and medications")
                            .font(.body.weight(medicalSummary == nil ? .regular : .medium))
                            .foregroundStyle(medicalSummary == nil ? Brand.textSecondary : Brand.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Space.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                Divider().overlay(Brand.stroke).padding(.vertical, 12)
                lockRow("Stored on this phone", "Shown on your crash screen so responders can help.")
            }
            .card(padding: Space.md + 4)
        }
    }

    private var medicalSummary: String? {
        // One item per sentence, comma or line: "Allergic to penicillin. Asthma" → "Allergic to penicillin · Asthma".
        var parts = profile.medicalNotes
            .replacingOccurrences(of: ". ", with: "\n")
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "."))) }
            .filter { !$0.isEmpty }
        if !profile.bloodType.isEmpty { parts.append("Blood type \(profile.bloodType)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Support details

    private var insurance: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Insurance", action: "Edit", icon: "pencil") { editingInsurance = true }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.md) {
                    Image(systemName: "building.columns")
                        .font(.title2)
                        .foregroundStyle(Brand.blueInk)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.insurer.isEmpty ? "Add your insurer" : profile.insurer)
                            .font(.headline)
                            .foregroundStyle(profile.insurer.isEmpty ? Brand.textSecondary : Brand.textPrimary)
                        Text("Auto insurance").font(.subheadline).foregroundStyle(Brand.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 12)

                Divider().overlay(Brand.stroke)

                detailRow("Policy number", value: maskedPolicy) {
                    if !profile.policyNumber.isEmpty {
                        Button {
                            UIPasteboard.general.string = profile.policyNumber
                            copiedPolicy = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copiedPolicy = false }
                        } label: {
                            Image(systemName: copiedPolicy ? "checkmark" : "doc.on.doc")
                                .font(.title3)
                                .foregroundStyle(Brand.blueInk)
                                .frame(width: 44, height: 44)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .sensoryFeedback(.success, trigger: copiedPolicy) { _, new in new }
                        .accessibilityLabel(copiedPolicy ? "Copied" : "Copy policy number")
                    }
                }

                Divider().overlay(Brand.stroke)

                detailRow("Claims phone", value: profile.insurerPhone.isEmpty ? nil : PhoneFormat.display(profile.insurerPhone),
                          icon: "phone.fill") {
                    if let url = phoneURL(profile.insurerPhone) {
                        Link(destination: url) {
                            Image(systemName: "phone.fill")
                                .font(.title3)
                                .foregroundStyle(Brand.blueInk)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Call claims")
                    }
                }
            }
            .card(padding: Space.md + 4)
        }
    }

    private var maskedPolicy: String? {
        let policy = profile.policyNumber.trimmingCharacters(in: .whitespaces)
        guard !policy.isEmpty else { return nil }
        return policy.count <= 4 ? policy : "•••• · " + policy.suffix(4)
    }

    private var contacts: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Family contacts", action: "Add contact", icon: "plus.circle") { addingContact = true }
            if profile.familyContacts.isEmpty {
                emptyRow("Add people to alert if you don't respond.", icon: "person.2.fill") { addingContact = true }
            }
            ForEach(profile.sortedContacts) { contact in
                FamilyContactCard(contact: contact)
                    .contextMenu {
                        Button("Remove contact", systemImage: "trash", role: .destructive) {
                            withAnimation {
                                context.delete(contact)
                                profile.familyContacts.removeAll { $0 === contact }
                            }
                        }
                    }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4), value: profile.familyContacts.count)
    }

    private var privacyNote: some View {
        lockRow("Stored on this phone", "Only you can see this information.")
            .card(padding: Space.md)
    }

    private var locationStatus: (text: String, action: String) {
        switch env.location.authorization {
        case .authorizedAlways: ("Always", "")
        case .authorizedWhenInUse: ("While using the app", env.location.canPromptForAlways ? "Allow Always" : "Open Settings")
        case .notDetermined: ("Not set", "Allow")
        default: ("Off", "Open Settings")
        }
    }

    private var notificationStatus: String {
        if env.permissions.notificationsGranted { return "Allowed" }
        return env.permissions.notificationsDenied ? "Off" : "Not set"
    }

    private var motionStatus: String {
        if env.permissions.motionGranted { return "Allowed" }
        return env.permissions.motionDenied ? "Off" : "Not set"
    }

    private func permissionRow(_ title: String, systemImage: String, status: String, ok: Bool,
                               action: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(ok ? Brand.greenInk : Brand.amberInk)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Brand.textPrimary)
                Text(status).font(.footnote).foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 8)
            if ok {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Brand.greenInk)
                    .accessibilityLabel("Allowed")
            } else {
                Button(action, action: run)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Brand.blueInk.opacity(0.12), in: Capsule())
                    .frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Account

    private var account: some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                Text(user.name.isEmpty ? "Signed in" : user.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(user.email)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Space.xs)

            Button(role: .destructive) {
                confirmingSignOut = true
            } label: {
                Text("Sign out").foregroundStyle(Brand.redInk)
            }
            .buttonStyle(.pill(.ghost, height: 48))

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("Delete account").font(.subheadline).foregroundStyle(Brand.textSecondary)
            }
            .frame(minHeight: 44)

            if let deleteError {
                Text(deleteError).font(.footnote).foregroundStyle(Brand.redInk)
            }
        }
    }

    // MARK: Testing

    /// Everything that exists for demos and development lives here, out of the everyday flow.
    private var testing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Testing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                StatusChip(text: "For testing only", systemImage: "hammer.fill", tint: Brand.amberInk)
            }
            .padding(.horizontal, Space.xs)
            Text("Demo and development tools. You don't need these for everyday driving.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
                .padding(.horizontal, Space.xs)

            VStack(alignment: .leading, spacing: 12) {
                Text("How Pulse coaches you")
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                HStack(spacing: 10) {
                    ForEach(CoachingStyle.allCases) { style in
                        ChoiceTile(title: style == .logical ? "Facts" : "Heart", systemImage: style.systemImage,
                                   isSelected: profile.coachingStyle == style) {
                            profile.coachingStyle = style
                        }
                    }
                }
                Text(profile.coachingStyle.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                Picker("Driving experience", selection: $profile.experience) {
                    ForEach(DrivingExperience.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .card(padding: Space.md)

            PulseVoiceCard()

            VStack(spacing: 0) {
                testRow("Sensor lab: tilt, gyro, speed, replays", systemImage: "gyroscope") { showingSensorLab = true }
                Divider().overlay(Brand.stroke)
                demoDriveRow
                Divider().overlay(Brand.stroke)
                testRow("CarPlay mode", systemImage: "car.rear.fill") { env.router.showingCarPlay = true }
                Divider().overlay(Brand.stroke)
                testRow("Nearby help", systemImage: "cross.case.fill") { showingNearbyHelp = true }
                Divider().overlay(Brand.stroke)
                testRow("Test crash", systemImage: "car.side.rear.and.collision.and.car.side.front", tint: Brand.redInk) {
                    env.crashDetector.simulateCrash()
                }
                Divider().overlay(Brand.stroke)
                testRow(delayedCrashTitle, systemImage: "lock.iphone", tint: Brand.redInk) {
                    scheduleLockedTestCrash()
                }
                .disabled(delayedCrashSeconds != nil)
                Divider().overlay(Brand.stroke)
                testRow("Redo setup", systemImage: "arrow.counterclockwise") { profile.onboardingCompleted = false }
            }
            .card(padding: Space.md)

            backgroundSensorCheck
            motionAnalysis
        }
    }

    /// The transport-mode model and harsh-event rules, live.
    private var motionAnalysis: some View {
        let intelligence = env.intelligence
        let ranked = intelligence.current.map { obs in
            obs.probabilities.enumerated().sorted { $0.element > $1.element }.prefix(3)
                .compactMap { i, p in TransportClass(rawValue: i).map { ($0, p) } }
        } ?? []
        let recent = intelligence.harshEvents(within: 600)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Motion analysis").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text("\(intelligence.windowsAnalyzed) windows").font(.footnote.monospacedDigit()).foregroundStyle(Brand.textSecondary)
            }
            Text("5-second windows at 50 Hz (the transport repo's input), every 2.5 s, from the rolling sensor history.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if ranked.isEmpty {
                Text(env.sensors.health.state == .unavailable ? "No motion sensor on this device." : "Waiting for the first window…")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
            ForEach(ranked, id: \.0) { mode, p in
                HStack(spacing: 10) {
                    Image(systemName: mode.systemImage).frame(width: 24).foregroundStyle(Brand.blueInk)
                    Text(mode.title).font(.subheadline).foregroundStyle(Brand.textPrimary).frame(width: 96, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Brand.fieldFill)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Brand.blue).frame(width: max(4, proxy.size.width * p))
                            }
                    }
                    .frame(height: 8)
                    Text("\(Int((p * 100).rounded()))%").font(.footnote.monospacedDigit())
                        .foregroundStyle(Brand.textSecondary).frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            Divider().overlay(Brand.stroke)
            Text("Hard brakes / accelerations, last 10 min: \(recent.filter { $0.event.kind == .harshBrake }.count) / \(recent.filter { $0.event.kind == .harshAccel }.count)")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
            Text("Model: \(intelligence.model.modelID)")
                .font(.caption.monospaced())
                .foregroundStyle(Brand.textSecondary)
            Menu {
                ForEach(MotionIntelligence.TestMotion.allCases) { kind in
                    Button(kind.rawValue) { intelligence.replay(kind) }
                }
            } label: {
                Label("Replay test motion", systemImage: "play.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .frame(minHeight: 44)
            }
        }
        .card(padding: Space.md)
    }

    /// Proof that sensors keep running with the app closed or the phone locked.
    private var backgroundSensorCheck: some View {
        let log = env.sensors.backgroundLog
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Background sensor check")
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                StatusChip(text: env.sensors.isRunning ? "Sensors on" : "Sensors off",
                           systemImage: env.sensors.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle",
                           tint: env.sensors.isRunning ? Brand.greenInk : Brand.textSecondary)
            }
            Text("Start a drive, lock the phone for a minute, then come back. These counts only go up while CrashSafe is off screen.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Motion").font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                    Text("GPS").font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                }
                GridRow {
                    Text("In background").foregroundStyle(Brand.textPrimary)
                    Text(log.backgroundMotion.formatted()).monospacedDigit().foregroundStyle(Brand.textPrimary)
                    Text(log.backgroundLocation.formatted()).monospacedDigit().foregroundStyle(Brand.textPrimary)
                }
                GridRow {
                    Text("While locked").foregroundStyle(Brand.textPrimary)
                    Text(log.lockedMotion.formatted()).monospacedDigit().foregroundStyle(Brand.textPrimary)
                    Text(log.lockedLocation.formatted()).monospacedDigit().foregroundStyle(Brand.textPrimary)
                }
            }
            .font(.subheadline)
            Text(log.isEmpty ? "No off-screen readings yet." :
                    "Longest motion gap off screen: \(log.longestBackgroundGap.formatted(.number.precision(.fractionLength(2)))) s")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
            Button("Reset counts") { env.sensors.resetBackgroundLog() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.blueInk)
                .frame(minHeight: 44)
        }
        .card(padding: Space.md)
    }

    /// Plays a scripted drive (speed, weather, light) so coaching and CarPlay can be tried without driving.
    @ViewBuilder
    private var demoDriveRow: some View {
        if let scenario = env.driving.scenario {
            testRow("Stop demo drive · \(scenario.title)", systemImage: "stop.fill") {
                env.driving.stop()
                env.conditions.override(with: nil)
                Task { await env.conditions.refresh(for: env.location.location, force: true) }
            }
        } else {
            Menu {
                ForEach(DriveScenario.allCases) { scenario in
                    Button(scenario.title, systemImage: scenario.systemImage) {
                        env.driving.startDemo(scenario)
                        env.conditions.override(with: scenario.weather)
                    }
                }
            } label: {
                HStack {
                    RowLabel(title: "Try a demo drive", systemImage: "play.fill")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
        }
    }

    private var delayedCrashTitle: String {
        delayedCrashSeconds.map { "Lock your phone now… \($0)" } ?? "Test crash in 10 s (lock phone)"
    }

    /// Fires a simulated crash after 10 s so the lock-screen check-in can be tried for real.
    private func scheduleLockedTestCrash() {
        let release = CrashResponseCenter.backgroundTask(named: "Locked test crash")
        let detector = env.crashDetector
        delayedCrashSeconds = 10
        Task {
            for remaining in stride(from: 9, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                delayedCrashSeconds = remaining == 0 ? nil : remaining
            }
            detector.simulateCrash()
            try? await Task.sleep(for: .seconds(1))
            release()
        }
    }

    private func testRow(_ title: String, systemImage: String, tint: Color = Brand.textPrimary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    Text(title).foregroundStyle(tint)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(tint).frame(width: 28)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Brand.textSecondary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: Building blocks

    private func pageHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Brand.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String, action: String, icon: String, run: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: run) {
                Label(action, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("\(action), \(title)")
        }
        .padding(.horizontal, Space.xs)
    }

    private func lockRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Brand.textPrimary)
                Text(detail).font(.footnote).foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func detailRow<Trailing: View>(_ title: String, value: String?, icon: String? = nil,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(Brand.textSecondary)
                HStack(spacing: 8) {
                    if let icon, value != nil {
                        Image(systemName: icon).foregroundStyle(Brand.blueInk)
                    }
                    Text(value ?? "Not added")
                        .font(.title3.weight(value == nil ? .regular : .medium))
                        .foregroundStyle(value == nil ? Brand.textSecondary : Brand.textPrimary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 12)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: 12) { content() }
                .card(padding: Space.md)
        }
    }

    private func emptyRow(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Brand.blueInk)
                Text(text).foregroundStyle(Brand.textSecondary)
                Spacer()
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Brand.blueInk)
            }
            .frame(minHeight: 44)
            .card(padding: Space.md)
        }
        .buttonStyle(.pressable)
    }

    private func deleteAccount() async {
        let id = user.id
        do {
            try await env.session.deleteAccount()
        } catch {
            deleteError = error.localizedDescription
            return
        }
        try? context.delete(model: Trip.self, where: #Predicate { $0.ownerID == id })
        try? context.delete(model: CheckInRecord.self, where: #Predicate { $0.ownerID == id })
        try? context.delete(model: Profile.self, where: #Predicate { $0.ownerID == id })
        try? context.save()
    }

    private func remove(_ vehicle: Vehicle) {
        let wasPrimary = vehicle.isPrimary
        context.delete(vehicle)
        profile.vehicles.removeAll { $0 === vehicle }
        if wasPrimary, let next = profile.sortedVehicles.first { profile.makePrimary(next) }
    }
}

private func phoneURL(_ raw: String) -> URL? {
    let digits = raw.filter { $0.isNumber || $0 == "+" }
    return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
}

// MARK: - Rows

/// Vehicle with a scenic thumbnail, "Primary · Sedan" and a chevron (mockup: Vehicles list).
private struct VehicleCard: View {
    let vehicle: Vehicle

    var body: some View {
        HStack(spacing: 14) {
            VehicleThumbnail()

            VStack(alignment: .leading, spacing: 4) {
                Text(vehicle.displayName)
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    if vehicle.isPrimary {
                        Text("Primary").foregroundStyle(Brand.amberInk).fontWeight(.semibold)
                        Text("·").foregroundStyle(Brand.textSecondary)
                    }
                    Text(vehicle.type.label).foregroundStyle(Brand.textSecondary)
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
        }
        .card(padding: Space.sm + 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit vehicle. Touch and hold for more options.")
    }
}

/// Contact with avatar, relationship, number, and message / call buttons (mockup: Family contacts).
private struct FamilyContactCard: View {
    let contact: FamilyContact

    var body: some View {
        HStack(spacing: 14) {
            Text(initials)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Brand.teal, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name).font(.headline).foregroundStyle(Brand.textPrimary)
                if !contact.relationship.isEmpty {
                    Text(contact.relationship).font(.subheadline).foregroundStyle(Brand.textSecondary)
                }
                Label(PhoneFormat.display(contact.phone), systemImage: "phone.fill")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textPrimary)
                    .labelStyle(TintedIconLabelStyle())
            }
            Spacer(minLength: 0)
            let digits = contact.phone.filter { $0.isNumber || $0 == "+" }
            if let sms = URL(string: "sms:\(digits)") {
                Link(destination: sms) {
                    Image(systemName: "message").font(.title3).foregroundStyle(Brand.blueInk).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Message \(contact.name)")
            }
            if let tel = phoneURL(contact.phone) {
                Link(destination: tel) {
                    Image(systemName: "phone.fill").font(.title3).foregroundStyle(Brand.blueInk).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Call \(contact.name)")
            }
        }
        .card(padding: Space.md)
    }

    private var initials: String {
        contact.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(Brand.blueInk)
            configuration.title
        }
    }
}

// MARK: - Editors

private struct MedicalEditorView: View {
    @Bindable var profile: Profile
    @Environment(\.dismiss) private var dismiss
    @FocusState private var notesFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allergies, conditions, medications")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Brand.textSecondary)
                        TextField("", text: $profile.medicalNotes,
                                  prompt: Text("e.g. Penicillin allergy, asthma, inhaler in glovebox")
                                    .foregroundStyle(Brand.textSecondary.opacity(0.7)),
                                  axis: .vertical)
                            .lineLimit(3...8)
                            .submitLabel(.done)
                            .finishOnReturn(text: $profile.medicalNotes, focus: $notesFocused)
                            .padding(14)
                            .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                        Text("Separate items with commas. Shown to responders on your crash screen.")
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                    }
                    HStack {
                        Text("Blood type").foregroundStyle(Brand.textPrimary)
                        Spacer()
                        Picker("Blood type", selection: $profile.bloodType) {
                            Text("Not set").tag("")
                            ForEach(["A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .frame(minHeight: 44)
                    .card(padding: Space.md)
                }
                .padding(Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BrandBackground())
            .navigationTitle("Medical information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationCornerRadius(28)
    }
}

private struct InsuranceEditorView: View {
    @Bindable var profile: Profile
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field { case insurer, policy, phone }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    FormField(title: "Insurance company", text: $profile.insurer, placeholder: "e.g. State Farm",
                              systemImage: "building.columns.fill", autocapitalization: .words, focus: $focus, field: .insurer)
                        .submitLabel(.next)
                        .onSubmit { focus = .policy }
                    FormField(title: "Policy number", text: $profile.policyNumber, systemImage: "number",
                              autocapitalization: .characters, focus: $focus, field: .policy)
                        .submitLabel(.next)
                        .onSubmit { focus = .phone }
                    FormField(title: "Claims phone", text: $profile.insurerPhone, placeholder: "(800) 555-0100",
                              systemImage: "phone.fill", keyboard: .phonePad, focus: $focus, field: .phone)
                }
                .padding(Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BrandBackground())
            .navigationTitle("Insurance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .onChange(of: focus) { old, _ in
                if old == .phone { profile.insurerPhone = PhoneFormat.display(profile.insurerPhone) }
            }
            .onDisappear { profile.insurerPhone = PhoneFormat.display(profile.insurerPhone) }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
    }
}

#Preview {
    ProfileView(user: PreviewData.user)
        .environment(PreviewData.environment())
        .modelContainer(PreviewData.container())
}
