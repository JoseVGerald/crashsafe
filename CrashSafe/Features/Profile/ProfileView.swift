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

            VStack(spacing: 0) {
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
                testRow("Redo setup", systemImage: "arrow.counterclockwise") { profile.onboardingCompleted = false }
            }
            .card(padding: Space.md)
        }
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
            ZStack {
                ScenicRoadArt(showsCar: false)
                Image(systemName: vehicle.type.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .offset(y: 10)
            }
            .frame(width: 100, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .accessibilityHidden(true)

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

    private var tint: Color {
        switch vehicle.colorName {
        case "Black": Color(hex: 0x4A4D52)
        case "White": Color(hex: 0xF2F2F2)
        case "Silver": Color(hex: 0xC0C4CC)
        case "Gray": Color(hex: 0x9A9DA3)
        case "Blue": Color(hex: 0x7FA0CC)
        case "Red": Color(hex: 0xE0574F)
        case "Green": Color(hex: 0x5FAF7A)
        default: Color(hex: 0xD3D6DB)
        }
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
