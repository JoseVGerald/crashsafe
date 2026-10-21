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
    @State private var confirmingSignOut = false
    @FocusState private var focus: Field?
    @FocusState private var notesFocused: Bool

    private enum Field { case insurer, policy, phone }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header.fadeUp()

                section("How Pulse coaches you") {
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
                .fadeUp(delay: 0.04)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Vehicles", action: ("Add", { addingVehicle = true }))
                    if profile.vehicles.isEmpty {
                        emptyRow("Add the cars you drive.", icon: "car.fill") { addingVehicle = true }
                    }
                    ForEach(profile.sortedVehicles) { vehicle in
                        Button {
                            editingVehicle = vehicle
                        } label: {
                            VehicleRow(vehicle: vehicle,
                                       onMakePrimary: { withAnimation { profile.makePrimary(vehicle) } },
                                       onDelete: { withAnimation { remove(vehicle) } })
                                .card()
                        }
                        .buttonStyle(.pressable)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4), value: profile.vehicles.count)
                .fadeUp(delay: 0.08)

                section("Medical") {
                    TextField("", text: $profile.medicalNotes,
                              prompt: Text("Allergies, conditions, medications…").foregroundStyle(Brand.textSecondary.opacity(0.7)),
                              axis: .vertical)
                        .lineLimit(3...8)
                        .submitLabel(.done)
                        .finishOnReturn(text: $profile.medicalNotes, focus: $notesFocused)
                        .padding(14)
                        .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                    Picker("Blood type", selection: $profile.bloodType) {
                        Text("Not set").tag("")
                        ForEach(["A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−"], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minHeight: 44)
                    Text("Shown to responders on your crash screen. Stored only on this phone.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
                .fadeUp(delay: 0.12)

                section("Insurance") {
                    FormField(title: "Insurance company", text: $profile.insurer, systemImage: "building.columns.fill",
                              autocapitalization: .words, focus: $focus, field: .insurer)
                    FormField(title: "Policy number", text: $profile.policyNumber, systemImage: "number",
                              autocapitalization: .characters, focus: $focus, field: .policy)
                    FormField(title: "Claims phone", text: $profile.insurerPhone, systemImage: "phone.fill",
                              keyboard: .phonePad, focus: $focus, field: .phone)
                }
                .fadeUp(delay: 0.16)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Family contacts", action: ("Add", { addingContact = true }))
                    if profile.familyContacts.isEmpty {
                        emptyRow("Add people to alert if you don't respond.", icon: "person.2.fill") { addingContact = true }
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
                }
                .animation(.spring(response: 0.4), value: profile.familyContacts.count)
                .fadeUp(delay: 0.2)

                section("Driving") {
                    Toggle(isOn: $profile.autoDetectDrives) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Watch every drive").font(.body.weight(.medium)).foregroundStyle(Brand.textPrimary)
                            Text("Keeps coaching and crash checks running in the background during trips.")
                                .font(.footnote).foregroundStyle(Brand.textSecondary)
                        }
                    }
                    .tint(Brand.blue)
                    Divider().overlay(Brand.stroke)
                    Button {
                        env.router.showingCarPlay = true
                    } label: {
                        HStack {
                            Label("CarPlay mode", systemImage: "car.rear.fill").foregroundStyle(Brand.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Brand.textSecondary)
                        }
                        .frame(minHeight: 44)
                    }
                    Divider().overlay(Brand.stroke)
                    Button {
                        profile.onboardingCompleted = false
                    } label: {
                        HStack {
                            Label("Redo setup", systemImage: "arrow.counterclockwise").foregroundStyle(Brand.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Brand.textSecondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .fadeUp(delay: 0.24)

                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    Text("Sign out").foregroundStyle(Brand.redInk)
                }
                .buttonStyle(.pill(.ghost, height: 48))
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.lg)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $addingVehicle) { VehicleEditorView(profile: profile) }
        .sheet(item: $editingVehicle) { VehicleEditorView(profile: profile, vehicle: $0) }
        .sheet(isPresented: $addingContact) { ContactEditorView(profile: profile) }
        .confirmationDialog("Sign out of CrashSafe?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { env.session.signOut() }
        } message: {
            Text("Your profile and trips stay saved on this phone.")
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text(initials)
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Brand.heroGradient, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(user.name.isEmpty ? "Your profile" : user.name)
                    .font(.title2.bold())
                    .foregroundStyle(Brand.textPrimary)
                Text(user.email)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.top, Space.lg)
    }

    private var initials: String {
        let letters = user.name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
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

    private func remove(_ vehicle: Vehicle) {
        let wasPrimary = vehicle.isPrimary
        context.delete(vehicle)
        profile.vehicles.removeAll { $0 === vehicle }
        if wasPrimary, let next = profile.sortedVehicles.first { profile.makePrimary(next) }
    }
}

#Preview {
    ProfileView(user: PreviewData.user)
        .environment(PreviewData.environment())
        .modelContainer(PreviewData.container())
}
