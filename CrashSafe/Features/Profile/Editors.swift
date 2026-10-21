import SwiftUI

// MARK: - Vehicle editor

/// Add or edit a vehicle. Used by onboarding and Profile.
struct VehicleEditorView: View {
    let profile: Profile
    var vehicle: Vehicle?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var make = ""
    @State private var model = ""
    @State private var year = ""
    @State private var type: CarType = .sedan
    @State private var colorName = ""
    @State private var plate = ""
    @State private var attempted = false
    @FocusState private var focus: Field?

    private enum Field { case make, model, year, plate }

    private let colors: [(name: String, color: Color)] = [
        ("Black", .black), ("White", .white), ("Silver", Color(hex: 0xC0C4CC)), ("Gray", .gray),
        ("Blue", Brand.blue), ("Red", Brand.red), ("Green", Brand.green), ("Other", Color(hex: 0xB08D57)),
    ]

    private var makeError: String? {
        attempted && make.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the make." : nil
    }

    private var yearError: String? {
        guard attempted, !year.isEmpty else { return nil }
        guard let value = Int(year), (1950...2030).contains(value) else { return "Enter a year like 2019." }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type").font(.subheadline.weight(.medium)).foregroundStyle(Brand.textSecondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(CarType.allCases) { option in
                                ChoiceTile(title: option.label, systemImage: option.systemImage, isSelected: type == option) {
                                    type = option
                                }
                            }
                        }
                    }

                    FormField(title: "Make", text: $make, error: makeError, placeholder: "e.g. Toyota", systemImage: "car.fill",
                              autocapitalization: .words, focus: $focus, field: .make)
                        .submitLabel(.next)
                        .onSubmit { focus = .model }
                    HStack(alignment: .top, spacing: 12) {
                        FormField(title: "Model", text: $model, placeholder: "e.g. Camry", autocapitalization: .words, focus: $focus, field: .model)
                            .submitLabel(.next)
                            .onSubmit { focus = .year }
                        FormField(title: "Year", text: $year, error: yearError, placeholder: "2019", keyboard: .numberPad,
                                  focus: $focus, field: .year)
                            .frame(width: 110)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Color").font(.subheadline.weight(.medium)).foregroundStyle(Brand.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(colors, id: \.name) { option in
                                Button {
                                    colorName = colorName == option.name ? "" : option.name
                                } label: {
                                    Circle()
                                        .fill(option.color)
                                        .overlay(Circle().strokeBorder(Brand.stroke, lineWidth: 1))
                                        .frame(width: 32, height: 32)
                                        .padding(3)
                                        .overlay(Circle().strokeBorder(Brand.blueInk, lineWidth: colorName == option.name ? 2.5 : 0))
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel(option.name)
                                .accessibilityAddTraits(colorName == option.name ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 2)
                        }
                        .scrollClipDisabled()
                    }

                    FormField(title: "License plate (optional)", text: $plate, placeholder: "e.g. ABC1234", systemImage: "number",
                              autocapitalization: .characters, focus: $focus, field: .plate)
                }
                .padding(Space.lg)
                .animation(.easeOut(duration: 0.2), value: type)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BrandBackground())
            .navigationTitle(vehicle == nil ? "Add vehicle" : "Edit vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
        .presentationCornerRadius(28)
    }

    private func load() {
        guard let vehicle else { return }
        make = vehicle.make
        model = vehicle.model
        year = vehicle.year.map(String.init) ?? ""
        type = vehicle.type
        colorName = vehicle.colorName
        plate = vehicle.plate
    }

    private func save() {
        attempted = true
        guard makeError == nil, yearError == nil else { return }
        let target = vehicle ?? Vehicle(make: "", model: "")
        target.make = make.trimmingCharacters(in: .whitespaces)
        target.model = model.trimmingCharacters(in: .whitespaces)
        target.year = Int(year)
        target.type = type
        target.colorName = colorName
        target.plate = plate.trimmingCharacters(in: .whitespaces).uppercased()
        if vehicle == nil {
            target.isPrimary = profile.vehicles.isEmpty
            context.insert(target)
            profile.vehicles.append(target)
        }
        dismiss()
    }
}

/// Selectable tile with an icon (vehicle types, coaching styles…).
struct ChoiceTile: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 24)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .foregroundStyle(isSelected ? .white : Brand.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Brand.heroGradient) : AnyShapeStyle(Brand.fieldFill))
            )
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}

// MARK: - Contact editor

struct ContactEditorView: View {
    let profile: Profile
    @State private var viewModel = AddContactViewModel()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field { case name, phone, relationship }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    FormField(title: "Name", text: $viewModel.name, error: viewModel.nameError, placeholder: "e.g. Maria Lopez", systemImage: "person.fill",
                              contentType: .name, autocapitalization: .words, focus: $focus, field: .name)
                    FormField(title: "Phone", text: $viewModel.phone, error: viewModel.phoneError, placeholder: "(206) 555-0100", systemImage: "phone.fill",
                              contentType: .telephoneNumber, keyboard: .phonePad, focus: $focus, field: .phone)
                    FormField(title: "Relationship", text: $viewModel.relationship, placeholder: "e.g. Mom", systemImage: "heart.fill",
                              autocapitalization: .words, focus: $focus, field: .relationship)
                }
                .padding(Space.lg)
            }
            .background(BrandBackground())
            .navigationTitle("Family contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if viewModel.add(to: profile) { dismiss() }
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { focus = .name }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
    }
}

// MARK: - Rows

struct VehicleRow: View {
    let vehicle: Vehicle
    var onMakePrimary: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: vehicle.type.systemImage, tint: Brand.blue, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(vehicle.displayName)
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    if vehicle.isPrimary {
                        StatusChip(text: "Primary", systemImage: "star.fill", tint: Brand.blueInk)
                    }
                    Text(vehicle.detail).font(.subheadline).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if onMakePrimary != nil || onDelete != nil {
                Menu {
                    if !vehicle.isPrimary, let onMakePrimary {
                        Button("Make primary", systemImage: "star", action: onMakePrimary)
                    }
                    if let onDelete {
                        Button("Remove", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Options for \(vehicle.displayName)")
            }
        }
    }
}

struct ContactRow: View {
    let contact: FamilyContact
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Text(initials)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Brand.teal.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name).font(.headline).foregroundStyle(Brand.textPrimary)
                Text([contact.relationship, PhoneFormat.display(contact.phone)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 0)
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.redInk)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(contact.name)")
            }
        }
    }

    private var initials: String {
        contact.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
