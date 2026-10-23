import SwiftUI

/// "Fill from Apple Health": reads blood type, age and tracked medications (with permission) into the
/// profile, then says what it filled. Hidden where Health isn't available (e.g. iPad).
struct AppleHealthFillButton: View {
    @Bindable var profile: Profile
    @State private var importer = AppleHealthImport()
    @State private var status: String?
    @State private var working = false

    var body: some View {
        if AppleHealthImport.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await fill() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.text.square.fill")
                            .font(.title3)
                            .foregroundStyle(.pink)
                        Text(working ? "Reading Apple Health…" : "Fill from Apple Health")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Spacer(minLength: 0)
                        if working { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 14)
                    .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                }
                .buttonStyle(.pressable)
                .disabled(working)
                Text(status ?? "Blood type, age and the medications you track in Health. Nothing is written to Health.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .contentTransition(.opacity)
            }
        }
    }

    private func fill() async {
        working = true
        defer { working = false }
        do {
            let filled = profile.apply(try await importer.read())
            status = filled.isEmpty
                ? "Nothing new to add. Health may not have these, or access wasn't allowed (Settings → Health → Data Access)."
                : "Added " + ListFormatter.localizedString(byJoining: filled) + " from Apple Health."
        } catch {
            status = error.localizedDescription
        }
    }
}
