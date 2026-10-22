import MapKit
import SwiftData
import SwiftUI

struct TripPlannerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel: TripPlannerViewModel
    @State private var picking: LocationPickerSheet.Field?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var packs: TripPackViewModel?
    @State private var pickingVehicle = false
    @Query private var trips: [Trip]
    @Query private var profiles: [Profile]

    init(userID: String) {
        _viewModel = State(initialValue: TripPlannerViewModel(userID: userID))
        _trips = Query(filter: #Predicate<Trip> { $0.ownerID == userID }, sort: \Trip.startDate)
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == userID })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md + 4) {
                    Text("Plan a drive")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Brand.textPrimary)
                        .padding(.top, Space.sm)
                        .fadeUp()

                    VStack(spacing: Space.sm) {
                        mapCard
                        BrandPhotoView(photo: .roadBanner)
                            .frame(height: 84)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
                    }
                    .fadeUp(delay: 0.05)
                    routeCard.fadeUp(delay: 0.1)
                    datesCard.fadeUp(delay: 0.13)
                    crashDetectionRow.fadeUp(delay: 0.16)

                    VStack(spacing: 10) {
                        Button {
                            save()
                        } label: {
                            Label("Save trip", systemImage: "checkmark")
                        }
                        .buttonStyle(.primary)
                        if let saved = viewModel.lastSaved {
                            Label("Saved \(saved)", systemImage: "checkmark.circle.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Brand.greenInk)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .fadeUp(delay: 0.2)

                    savedTrips.fadeUp(delay: 0.25)
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.lg)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .animation(.spring(response: 0.4), value: viewModel.lastSaved)
            }
            .background(BrandBackground())
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip, viewModel: TripPackViewModel(service: env.tripPacks))
            }
            .sheet(isPresented: $pickingVehicle) {
                if let profile = profiles.first {
                    DriveVehiclePicker(profile: profile, mode: .chooseForTrip)
                }
            }
            .sheet(item: $picking) { field in
                LocationPickerSheet(field: field) { selection in
                    switch field {
                    case .origin: viewModel.origin = selection
                    case .destination: viewModel.destination = selection
                    }
                    viewModel.dismissSavedNotice()
                }
            }
            .onAppear {
                env.location.requestPermission()
                packs = packs ?? TripPackViewModel(service: env.tripPacks)
                useCurrentLocationIfEmpty()
            }
            .onChange(of: env.location.location == nil) { useCurrentLocationIfEmpty() }
            .onChange(of: viewModel.route) { _, route in
                guard let route else { return }
                let rect = route.polyline.boundingMapRect
                withAnimation(.easeInOut(duration: 0.8)) {
                    position = .rect(rect.insetBy(dx: -rect.size.width * 0.15, dy: -rect.size.height * 0.25))
                }
            }
        }
    }

    // MARK: Sections

    private var mapCard: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            if let route = viewModel.route {
                MapPolyline(route.polyline)
                    .stroke(Brand.blueInk, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let origin = viewModel.origin, !origin.isCurrentLocation {
                Annotation(origin.title, coordinate: origin.coordinate) {
                    Circle().fill(Brand.blue).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                }
            }
            if let destination = viewModel.destination {
                Annotation(destination.title, coordinate: destination.coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Brand.navy, .white)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
        .overlay(alignment: .bottomTrailing) {
            if viewModel.isRouting || viewModel.routeSummary != nil {
                HStack(spacing: 8) {
                    if viewModel.isRouting {
                        ProgressView().controlSize(.small)
                        Text("Finding route…")
                    } else if let summary = viewModel.routeSummary {
                        Image(systemName: "car.fill")
                        Text(summary)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Brand.navy.opacity(0.88), in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.stroke))
                .padding(12)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: viewModel.routeSummary)
    }

    private var routeCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                placeRow(field: .origin, label: "From", value: viewModel.origin,
                         placeholder: "Choose a starting point", error: viewModel.originError) {
                    Circle()
                        .strokeBorder(Brand.blueInk, lineWidth: 3)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().fill(Brand.blueInk).frame(width: 10, height: 10))
                }
                HStack(spacing: 12) {
                    Line()
                        .stroke(Brand.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 5]))
                        .frame(width: 2, height: 22)
                        .frame(width: 32)
                    Rectangle().fill(Brand.stroke).frame(height: 1)
                }
                .accessibilityHidden(true)
                placeRow(field: .destination, label: "To", value: viewModel.destination,
                         placeholder: "Search destination", error: viewModel.destinationError) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Brand.navy)
                        .frame(width: 28, height: 28)
                        .background(Color(hex: 0xF4EEDF), in: Circle())
                }
            }
            Button {
                withAnimation(.spring(response: 0.35)) { viewModel.swap() }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .frame(width: 56, height: 56)
                    .background(Brand.fieldFill, in: Circle())
                    .overlay(Circle().strokeBorder(Brand.stroke))
            }
            .disabled(viewModel.origin == nil && viewModel.destination == nil)
            .accessibilityLabel("Swap start and destination")
        }
        .card(padding: Space.md)
    }

    private func placeRow<Glyph: View>(field: LocationPickerSheet.Field, label: String, value: PlaceSelection?,
                                       placeholder: String, error: String?, @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 12) {
            Button {
                picking = field
            } label: {
                HStack(spacing: 12) {
                    glyph()
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.subheadline).foregroundStyle(Brand.textSecondary)
                        if let value {
                            Text(value.isCurrentLocation ? "Current location" : value.title)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(field == .origin ? Brand.blueInk : Brand.textPrimary)
                                .lineLimit(1)
                            if !value.subtitle.isEmpty {
                                Text(value.subtitle).font(.subheadline).foregroundStyle(Brand.textSecondary).lineLimit(1)
                            }
                        } else {
                            Text(error ?? placeholder)
                                .font(.title3)
                                .foregroundStyle(error == nil ? Brand.textSecondary : Brand.redInk)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            if field == .origin && value?.isCurrentLocation != true {
                Button(action: useCurrentLocation) {
                    Image(systemName: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.blueInk)
                        .frame(width: 44, height: 44)
                        .background(Brand.blueInk.opacity(0.1), in: Circle())
                }
                .accessibilityLabel("Use current location")
            }
        }
    }

    private var crashDetectionRow: some View {
        Button {
            pickingVehicle = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(Brand.amberInk)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Crash detection ready")
                        .font(.headline)
                        .foregroundStyle(Brand.textPrimary)
                    Text(profiles.first?.primaryVehicle.map { "Driving the \($0.displayName) · Tap to change" }
                         ?? "Pick the car you're driving.")
                        .font(.footnote)
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.textSecondary)
            }
            .card(padding: Space.md)
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Pick which car you're driving")
    }

    private var datesCard: some View {
        VStack(spacing: 4) {
            DateField(title: "Leave", systemImage: "calendar", date: $viewModel.startDate, minimum: nil)
            Divider().overlay(Brand.stroke)
            DateField(title: "Return", systemImage: "calendar.badge.clock", date: $viewModel.endDate,
                      minimum: viewModel.startDate)
        }
        .card(padding: Space.md)
    }

    @ViewBuilder
    private var savedTrips: some View {
        if !trips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Saved trips")
                ForEach(trips) { trip in
                    NavigationLink(value: trip) {
                        TripCard(trip: trip)
                    }
                    .buttonStyle(.pressable)
                    .contextMenu {
                        Button("Delete trip", systemImage: "trash", role: .destructive) {
                            withAnimation { context.delete(trip) }
                        }
                    }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4), value: trips.count)
        }
    }

    private func useCurrentLocation() {
        guard let here = env.location.location else {
            env.location.requestPermission()
            return
        }
        viewModel.origin = PlaceSelection(title: "Current location", subtitle: env.location.placeName ?? "",
                                          coordinate: here.coordinate, isCurrentLocation: true)
    }

    private func useCurrentLocationIfEmpty() {
        if viewModel.origin == nil, env.location.location != nil { useCurrentLocation() }
    }

    private func save() {
        guard let trip = viewModel.save(in: context) else { return }
        Task { await packs?.download(for: trip) }
    }
}

/// Vertical line used for the dotted From → To connector.
private nonisolated struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
    }
}

/// What "Crash detection ready" means, in plain words.
struct CrashDetectionInfoView: View {
    private let points: [(String, String)] = [
        ("play.circle.fill", "Turns on when your drive starts and off when it ends."),
        ("waveform.path.ecg", "Watches motion and GPS together for a sudden, severe impact."),
        ("car.fill", "Tuned to the car you pick: an SUV, a sedan and a motorcycle crash differently."),
        ("questionmark.bubble.fill", "Asks if you're okay. If you don't answer, your family contacts get your location."),
        ("location.fill", "With “Always” location, Pulse can notice drives that start while the app is closed."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(points, id: \.1) { icon, text in
                    Label {
                        Text(text).foregroundStyle(Brand.textPrimary).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: icon).foregroundStyle(Brand.blueInk).frame(width: 28)
                    }
                }
                SafetyNotice()
            }
            .padding(Space.lg)
        }
        .background(BrandBackground())
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension LocationPickerSheet.Field: Identifiable {
    var id: Self { self }
}

struct TripCard: View {
    let trip: Trip

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: trip.isActive ? "car.fill" : "map.fill", tint: trip.isActive ? Brand.green : Brand.blue, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(trip.destination)
                        .font(.headline)
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    if trip.isActive { StatusChip(text: "Active", tint: Brand.greenInk) }
                }
                Text("From \(trip.origin) · \(trip.startDate.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                packStatus
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
        }
        .card(padding: Space.md)
    }

    @ViewBuilder
    private var packStatus: some View {
        switch trip.tripPackStatus {
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Saving offline help…")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Brand.textSecondary)
        case .ready:
            Label(trip.routeSummary.map { "Offline ready · \($0)" } ?? "Offline ready", systemImage: "checkmark.icloud.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Brand.greenInk)
        case .notDownloaded, .failed:
            Label(trip.tripPackStatus.label, systemImage: "icloud.slash")
                .font(.caption.weight(.medium))
                .foregroundStyle(Brand.textSecondary)
        }
    }
}

#Preview {
    TripPlannerView(userID: PreviewData.user.id)
        .environment(PreviewData.environment())
        .modelContainer(PreviewData.container())
}

/// Row with a consistently formatted date ("Oct 22, 2026 · 9:13 AM") that opens Apple's calendar picker.
/// (The compact DatePicker switches to "10/22/26" for any day that isn't today.)
struct DateField: View {
    let title: String
    let systemImage: String
    @Binding var date: Date
    let minimum: Date?
    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            HStack {
                Label(title, systemImage: systemImage).foregroundStyle(Brand.textPrimary)
                Spacer(minLength: 8)
                Text(date.formatted(.dateTime.month(.abbreviated).day().year()) + " · " + date.formatted(date: .omitted, time: .shortened))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Brand.blueInk)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Brand.fieldFill, in: Capsule())
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(title), \(date.formatted(date: .complete, time: .shortened))")
        .accessibilityHint("Opens a calendar")
        .sheet(isPresented: $editing) {
            NavigationStack {
                Group {
                    if let minimum {
                        DatePicker(title, selection: $date, in: minimum..., displayedComponents: [.date, .hourAndMinute])
                    } else {
                        DatePicker(title, selection: $date, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { editing = false }.fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.height(560), .large])
            .presentationCornerRadius(28)
        }
    }
}
