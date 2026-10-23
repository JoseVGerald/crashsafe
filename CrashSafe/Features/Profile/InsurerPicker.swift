import SwiftUI

/// Insurance setup: one tap on a big insurer (fills in its claims number) or Other to type a name, then the
/// policy number. Used in onboarding and Profile → Insurance.
struct InsurerPicker: View {
    @Bindable var profile: Profile
    @State private var manual: Bool
    @FocusState private var focus: Field?

    private enum Field { case insurer, policy, phone }

    init(profile: Profile) {
        self.profile = profile
        _manual = State(initialValue: !profile.insurer.isEmpty && !InsurerPreset.all.contains { $0.name == profile.insurer })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your insurance company")
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(InsurerPreset.all) { preset in
                        chip(preset.name, systemImage: "building.columns.fill", isSelected: !manual && profile.insurer == preset.name) {
                            manual = false
                            profile.insurer = preset.name
                            profile.insurerPhone = preset.claimsPhone
                            focus = .policy
                        }
                    }
                    chip("Other", systemImage: "pencil", isSelected: manual) {
                        if InsurerPreset.all.contains(where: { $0.name == profile.insurer }) {
                            profile.insurer = ""
                            profile.insurerPhone = ""
                        }
                        manual = true
                        focus = .insurer
                    }
                }
            }

            if manual {
                FormField(title: "Insurance company", text: $profile.insurer, placeholder: "Company name",
                          systemImage: "building.columns.fill", autocapitalization: .words, focus: $focus, field: .insurer)
                    .submitLabel(.next)
                    .onSubmit { focus = .policy }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            FormField(title: "Policy number", text: $profile.policyNumber, placeholder: "On your insurance card",
                      systemImage: "number", autocapitalization: .characters, focus: $focus, field: .policy)
                .submitLabel(.next)
                .onSubmit { focus = .phone }
            FormField(title: "Claims phone number", text: $profile.insurerPhone, placeholder: "(800) 555-0123",
                      systemImage: "phone.fill", contentType: .telephoneNumber, keyboard: .phonePad, focus: $focus, field: .phone)
            if !manual, InsurerPreset.all.contains(where: { $0.name == profile.insurer }) {
                Text("Filled in with \(profile.insurer)'s auto-claims line. If your card shows a different number, use that one.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: manual)
        .onChange(of: focus) { old, _ in
            if old == .phone { profile.insurerPhone = PhoneFormat.display(profile.insurerPhone) }
        }
    }

    private func chip(_ title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(isSelected ? .white : Brand.textPrimary)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(Brand.fieldFill)))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
