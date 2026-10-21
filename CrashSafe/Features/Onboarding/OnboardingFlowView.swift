import CoreMotion
import SwiftUI
import UserNotifications

/// First-run setup after sign up: driver style, vehicles, health, insurance, family, permissions.
struct OnboardingFlowView: View {
    let user: AuthUser
    @Bindable var profile: Profile

    enum Step: Int, CaseIterable {
        case welcome, driver, vehicles, health, insurance, family, permissions, done

        var isOptional: Bool { [.vehicles, .health, .insurance, .family].contains(self) }
    }

    @State private var step: Step = .welcome
    @State private var forward = true

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
                        .fill(Brand.heroGradient)
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
        case .permissions: PermissionsStep()
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
                        .font(.system(size: 32, weight: .bold))
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
        VStack(spacing: Space.lg) {
            Spacer()
            ZStack {
                PulseRings(color: Brand.blue)
                    .frame(width: 130, height: 130)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 124, height: 124)
                    .background(Brand.heroGradient, in: Circle())
            }
            .frame(height: 220)
            .fadeUp()
            VStack(spacing: Space.sm) {
                Text("Welcome, \(name)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                Text("Let's set up your safety profile. It takes about two minutes, and everything stays on this phone.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.textSecondary)
            }
            .fadeUp(delay: 0.1)
            Spacer()
        }
        .padding(.horizontal, Space.lg)
    }
}

private struct DriverStep: View {
    @Bindable var profile: Profile

    var body: some View {
        StepScaffold(title: "How should Pulse coach you?",
                     subtitle: "When you're driving too fast for the conditions, Pulse speaks up in the way that works for you.") {
            VStack(spacing: 12) {
                ForEach(CoachingStyle.allCases) { style in
                    Button {
                        profile.coachingStyle = style
                    } label: {
                        HStack(spacing: 14) {
                            IconBadge(systemName: style.systemImage, tint: style == .logical ? Brand.blue : Brand.red, size: 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(style.title).font(.headline).foregroundStyle(Brand.textPrimary)
                                Text(style.subtitle).font(.subheadline).foregroundStyle(Brand.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: profile.coachingStyle == style ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(profile.coachingStyle == style ? Brand.blueInk : Brand.textSecondary.opacity(0.5))
                        }
                        .card()
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .strokeBorder(Brand.blueInk, lineWidth: profile.coachingStyle == style ? 2 : 0)
                        )
                    }
                    .buttonStyle(.pressable)
                    .sensoryFeedback(.selection, trigger: profile.coachingStyle)
                }

                Text("Example: “\(example)”")
                    .font(.callout.italic())
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.horizontal, Space.xs)
                    .contentTransition(.opacity)
                    .animation(.easeOut, value: profile.coachingStyle)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("How long have you been driving?")
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                HStack(spacing: 8) {
                    ForEach(DrivingExperience.allCases) { option in
                        ChoiceTile(title: option.label, systemImage: icon(for: option), isSelected: profile.experience == option) {
                            profile.experience = option
                        }
                    }
                }
            }
        }
    }

    private var example: String {
        switch profile.coachingStyle {
        case .logical: "At 58 mph on wet pavement you need about 375 ft to stop. At 45 it's 250 ft."
        case .emotional: "Your mom would rather you get home a few minutes late. Let's ease off."
        }
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
    @FocusState private var focus: Field?

    private enum Field { case insurer, policy, phone }

    var body: some View {
        StepScaffold(title: "Insurance",
                     subtitle: "So Pulse can help you report a claim with just the facts — no searching through your glovebox.") {
            VStack(spacing: 18) {
                FormField(title: "Insurance company", text: $profile.insurer, placeholder: "e.g. State Farm", systemImage: "building.columns.fill",
                          autocapitalization: .words, focus: $focus, field: .insurer)
                FormField(title: "Policy number", text: $profile.policyNumber, placeholder: "On your insurance card", systemImage: "number",
                          autocapitalization: .characters, focus: $focus, field: .policy)
                FormField(title: "Claims phone number", text: $profile.insurerPhone, placeholder: "(800) 555-0123", systemImage: "phone.fill",
                          contentType: .telephoneNumber, keyboard: .phonePad, focus: $focus, field: .phone)
            }
        }
    }
}

private struct FamilyStep: View {
    @Bindable var profile: Profile
    @State private var adding = false
    @Environment(\.modelContext) private var context

    var body: some View {
        StepScaffold(title: "Who should we alert?",
                     subtitle: "If you don't respond after a crash, these people get your location right away.") {
            VStack(spacing: 12) {
                if profile.familyContacts.isEmpty {
                    EmptyStateCard(systemImage: "person.2.fill", title: "No one added yet",
                                   message: "Parents, a partner, a close friend — whoever should know first.",
                                   tint: Brand.indigo)
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
                    adding = true
                } label: {
                    Label(profile.familyContacts.isEmpty ? "Add a contact" : "Add another contact", systemImage: "person.badge.plus")
                }
                .buttonStyle(.secondary)
            }
            .animation(.spring(response: 0.4), value: profile.familyContacts.count)
        }
        .sheet(isPresented: $adding) {
            ContactEditorView(profile: profile)
        }
    }
}

private struct PermissionsStep: View {
    @Environment(AppEnvironment.self) private var env
    @State private var motionGranted = CMMotionActivityManager.authorizationStatus() == .authorized
    @State private var notificationsGranted = false

    var body: some View {
        StepScaffold(title: "Allow a few things",
                     subtitle: "These let CrashSafe notice a crash and send help to the right place.") {
            VStack(spacing: 12) {
                PermissionRow(icon: "location.fill", tint: Brand.blue, title: "Location",
                              detail: "Find help near you and share where you are.",
                              granted: env.location.isAuthorized) {
                    env.location.requestPermission()
                }
                PermissionRow(icon: "figure.walk.motion", tint: Brand.green, title: "Motion",
                              detail: "Detect hard stops and possible crashes.",
                              granted: motionGranted) {
                    requestMotion()
                }
                PermissionRow(icon: "bell.badge.fill", tint: Brand.red, title: "Notifications",
                              detail: "Check on you if a crash is detected.",
                              granted: notificationsGranted) {
                    Task {
                        notificationsGranted = (try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .criticalAlert])) ?? false
                    }
                }
            }
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
        }
    }

    private func requestMotion() {
        // Querying activity triggers the Motion & Fitness prompt.
        let manager = CMMotionActivityManager()
        manager.queryActivityStarting(from: .now.addingTimeInterval(-60), to: .now, to: .main) { _, _ in
            Task { @MainActor in
                motionGranted = CMMotionActivityManager.authorizationStatus() == .authorized
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: icon, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Brand.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Brand.greenInk)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Allowed")
            } else {
                Button("Allow", action: request)
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
                    .background(Brand.green.gradient, in: Circle())
                    .scaleEffect(pop ? 1 : 0.4)
            }
            .frame(height: 220)
            VStack(spacing: Space.sm) {
                Text("You're all set, \(name)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Pulse will watch out for you on every drive.")
                    .foregroundStyle(Brand.textSecondary)
            }
            .fadeUp(delay: 0.15)
            HStack(spacing: 8) {
                StatusChip(text: "\(profile.vehicles.count) vehicle\(profile.vehicles.count == 1 ? "" : "s")", systemImage: "car.fill")
                StatusChip(text: "\(profile.familyContacts.count) contact\(profile.familyContacts.count == 1 ? "" : "s")",
                           systemImage: "person.2.fill", tint: Brand.greenInk)
                StatusChip(text: profile.coachingStyle == .logical ? "Facts" : "Heart",
                           systemImage: profile.coachingStyle.systemImage,
                           tint: profile.coachingStyle == .logical ? Brand.blueInk : Brand.redInk)
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
}

#Preview {
    let container = PreviewData.container(empty: true)
    let profile = Profile(ownerID: PreviewData.user.id)
    container.mainContext.insert(profile)
    return OnboardingFlowView(user: PreviewData.user, profile: profile)
        .environment(PreviewData.environment())
        .modelContainer(container)
}
