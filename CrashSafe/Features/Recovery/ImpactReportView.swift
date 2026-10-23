import SwiftData
import SwiftUI

/// The facts of a crash in two forms, from what the phone recorded at the time (`CrashSnapshot`):
/// one written for you, and one to text, email or show to the police and your insurer, so your agent has
/// what they need without you having to remember it. Neither copy says who was at fault.
struct ImpactReportFacts: Equatable {
    var snapshot: CrashSnapshot
    var outcome: CheckInOutcome
    var driverName: String
    var vehicle: String?
    var insurer: String
    var policyNumber: String
    var claimsPhone: String
    var otherDriver = ""
    var otherInsurance = ""
    var otherPlate = ""
    var policeReportNumber = ""
    /// Blood type and medical notes, only when the driver chooses to add them (e.g. for a medical claim).
    var medical: String?

    static let disclaimer = "Sensor values are estimates from a phone in the vehicle. They are not a crash reconstruction and do not show fault or injury."

    var when: String { snapshot.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute().timeZone()) }

    var whereText: String {
        let address = [snapshot.street, snapshot.place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let coordinates = snapshot.latitude.flatMap { lat in snapshot.longitude.map { String(format: "%.5f, %.5f", lat, $0) } }
        let accuracy = snapshot.accuracyMeters.map { " ±\(Int($0.rounded())) m" } ?? ""
        switch (address.isEmpty, coordinates) {
        case (false, let point?): return "\(address) (\(point)\(accuracy))"
        case (false, nil): return address
        case (true, let point?): return point + accuracy
        case (true, nil): return "Not recorded"
        }
    }

    // MARK: For you

    var headline: String {
        let severity = snapshot.impact?.severity.label ?? "Possible"
        return "\(severity) impact · \(snapshot.date.formatted(date: .omitted, time: .shortened))"
    }

    /// What the phone felt, in everyday words.
    var whatHappened: [String] {
        var lines: [String] = []
        if let impact = snapshot.impact {
            lines.append("Your car's speed changed by about \(Int(impact.deltaVMPH.rounded())) mph in a split second (about \(String(format: "%.2f", impact.pulseDuration)) s).")
            lines.append("At its peak the force was about \(Int(impact.peakG.rounded())) times the pull of gravity, for an instant.")
            if let before = impact.preImpactSpeedMPH { lines.append("You were going about \(Int(before.rounded())) mph just before.") }
            if let stop = impact.timeToStop { lines.append(String(format: "The car came to a stop about %.1f seconds later.", stop)) }
        } else {
            lines.append("Your phone felt a sudden jolt of about \(Int(snapshot.peakG.rounded())) times the pull of gravity.")
            if let drop = snapshot.speedDropMPH { lines.append("Your speed dropped by about \(Int(drop.rounded())) mph.") }
        }
        if snapshot.isSimulated { lines.append("This was a test crash with simulated data.") }
        return lines
    }

    static let lookAfterYourself = "Some injuries, like whiplash or a concussion, can show up hours or days later. Get checked if you notice neck or back pain, a headache, dizziness, confusion or numbness, and keep this report with your visit records for a medical claim."

    static let nextSteps = [
        "Photograph the cars, plates and the scene from a safe spot.",
        "Swap names, phone numbers, plates and insurance with the other driver.",
        "Stick to what you saw. Don't guess, and don't argue about fault.",
        "Send the police & insurer copy to your agent so they can take it from here.",
    ]

    // MARK: For police and insurer

    var officialText: String {
        var lines = ["COLLISION FACTS, RECORDED BY PHONE" + (snapshot.isSimulated ? " (TEST, SIMULATED DATA)" : ""), "",
                     "Date and time: \(when)", "Location: \(whereText)"]
        if let weather = snapshot.weather { lines.append("Conditions: \(weather)") }
        lines.append("Driver: \(driverName.isEmpty ? "Not given" : driverName)")
        if let vehicle, !vehicle.isEmpty { lines.append("Vehicle: \(vehicle)") }
        let insurance = [insurer, policyNumber.isEmpty ? nil : "Policy \(policyNumber)",
                         claimsPhone.isEmpty ? nil : "Claims \(claimsPhone)"].compactMap { $0 }.filter { !$0.isEmpty }
        if !insurance.isEmpty { lines.append("Insurance: " + insurance.joined(separator: " · ")) }
        lines.append("Impact measured by phone sensors: " + impactLine)
        lines.append("Driver check-in: \(outcome.reportLabel) (\(snapshot.date.formatted(date: .omitted, time: .shortened)))")
        if !otherDriver.isEmpty { lines.append("Other driver: \(otherDriver)") }
        if !otherInsurance.isEmpty { lines.append("Other driver's insurance: \(otherInsurance)") }
        if !otherPlate.isEmpty { lines.append("Other vehicle plate: \(otherPlate)") }
        if !policeReportNumber.isEmpty { lines.append("Police report number: \(policeReportNumber)") }
        if let medical, !medical.isEmpty { lines.append("Medical: \(medical)") }
        lines += ["", Self.disclaimer]
        return lines.joined(separator: "\n")
    }

    private var impactLine: String {
        guard let impact = snapshot.impact else {
            return "peak \(String(format: "%.1f", snapshot.peakG)) g" + (snapshot.speedDropMPH.map { ", speed drop about \(Int($0.rounded())) mph (GPS)" } ?? "")
        }
        var parts = ["\(impact.severity.label.lowercased())", String(format: "peak %.1f g", impact.peakG),
                     "speed change about \(Int(impact.deltaVMPH.rounded())) mph over \(Int((impact.pulseDuration * 1000).rounded())) ms"]
        if let before = impact.preImpactSpeedMPH { parts.append("speed before about \(Int(before.rounded())) mph (GPS)") }
        if let stop = impact.timeToStop { parts.append(String(format: "stopped %.1f s later", stop)) }
        return parts.joined(separator: ", ")
    }
}

extension CheckInOutcome {
    /// How the check-in ended, as stated in the report.
    var reportLabel: String {
        switch self {
        case .ok: "driver answered \"I'm okay\""
        case .needsHelp: "driver asked for help"
        case .noResponse: "no answer from the driver"
        }
    }
}

/// The impact report screen: "For you" and "For police & insurer", with ways to send or show the second.
struct ImpactReportView: View {
    @Bindable var record: CheckInRecord
    let profile: Profile?
    let driverName: String

    @Environment(\.openURL) private var openURL
    @State private var copy: Copy = .forYou
    @State private var includeMedical = false

    enum Copy: String, CaseIterable, Identifiable {
        case forYou = "For you", official = "For police & insurer"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                Picker("Copy", selection: $copy) {
                    ForEach(Copy.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if let facts {
                    switch copy {
                    case .forYou: personal(facts)
                    case .official: official(facts)
                    }
                } else {
                    Text("This check-in has no impact details saved.")
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .padding(Space.md)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BrandBackground())
        .navigationTitle("Impact report")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeOut(duration: 0.2), value: copy)
    }

    private var facts: ImpactReportFacts? {
        guard let snapshot = record.snapshot else { return nil }
        let vehicle = profile?.primaryVehicle.map { car in
            [car.year.map(String.init), car.make, car.model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                + (car.colorName.isEmpty ? "" : ", \(car.colorName.lowercased())")
                + (car.plate.isEmpty ? "" : ", plate \(car.plate)")
        }
        let medical = includeMedical ? profile.map { p in
            [p.bloodType.isEmpty ? nil : "blood type \(p.bloodType)", p.medicalNotes.isEmpty ? nil : p.medicalNotes]
                .compactMap { $0 }.joined(separator: "; ")
        } : nil
        return ImpactReportFacts(snapshot: snapshot, outcome: record.outcome, driverName: driverName, vehicle: vehicle,
                                 insurer: profile?.insurer ?? "", policyNumber: profile?.policyNumber ?? "",
                                 claimsPhone: profile?.insurerPhone ?? "", otherDriver: record.otherDriver,
                                 otherInsurance: record.otherInsurance, otherPlate: record.otherPlate,
                                 policeReportNumber: record.policeReportNumber, medical: medical)
    }

    // MARK: For you

    private func personal(_ facts: ImpactReportFacts) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text(facts.headline)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Brand.textPrimary)
                Text(facts.snapshot.latitude == nil && facts.snapshot.street == nil ? "Location wasn't available" : facts.whereText)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
            if let impact = facts.snapshot.impact { ImpactSummary(impact: impact) }

            section("What your phone felt", systemImage: "waveform.path.ecg") {
                ForEach(facts.whatHappened, id: \.self) { Text($0) }
            }
            section("Look after yourself", systemImage: "heart.text.square.fill") {
                Text(ImpactReportFacts.lookAfterYourself)
            }
            section("Next steps", systemImage: "checklist") {
                ForEach(Array(ImpactReportFacts.nextSteps.enumerated()), id: \.offset) { index, step in
                    Label(step, systemImage: "\(index + 1).circle.fill")
                }
            }
            Button("Open the police & insurer copy", systemImage: "doc.text.fill") { copy = .official }
                .buttonStyle(.pill(.primary, height: 54))
        }
    }

    // MARK: For police and insurer

    private func official(_ facts: ImpactReportFacts) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Facts only, ready to show an officer or send to your insurer or agent.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)

            OfficialReportCard(text: facts.officialText)

            VStack(spacing: 10) {
                ShareLink(item: facts.officialText, subject: Text("Collision facts"),
                          message: Text("Collision facts recorded by my phone.")) {
                    Label("Send by text or email", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.pill(.primary, height: 54))

                if let image = Self.picture(of: facts.officialText) {
                    ShareLink(item: image, preview: SharePreview("Collision facts", image: image)) {
                        Label("Save or send as a picture", systemImage: "photo")
                    }
                    .buttonStyle(.pill(.secondary, height: 50))
                }

                if !facts.claimsPhone.isEmpty, let url = URL(string: "tel://" + facts.claimsPhone.filter(\.isNumber)) {
                    Button("Call \(facts.insurer.isEmpty ? "your insurer" : facts.insurer)", systemImage: "phone.fill") { openURL(url) }
                        .buttonStyle(.pill(.secondary, height: 50))
                }
            }

            section("Add the other driver's details", systemImage: "person.2.fill") {
                detailField("Other driver's name and phone", text: $record.otherDriver)
                detailField("Their insurance and policy number", text: $record.otherInsurance)
                detailField("Their license plate", text: $record.otherPlate)
                detailField("Police report number", text: $record.policeReportNumber)
            }

            Toggle("Add my blood type and medical notes (for a medical claim)", isOn: $includeMedical)
                .font(.subheadline)
                .tint(Brand.blue)
                .card(padding: Space.md)
        }
    }

    /// The police & insurer copy as an image, for showing an officer or attaching to a message.
    @MainActor static func picture(of text: String) -> Image? {
        let renderer = ImageRenderer(content: OfficialReportCard(text: text).frame(width: 380).padding(12)
            .background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Brand.textPrimary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .font(.callout)
                .foregroundStyle(Brand.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.md)
    }

    private func detailField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.words)
            .padding(12)
            .background(Brand.fieldFill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// The police & insurer copy, laid out like a printed form (black on white, readable at arm's length).
struct OfficialReportCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.black)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.15)))
    }
}
