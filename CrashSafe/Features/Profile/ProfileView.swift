import SwiftData
import SwiftUI

struct ProfileView: View {
    let user: AuthUser
    @Environment(\.modelContext) private var context
    @State private var viewModel: ProfileViewModel
    @Query private var profiles: [Profile]

    init(user: AuthUser, viewModel: ProfileViewModel) {
        self.user = user
        _viewModel = State(initialValue: viewModel)
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile = profiles.first {
                    ProfileForm(user: user, profile: profile, viewModel: viewModel)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profile")
        }
        .onAppear { viewModel.ensureProfile(existing: profiles, in: context) }
    }
}

private struct ProfileForm: View {
    let user: AuthUser
    @Bindable var profile: Profile
    let viewModel: ProfileViewModel
    @Environment(\.modelContext) private var context
    @State private var showingAddContact = false
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Name", value: user.name.isEmpty ? "—" : user.name)
                LabeledContent("Email", value: user.email)
            }

            Section {
                TextField("Allergies, conditions, medications, blood type…", text: $profile.medicalNotes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Label("Medical notes", systemImage: "heart.text.square.fill")
            } footer: {
                Text("Stored only on this phone. Apps can't read Apple's Medical ID, so add anything responders should know.")
            }

            Section {
                TextField("Make (e.g. Toyota)", text: $profile.carMake)
                    .textContentType(.organizationName)
                TextField("Model (e.g. Camry)", text: $profile.carModel)
                Picker("Type", selection: $profile.carType) {
                    ForEach(CarType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
            } header: {
                Label("Vehicle", systemImage: "car.fill")
            } footer: {
                Text("Car type tunes crash detection.")
            }

            Section {
                TextField("Insurance company", text: $profile.insurer)
                TextField("Policy number (optional)", text: $profile.policyNumber)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } header: {
                Label("Insurance", systemImage: "doc.text.fill")
            }

            Section {
                if profile.familyContacts.isEmpty {
                    Text("Add the people we should alert if you don't respond after a crash.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profile.sortedContacts) { contact in
                    ContactRow(contact: contact) {
                        withAnimation { viewModel.remove(contact, in: context) }
                    }
                }
                .onDelete { offsets in
                    let contacts = profile.sortedContacts
                    for index in offsets { viewModel.remove(contacts[index], in: context) }
                }
                Button {
                    showingAddContact = true
                } label: {
                    Label("Add family contact", systemImage: "person.crop.circle.badge.plus")
                        .frame(minHeight: 44)
                }
            } header: {
                Label("Family contacts", systemImage: "person.2.fill")
            }

            Section {
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    Text("Sign out")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showingAddContact) {
            AddContactView(profile: profile)
        }
        .confirmationDialog("Sign out of CrashSafe?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { viewModel.signOut() }
        } message: {
            Text("Your profile and trips stay saved on this phone.")
        }
    }
}

private struct ContactRow: View {
    let contact: FamilyContact
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.headline)
                Text([contact.relationship, contact.phone].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.danger)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(contact.name)")
        }
    }
}

struct AddContactView: View {
    let profile: Profile
    @State private var viewModel = AddContactViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $viewModel.name)
                        .textContentType(.name)
                    if let error = viewModel.nameError { fieldError(error) }
                    TextField("Phone", text: $viewModel.phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                    if let error = viewModel.phoneError { fieldError(error) }
                    TextField("Relationship (e.g. Mom)", text: $viewModel.relationship)
                }
            }
            .navigationTitle("Family contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if viewModel.add(to: profile) { dismiss() }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func fieldError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.danger)
    }
}

#Preview {
    let env = PreviewData.environment()
    ProfileView(user: PreviewData.user, viewModel: ProfileViewModel(userID: PreviewData.user.id, session: env.session))
        .environment(env)
        .modelContainer(PreviewData.container())
}
