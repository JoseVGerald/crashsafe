import MapKit
import SwiftData
import SwiftUI

struct HomeView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel: HomeViewModel
    @State private var talk: PulseCallViewModel
    @State private var showingDrivePicker = false
    /// Set when a drive starts from the picker; CarPlay mode opens once the picker has closed.
    @State private var openCarPlayAfterPicker = false

    @Query private var trips: [Trip]
    @Query private var checkIns: [CheckInRecord]
    @State private var openReport: CheckInRecord?
    @Query private var profiles: [Profile]

    init(user: AuthUser, viewModel: HomeViewModel, talk: PulseCallViewModel) {
        self.user = user
        _viewModel = State(initialValue: viewModel)
        _talk = State(initialValue: talk)
        let id = user.id
        _trips = Query(filter: #Predicate<Trip> { $0.ownerID == id }, sort: \Trip.startDate)
        var latest = FetchDescriptor<CheckInRecord>(
            predicate: #Predicate { $0.ownerID == id },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        latest.fetchLimit = 1
        _checkIns = Query(latest)
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

    private var profile: Profile? { profiles.first }
    private var activeTrip: Trip? { trips.first(where: \.isActive) }
    private var upcomingTrips: [Trip] { trips.filter { !$0.isActive && $0.endDate >= .now } }
    private var currentTrip: Trip? { activeTrip ?? upcomingTrips.first }
    private var isNight: Bool { env.driving.scenario?.isNight ?? env.conditions.isNight }
    private var advice: DrivingAdvice { DrivingAdvice.make(weather: env.conditions.weather, isNight: isNight) }
    private var isDriving: Bool { env.driving.isActive }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md + 4) {
                    topBar.fadeUp()
                    header.fadeUp(delay: 0.03)
                    heroCard.fadeUp(delay: 0.06)

                    if let sensorNotice {
                        Button {
                            if env.sensors.health.state == .permissionDenied || env.location.isDenied {
                                PermissionCenter.openSettings()
                            }
                        } label: {
                            Label(sensorNotice, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(Brand.amberInk)
                                .multilineTextAlignment(.leading)
                                .card(padding: Space.md)
                        }
                        .buttonStyle(.pressable)
                    }

                    locationCard.fadeUp(delay: 0.09)

                    RoadAlertCard(
                        advice: advice,
                        isNight: isNight,
                        isLoading: env.conditions.weather == nil && env.conditions.isLoading,
                        windMph: env.conditions.weather?.windMph,
                        demoTitle: env.driving.scenario.map { "Demo · \($0.title)" },
                        showsAttribution: env.conditions.weather != nil && env.driving.scenario == nil,
                        source: env.conditions.source,
                        appleLegalURL: env.conditions.appleLegalURL,
                        appleMarkURL: env.conditions.appleMarkURL
                    )
                    .fadeUp(delay: 0.12)

                    PulseCallCard(
                        viewModel: talk,
                        onCall: {
                            env.router.selectedTab = .pulseVoice
                            if !talk.inCall { talk.startCall() }
                        },
                        onOpenChat: { env.router.selectedTab = .assistant }
                    )
                    .fadeUp(delay: 0.15)

                    tripCard.fadeUp(delay: 0.18)
                    lastCheckIn.fadeUp(delay: 0.21)
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.lg)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(BrandBackground())
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await env.conditions.refresh(for: env.location.location, force: true) }
            .sheet(isPresented: $showingDrivePicker, onDismiss: {
                guard openCarPlayAfterPicker else { return }
                openCarPlayAfterPicker = false
                env.router.showingCarPlay = true
            }) {
                if let profile {
                    DriveVehiclePicker(
                        profile: profile,
                        mode: activeTrip == nil ? .startDrive : .changeCar,
                        upcomingTrips: upcomingTrips,
                        onConfirm: { trip in
                            if activeTrip != nil {
                                viewModel.changeVehicle(profile: profile)
                            } else if let trip {
                                viewModel.start(trip, among: trips, profile: profile)
                            } else {
                                viewModel.startQuickTrip(among: trips, profile: profile, in: context)
                            }
                            // Straight into the driving dashboard, on live data.
                            openCarPlayAfterPicker = true
                        },
                        onPlanTrip: { env.router.selectedTab = .trips }
                    )
                }
            }
            .onAppear {
                viewModel.resumeIfNeeded(activeTrip: activeTrip, profile: profile)
                env.location.requestPermission()
            }
            .task(id: env.location.location.map { Int($0.coordinate.latitude * 100) }) {
                guard env.driving.scenario == nil else { return }
                // Have the roads around here on the phone before "Drive this car" needs their limits.
                if let here = env.location.location?.coordinate {
                    env.driving.speedLimits?.prefetch(lat: here.latitude, lon: here.longitude)
                }
                await env.conditions.refresh(for: env.location.location)
            }
        }
    }

    // MARK: Sections

    private var sensorNotice: String? {
        guard env.driving.mode == .live else { return nil }
        switch env.sensors.health.state {
        case .starting: return "Waiting for motion readings. Crash monitoring is not ready yet."
        case .permissionDenied: return "Motion access is off. Enable it in Settings to monitor for crashes."
        case .unavailable: return "Motion sensors are unavailable. Automatic crash monitoring is unavailable."
        case .interrupted, .stale, .stopped: return "Motion readings have stopped. Automatic crash monitoring is interrupted."
        case .active:
            return env.sensors.health.locationUnavailable ? "Reliable location or speed is unavailable. Crash monitoring has limited information." : nil
        }
    }

    private var topBar: some View {
        HStack {
            PulseWordmark()
            Spacer()
            Button {
                env.router.selectedTab = .profile
            } label: {
                Image(systemName: "person")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Brand.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Brand.stroke))
            }
            .accessibilityLabel("Profile")
        }
        .padding(.top, Space.sm)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(user.firstName.isEmpty ? "\(greeting)," : "\(greeting), \(user.firstName)")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Brand.textPrimary)
            Text("Stay safe. We're looking out for you.")
                .font(.body)
                .foregroundStyle(Brand.textSecondary)
            ActivityChip()
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var isProtected: Bool { viewModel.isMonitoring || isDriving }

    /// Scenic hero with the crash-detection status underneath (mockup: "Crash detection active").
    private var heroCard: some View {
        Button {
            showingDrivePicker = true
        } label: {
            VStack(spacing: 0) {
                BrandPhotoView(photo: .roadHero)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 14, height: 14)
                        .overlay {
                            if isProtected { PulseRings(color: statusTint, count: 2).frame(width: 14, height: 14) }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(heroTitle)
                            .font(.headline)
                            .foregroundStyle(Brand.textPrimary)
                        Text(heroDetail)
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
                .padding(Space.md)
            }
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
        }
        .buttonStyle(.pressable)
        .accessibilityHint(activeTrip == nil ? "Pick your car and start a drive" : "Change the car you're driving")
    }

    /// Honest status: a running drive whose sensors aren't delivering is "limited", not "active".
    private var heroTitle: String {
        guard isProtected else { return "Crash detection ready" }
        return sensorNotice == nil ? "Crash detection active" : "Crash detection limited"
    }

    private var statusTint: Color {
        guard isProtected else { return Brand.textSecondary.opacity(0.6) }
        return sensorNotice == nil ? Brand.greenInk : Brand.amberInk
    }

    private var heroDetail: String {
        let car = profile?.primaryVehicle?.displayName
        if isProtected {
            let sensors = sensorNotice == nil ? "Sensors enabled" : "Sensors limited — see below"
            return car.map { "\(sensors) · \($0)" } ?? sensors
        }
        return car.map { "Tap to drive the \($0)" } ?? "Tap to pick your car and start"
    }

    private var locationCard: some View {
        Button(action: openLocation) {
            VStack(spacing: 0) {
                Map(initialPosition: .userLocation(fallback: .automatic), interactionModes: []) {
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: 92)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                HStack(spacing: 14) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title2)
                        .foregroundStyle(Brand.amberInk)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your location")
                            .font(.headline)
                            .foregroundStyle(Brand.textPrimary)
                        Text(locationText)
                            .font(.footnote)
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                }
                .padding(Space.md)
            }
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
        }
        .buttonStyle(.pressable)
        .accessibilityHint(env.location.isAuthorized ? "Opens Maps" : "Turns on location")
    }

    private var locationText: String {
        if !env.location.isAuthorized { return "Location off · Tap to turn on" }
        return env.location.placeName ?? "Locating…"
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var tripCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(activeTrip != nil ? "Current trip" : "Next trip")
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                if let trip = currentTrip {
                    StatusChip(text: trip.tripPackStatus == .ready ? "Offline ready" : "No trip pack",
                               systemImage: trip.tripPackStatus == .ready ? "checkmark.icloud.fill" : "icloud.slash",
                               tint: trip.tripPackStatus == .ready ? Brand.greenInk : Brand.textSecondary)
                }
            }
            if let trip = currentTrip {
                HStack(spacing: 14) {
                    IconBadge(systemName: trip.isActive ? "car.fill" : "map.fill", tint: Brand.blue, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(trip.routeLabel)
                            .font(.headline)
                            .foregroundStyle(Brand.textPrimary)
                            .lineLimit(1)
                        Text(trip.isActive
                             ? "Started \((trip.startedAt ?? .now).formatted(date: .omitted, time: .shortened))"
                             : trip.routeSummary ?? trip.startDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            } else {
                Text("Plan a trip so we can save tow companies and hospitals along your route for offline use.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
            if let activeTrip {
                Button {
                    withAnimation { viewModel.end(activeTrip) }
                } label: {
                    Label("End trip", systemImage: "stop.fill")
                }
                .buttonStyle(.secondary)
            } else {
                Button {
                    showingDrivePicker = true
                } label: {
                    Label("Start a trip", systemImage: "car.fill")
                }
                .buttonStyle(.primary)
            }
        }
        .card(padding: Space.md + 4)
    }

    @ViewBuilder
    private var lastCheckIn: some View {
        if let last = checkIns.first {
            Button { if last.snapshot != nil { openReport = last } } label: { lastCheckInRow(last) }
                .buttonStyle(.plain)
                .disabled(last.snapshot == nil)
                .accessibilityHint(last.snapshot == nil ? "" : "Opens the impact report.")
                .sheet(item: $openReport) { record in
                    NavigationStack {
                        ImpactReportView(record: record, profile: profiles.first, driverName: user.name)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { openReport = nil } } }
                    }
                    .preferredColorScheme(.dark)
                }
        }
    }

    private func lastCheckInRow(_ last: CheckInRecord) -> some View {
        Group {
            AdaptiveStack(spacing: 12) {
                Label {
                    Text("Last check-in · \(last.outcome.shortLabel)")
                        .foregroundStyle(Brand.textPrimary)
                } icon: {
                    Image(systemName: last.outcome.systemImage)
                        .foregroundStyle(last.outcome == .ok ? Brand.greenInk : Brand.redInk)
                }
                Spacer(minLength: 0)
                Text(last.date.formatted(.relative(presentation: .named)))
                    .foregroundStyle(Brand.textSecondary)
                if last.snapshot != nil {
                    Label("Report", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Brand.blueInk)
                }
            }
            .font(.footnote)
            .padding(.horizontal, Space.xs)
        }
    }

    private func openLocation() {
        if env.location.isAuthorized {
            // Open Maps on the live GPS fix (falls back to Maps' own current-location item while one arrives).
            if let here = env.location.location {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
                item.name = env.location.placeName.map { "Your location · \($0)" } ?? "Your location"
                item.openInMaps(launchOptions: [
                    MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: here.coordinate),
                    MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)),
                ])
            } else {
                MKMapItem.forCurrentLocation().openInMaps()
            }
        } else if env.location.isDenied, let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        } else {
            env.location.requestPermission()
        }
    }
}

/// "Which car are you driving?" — opened from "Crash detection ready". The car you pick tunes crash
/// detection to its type and becomes your primary car, so the next drive starts with it selected.
struct DriveVehiclePicker: View {
    enum Mode {
        /// Home, no drive yet: pick a car (and optionally a planned trip), then start.
        case startDrive
        /// A drive is running: swap the car.
        case changeCar
        /// Trip planner: pick the car for the trip being planned.
        case chooseForTrip
    }

    @Bindable var profile: Profile
    let mode: Mode
    var upcomingTrips: [Trip] = []
    var onConfirm: (Trip?) -> Void = { _ in }
    var onPlanTrip: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Vehicle?
    @State private var trip: Trip?
    @State private var addingVehicle = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Which car are you driving?")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("Crash detection is tuned to the size and type of the car you pick.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.textSecondary)
                    }

                    VStack(spacing: 10) {
                        ForEach(profile.sortedVehicles) { vehicle in
                            vehicleOption(vehicle)
                        }
                        if profile.vehicles.isEmpty {
                            Text("No cars yet. Add the one you're driving so crash detection fits it.")
                                .font(.subheadline)
                                .foregroundStyle(Brand.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .card(padding: Space.md)
                        }
                        Button {
                            addingVehicle = true
                        } label: {
                            Label("Add a vehicle", systemImage: "plus.circle")
                        }
                        .buttonStyle(.pill(.secondary, height: 48))
                    }

                    if mode == .startDrive {
                        tripChoices
                    }

                    NavigationLink {
                        CrashDetectionInfoView()
                    } label: {
                        Label("How crash detection works", systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.blueInk)
                            .frame(minHeight: 44)
                    }
                }
                .padding(Space.lg)
            }
            .background(BrandBackground())
            .safeAreaInset(edge: .bottom) {
                Button(action: confirm) {
                    Label(confirmTitle, systemImage: mode == .startDrive ? "car.fill" : "checkmark")
                }
                .buttonStyle(.primary)
                .disabled(selected == nil && !profile.vehicles.isEmpty)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .background(Brand.background)
            }
            .navigationTitle("Crash detection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $addingVehicle) { VehicleEditorView(profile: profile) }
            .onAppear { selected = selected ?? profile.primaryVehicle ?? profile.sortedVehicles.first }
            .onChange(of: profile.vehicles.count) { _, _ in
                // Select a car the user just added.
                if let newest = profile.vehicles.max(by: { $0.createdAt < $1.createdAt }) { selected = newest }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(28)
    }

    private var confirmTitle: String {
        switch mode {
        case .startDrive: "Start drive"
        case .changeCar: "Drive this car"
        case .chooseForTrip: "Use this car"
        }
    }

    private func vehicleOption(_ vehicle: Vehicle) -> some View {
        let isSelected = selected === vehicle
        return Button {
            selected = vehicle
        } label: {
            HStack(spacing: 14) {
                VehicleThumbnail(width: 84, height: 58)
                VStack(alignment: .leading, spacing: 3) {
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Brand.blueInk : Brand.textSecondary.opacity(0.6))
            }
            .card(padding: Space.sm + 2)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Brand.blueInk, lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    private var tripChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to?")
                .font(.headline)
                .foregroundStyle(Brand.textPrimary)
            VStack(spacing: 0) {
                tripRow(title: "Quick drive", subtitle: "No planned route", isSelected: trip == nil) { trip = nil }
                ForEach(upcomingTrips.prefix(3)) { option in
                    Divider().overlay(Brand.stroke)
                    tripRow(title: option.destination, subtitle: "From \(option.origin)", isSelected: trip === option) {
                        trip = option
                    }
                }
                if let onPlanTrip {
                    Divider().overlay(Brand.stroke)
                    Button {
                        dismiss()
                        onPlanTrip()
                    } label: {
                        HStack {
                            Label("Plan a new trip", systemImage: "map")
                                .foregroundStyle(Brand.blueInk)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .card(padding: Space.md)
        }
    }

    private func tripRow(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Brand.blueInk : Brand.textSecondary.opacity(0.6))
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func confirm() {
        if let selected { profile.makePrimary(selected) }
        onConfirm(trip)
        dismiss()
    }
}

/// What the motion model thinks you're doing right now. Its own view: it updates every 2.5 s while on
/// screen, and only the chip should redraw, not all of Home.
private struct ActivityChip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let intelligence = env.intelligence
        if let current = intelligence.current, let mode = current.transportClass {
            StatusChip(text: "\(mode.title) · \(Int((current.probability * 100).rounded()))%",
                       systemImage: mode.systemImage, tint: Brand.blueInk)
                .contentTransition(.opacity)
                .animation(.easeOut, value: mode)
        } else if intelligence.current != nil {
            StatusChip(text: "Figuring out what you're doing…", systemImage: "waveform.path.ecg", tint: Brand.textSecondary)
        } else if env.sensors.health.state == .unavailable {
            StatusChip(text: "Motion sensors unavailable here", systemImage: "sensor.fill", tint: Brand.textSecondary)
        } else if intelligence.isSensingActivity {
            StatusChip(text: "Sensing your motion…", systemImage: "waveform.path.ecg", tint: Brand.textSecondary)
        }
    }
}
