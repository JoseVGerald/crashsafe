import MapKit
import SwiftData
import SwiftUI

struct HomeView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel: HomeViewModel
    @State private var talk: PressToTalkViewModel
    @State private var showingTripPicker = false

    @Query private var trips: [Trip]
    @Query private var checkIns: [CheckInRecord]
    @Query private var profiles: [Profile]

    init(user: AuthUser, viewModel: HomeViewModel, talk: PressToTalkViewModel) {
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
                        Label(sensorNotice, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(Brand.amberInk)
                            .card(padding: Space.md)
                    }

                    locationCard.fadeUp(delay: 0.09)

                    RoadAlertCard(
                        advice: advice,
                        isNight: isNight,
                        isLoading: env.conditions.weather == nil && env.conditions.isLoading,
                        windMph: env.conditions.weather?.windMph,
                        demoTitle: env.driving.scenario.map { "Demo · \($0.title)" },
                        showsAttribution: env.conditions.weather != nil && env.driving.scenario == nil
                    )
                    .fadeUp(delay: 0.12)

                    PressToTalkCard(viewModel: talk) { env.router.selectedTab = .assistant }
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
            .confirmationDialog("Start a trip", isPresented: $showingTripPicker, titleVisibility: .visible) {
                ForEach(upcomingTrips.prefix(3)) { trip in
                    Button(trip.routeLabel) { viewModel.start(trip, among: trips, profile: profile) }
                }
                Button("Quick drive (no route)") {
                    viewModel.startQuickTrip(among: trips, profile: profile, in: context)
                }
                Button("Plan a new trip") { env.router.selectedTab = .trips }
            } message: {
                Text("Crash detection and coaching run while a trip is active.")
            }
            .onAppear {
                viewModel.resumeIfNeeded(activeTrip: activeTrip, profile: profile)
                env.location.requestPermission()
            }
            .task(id: env.location.location.map { Int($0.coordinate.latitude * 100) }) {
                guard env.driving.scenario == nil else { return }
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
        }
        .accessibilityElement(children: .combine)
    }

    private var isProtected: Bool { viewModel.isMonitoring || isDriving }

    /// Scenic hero with the crash-detection status underneath (mockup: "Crash detection active").
    private var heroCard: some View {
        Button {
            if activeTrip == nil { showingTripPicker = true } else { env.router.selectedTab = .trips }
        } label: {
            VStack(spacing: 0) {
                ScenicRoadArt()
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    Circle()
                        .fill(isProtected ? Brand.greenInk : Brand.textSecondary.opacity(0.6))
                        .frame(width: 14, height: 14)
                        .overlay {
                            if isProtected { PulseRings(color: Brand.greenInk, count: 2).frame(width: 14, height: 14) }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isProtected ? "Crash detection active" : "Crash detection ready")
                            .font(.headline)
                            .foregroundStyle(Brand.textPrimary)
                        Text(isProtected ? "Sensors enabled · Ready to assist" : "Turns on when you start a drive")
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
        .accessibilityHint(activeTrip == nil ? "Start a trip" : "Opens your trips")
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
                    showingTripPicker = true
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
            }
            .font(.footnote)
            .padding(.horizontal, Space.xs)
        }
    }

    private func openLocation() {
        if env.location.isAuthorized {
            MKMapItem.forCurrentLocation().openInMaps()
        } else if env.location.isDenied, let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        } else {
            env.location.requestPermission()
        }
    }
}
