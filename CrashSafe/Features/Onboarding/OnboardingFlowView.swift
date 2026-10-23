import SwiftData
import SwiftUI

/// First-run setup after sign up: about you (which picks the coaching style), vehicles, health, insurance, family,
/// permissions. Pulse watches every drive by default (Profile → Driving changes that).
struct OnboardingFlowView: View {
    let user: AuthUser
    @Bindable var profile: Profile

    enum Step: Int, CaseIterable {
        case welcome, driver, vehicles, health, insurance, family, permissions, done

        var isOptional: Bool { [.vehicles, .health, .insurance, .family].contains(self) }
    }

    @State private var step: Step
    @State private var forward = true

    /// `start` is for previews and screenshots; the app always starts at the welcome step.
    init(user: AuthUser, profile: Profile, start: Step = .welcome) {
        self.user = user
        self.profile = profile
        _step = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome && step != .done {
                header
                    .transition(.opacity)
            }

            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        // Keeps Continue visible above the keyboard.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(BrandBackground())
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: Space.md) {
            HStack {
                Button {
                    go(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Brand.fieldFill, in: Circle())
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("Step \(step.rawValue) of \(Step.allCases.count - 2)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.textSecondary)
                Spacer()
                Button("Skip") { go(1) }
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .opacity(step.isOptional ? 1 : 0)
                    .disabled(!step.isOptional)
            }
            .foregroundStyle(Brand.textPrimary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.fieldFill)
                    Capsule()
                        .fill(Brand.blue)
                        .frame(width: proxy.size.width * Double(step.rawValue) / Double(Step.allCases.count - 2))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    private var footer: some View {
        Button {
            if step == .done {
                withAnimation { profile.onboardingCompleted = true }
            } else {
                go(1)
            }
        } label: {
            Text(primaryTitle)
                .contentTransition(.numericText())
        }
        .buttonStyle(.primary)
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.sm)
        .padding(.top, Space.sm)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Let's go"
        case .permissions: "Continue"
        case .done: "Go to Home"
        default: "Continue"
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        step = next
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep(name: user.firstName)
        case .driver: DriverStep(profile: profile)
        case .vehicles: VehiclesStep(profile: profile)
        case .health: HealthStep(profile: profile)
        case .insurance: InsuranceStep(profile: profile)
        case .family: FamilyStep(profile: profile)
        case .permissions: PermissionsStep(profile: profile)
        case .done: DoneStep(name: user.firstName, profile: profile)
        }
    }
}

/// Shared layout for a step: big title, subtitle, scrollable content.
private struct StepScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(Brand.textPrimary)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(Brand.textSecondary)
                }
                .fadeUp()
                content
                    .fadeUp(delay: 0.08)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct WelcomeStep: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            PulseWordmark()
                .padding(.top, Space.md)
                .fadeUp()
            BrandPhotoView(photo: .roadHero)
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
                .fadeUp(delay: 0.05)
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(name.isEmpty ? "Welcome" : "Welcome, \(name)")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text("A few quick questions to set up your safety profile. It takes about two minutes, and everything stays on this phone.")
                    .font(.body)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fadeUp(delay: 0.1)
            Spacer()
        }
        .padding(.horizontal, Space.lg)
    }
}

/// About you: a few questions Pulse actually uses (who may be in the car after a crash, how to steady you,
/// what to explain first). Together they pick the coaching style quietly (Profile shows and changes it).
private struct DriverStep: View {
    @Bindable var profile: Profile

    var body: some View {
        StepScaffold(title: "A bit about you",
                     subtitle: "Pulse uses these to coach you the way that works for you, and to know who might need help after a crash.") {
            question("How long have you been driving?") {
                HStack(spacing: 8) {
                    ForEach(DrivingExperience.allCases) { option in
                        ChoiceTile(title: option.label, systemImage: icon(for: option), isSelected: profile.experience == option) {
                            profile.experience = option
                            decide()
                        }
                    }
                }
            }
            question("How old are you?") {
                HStack(spacing: 6) {
                    ForEach(AgeBand.allCases) { option in
                        ChoiceTile(title: option.label, systemImage: "person.fill", isSelected: profile.ageBand == option) {
                            profile.ageBand = option
                            decide()
                        }
                    }
                }
            }
            question("What do you drive for most?") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(DrivingPurpose.allCases) { option in
                        ChoiceTile(title: option.label, systemImage: option.systemImage, isSelected: profile.drivingPurpose == option) {
                            profile.drivingPurpose = option
                            decide()
                        }
                    }
                }
            }
            question("Who usually rides with you?") {
                choices(UsualPassengers.allCases, selected: profile.passengers) { profile.passengers = $0 }
            }
            question("How do you feel about driving?") {
                choices(DrivingFeeling.allCases, selected: profile.drivingFeeling) { profile.drivingFeeling = $0 }
            }
            question("Have you been in a crash before?") {
                choices(PastCrash.allCases, selected: profile.pastCrash) { profile.pastCrash = $0 }
            }
        }
        .onAppear(perform: decide)
    }

    private func question<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.textPrimary)
            content()
        }
    }

    private func choices<Option: Identifiable & Equatable>(_ options: [Option], selected: Option?,
                                                         set: @escaping (Option) -> Void) -> some View
        where Option: AboutYouOption {
        HStack(spacing: 8) {
            ForEach(options) { option in
                ChoiceTile(title: option.label, systemImage: option.systemImage, isSelected: selected == option) {
                    set(option)
                    decide()
                }
            }
        }
    }

    /// Re-picks the style whenever an answer changes.
    private func decide() {
        profile.coachingStyle = profile.recommendedCoaching.style
    }

    private func icon(for experience: DrivingExperience) -> String {
        switch experience {
        case .learner: "graduationcap.fill"
        case .newDriver: "leaf.fill"
        case .experienced: "car.fill"
        case .veteran: "star.fill"
        }
    }
}

/// The answer types shown as tiles.
private protocol AboutYouOption {
    var label: String { get }
    var systemImage: String { get }
}
extension UsualPassengers: AboutYouOption {}
extension DrivingFeeling: AboutYouOption {}
extension PastCrash: AboutYouOption {}

private struct VehiclesStep: View {
    @Bindable var profile: Profile
    @State private var editing = false
    @Environment(\.modelContext) private var context

    var body: some View {
        StepScaffold(title: "Your vehicles",
                     subtitle: "Add every car you drive. The type tunes crash detection, and tow drivers need the details.") {
            VStack(spacing: 12) {
                if profile.vehicles.isEmpty {
                    EmptyStateCard(systemImage: "car.side.fill", title: "No vehicles yet",
                                   message: "Add your car, and any others you drive — like a parent's SUV.")
                        .transition(.opacity)
                }
                ForEach(profile.sortedVehicles) { vehicle in
                    VehicleRow(vehicle: vehicle,
                               onMakePrimary: { withAnimation { profile.makePrimary(vehicle) } },
                               onDelete: { withAnimation { remove(vehicle) } })
                        .card()
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                Button {
                    editing = true
                } label: {
                    Label(profile.vehicles.isEmpty ? "Add a vehicle" : "Add another vehicle", systemImage: "plus")
                }
                .buttonStyle(.secondary)
            }
            .animation(.spring(response: 0.4), value: profile.vehicles.count)
        }
        .sheet(isPresented: $editing) {
            VehicleEditorView(profile: profile)
        }
    }

    private func remove(_ vehicle: Vehicle) {
        let wasPrimary = vehicle.isPrimary
        context.delete(vehicle)
        profile.vehicles.removeAll { $0 === vehicle }
        if wasPrimary, let next = profile.sortedVehicles.first { profile.makePrimary(next) }
    }
}

private struct HealthStep: View {
    @Bindable var profile: Profile
    @FocusState private var notesFocused: Bool
    private let bloodTypes = ["A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−"]

    var body: some View {
        StepScaffold(title: "Medical info",
                     subtitle: "Shown to responders on your crash screen. Apps can't read Apple's Medical ID, so add anything important here.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Allergies, conditions, medications")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.textSecondary)
                TextField("", text: $profile.medicalNotes,
                          prompt: Text("e.g. Allergic to penicillin. Asthma — inhaler in glovebox.")
                            .foregroundStyle(Brand.textSecondary.opacity(0.7)),
                          axis: .vertical)
                    .lineLimit(4...8)
                    .submitLabel(.done)
                    .finishOnReturn(text: $profile.medicalNotes, focus: $notesFocused)
                    .padding(14)
                    .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Blood type")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.textSecondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(bloodTypes, id: \.self) { type in
                        Button {
                            profile.bloodType = profile.bloodType == type ? "" : type
                        } label: {
                            Text(type)
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(profile.bloodType == type ? .white : Brand.textPrimary)
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                        .fill(profile.bloodType == type ? AnyShapeStyle(Brand.red) : AnyShapeStyle(Brand.fieldFill))
                                )
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }
}

private struct InsuranceStep: View {
    @Bindable var profile: Profile

    var body: some View {
        StepScaffold(title: "Insurance",
                     subtitle: "So Pulse can help you report a claim with just the facts — no searching through your glovebox.") {
            InsurerPicker(profile: profile)
        }
    }
}

private struct FamilyStep: View {
    @Bindable var profile: Profile
    @State private var adding = false
    @State private var picked: ContactPicker.Picked?
    @Environment(\.modelContext) private var context

    var body: some View {
        StepScaffold(title: "Who should we alert?",
                     subtitle: "If you don't respond after a crash, these people get your location right away.") {
            VStack(spacing: 12) {
                if profile.familyContacts.isEmpty {
                    EmptyStateCard(systemImage: "person.2.fill", title: "No one added yet",
                                   message: "Parents, a partner, a close friend — whoever should know first.",
                                   tint: Brand.teal)
                        .transition(.opacity)
                }
                ForEach(profile.sortedContacts) { contact in
                    ContactRow(contact: contact) {
                        withAnimation {
                            context.delete(contact)
                            profile.familyContacts.removeAll { $0 === contact }
                        }
                    }
                    .card()
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                Button {
                    // Opens Apple Contacts; the pick lands in the editor so a relationship can be added.
                    Task {
                        if let contact = await ContactPicker.pickPhone() { picked = contact }
                    }
                } label: {
                    Label(profile.familyContacts.isEmpty ? "Add a contact" : "Add another contact", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.primary)
                Button("Type it in instead") { adding = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .frame(minHeight: 44)
            }
            .animation(.spring(response: 0.4), value: profile.familyContacts.count)
        }
        .sheet(isPresented: $adding) {
            ContactEditorView(profile: profile)
        }
        .sheet(item: $picked) { contact in
            ContactEditorView(profile: profile, prefill: contact)
        }
    }
}

private struct PermissionsStep: View {
    @Bindable var profile: Profile
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        StepScaffold(title: "Allow a few things",
                     subtitle: "iOS asks you directly. These let CrashSafe notice a crash and send help to the right place.") {
            VStack(spacing: 12) {
                PermissionRow(icon: "location.fill", tint: Brand.blue, title: "Location",
                              detail: "Find help near you and share where you are.",
                              granted: env.location.isAuthorized,
                              actionTitle: env.location.isDenied ? "Settings" : "Allow") {
                    if env.location.isDenied { PermissionCenter.openSettings() } else { env.location.requestPermission() }
                }
                if profile.autoDetectDrives {
                    PermissionRow(icon: "location.circle.fill", tint: Brand.teal, title: "Always allow location",
                                  detail: "So Pulse can notice drives that start while CrashSafe is closed. iOS asks for this separately.",
                                  granted: env.location.hasAlwaysAccess,
                                  actionTitle: env.location.canPromptForAlways ? "Allow" : "Settings") {
                        if !env.location.requestAlwaysPermission() && !env.location.hasAlwaysAccess {
                            PermissionCenter.openSettings()
                        }
                    }
                    .transition(.opacity)
                }
                PermissionRow(icon: "figure.walk.motion", tint: Brand.green, title: "Motion & Fitness",
                              detail: "Detect hard stops and possible crashes.",
                              granted: env.permissions.motionGranted,
                              actionTitle: env.permissions.motionDenied ? "Settings" : "Allow") {
                    Task { await env.permissions.requestMotion() }
                }
                PermissionRow(icon: "bell.badge.fill", tint: Brand.red, title: "Notifications",
                              detail: "Check on you if a crash is detected.",
                              granted: env.permissions.notificationsGranted,
                              actionTitle: env.permissions.notificationsDenied ? "Settings" : "Allow") {
                    Task { await env.permissions.requestNotifications() }
                }
                Text("Changed your mind? You can update these anytime in Profile → Driving or in Settings.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SafetyNotice()
                    .padding(.top, Space.sm)
            }
            .animation(.spring(response: 0.35), value: env.location.isAuthorized)
        }
        .task { await env.permissions.refresh() }
    }
}

private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    var actionTitle = "Allow"
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: icon, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Brand.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Brand.greenInk)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Allowed")
            } else {
                Button(actionTitle, action: request)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .foregroundStyle(.white)
                    .background(Brand.blue, in: Capsule())
                    .frame(minHeight: 44)
            }
        }
        .card()
        .animation(.spring(response: 0.35), value: granted)
    }
}

private struct DoneStep: View {
    let name: String
    let profile: Profile
    @State private var pop = false

    var body: some View {
        VStack(spacing: Space.lg) {
            Spacer()
            ZStack {
                PulseRings(color: Brand.green)
                    .frame(width: 130, height: 130)
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 124, height: 124)
                    .background(Brand.green, in: Circle())
                    .scaleEffect(pop ? 1 : 0.4)
            }
            .frame(height: 220)
            VStack(spacing: Space.sm) {
                Text("You're all set, \(name)")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Brand.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Pulse will watch out for you on every drive.")
                    .foregroundStyle(Brand.textSecondary)
            }
            .fadeUp(delay: 0.15)
            ViewThatFits {
                HStack(spacing: 8) { summaryChips }
                VStack(spacing: 8) { summaryChips }
            }
            .fadeUp(delay: 0.25)
            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .sensoryFeedback(.success, trigger: pop)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.1)) { pop = true }
        }
    }

    @ViewBuilder
    private var summaryChips: some View {
        StatusChip(text: "\(profile.vehicles.count) vehicle\(profile.vehicles.count == 1 ? "" : "s")", systemImage: "car.fill")
        StatusChip(text: "\(profile.familyContacts.count) contact\(profile.familyContacts.count == 1 ? "" : "s")",
                   systemImage: "person.2.fill", tint: Brand.greenInk)
        StatusChip(text: profile.autoDetectDrives ? "Every drive" : "Manual start",
                   systemImage: profile.autoDetectDrives ? "steeringwheel" : "hand.tap.fill", tint: Brand.amberInk)
        StatusChip(text: profile.coachingStyle == .logical ? "Facts" : "Heart",
                   systemImage: profile.coachingStyle.systemImage,
                   tint: profile.coachingStyle == .logical ? Brand.blueInk : Brand.redInk)
    }
}

#Preview {
    let container = PreviewData.container(empty: true)
    let profile = Profile(ownerID: PreviewData.user.id)
    container.mainContext.insert(profile)
    return OnboardingFlowView(user: PreviewData.user, profile: profile)
        .environment(PreviewData.environment())
        .modelContainer(container)
}
