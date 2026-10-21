import SwiftData
import SwiftUI

struct HomeView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel: HomeViewModel
    @State private var talk: PressToTalkViewModel
    @State private var showingTripPicker = false
    @State private var showingNearbyHelp = false

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
                    header.fadeUp()

                    PressToTalkCard(viewModel: talk) { env.router.selectedTab = .assistant }
                        .fadeUp(delay: 0.05)

                    ConditionsCard(
                        placeName: env.location.placeName,
                        weather: env.conditions.weather,
                        isNight: isNight,
                        advice: advice,
                        isLoading: env.conditions.isLoading || (env.location.isAuthorized && env.location.location == nil),
                        locationDenied: !env.location.isAuthorized,
                        demoTitle: env.driving.scenario.map { "Demo · \($0.title)" },
                        onEnableLocation: enableLocation
                    )
                    .fadeUp(delay: 0.1)

                    DrivingComparisonCard(
                        snapshot: env.driving.snapshot,
                        comparison: DrivingComparison.make(snapshot: env.driving.snapshot, advice: advice, isDriving: isDriving),
                        isDriving: isDriving,
                        scenario: env.driving.scenario,
                        onDemo: { viewModel.startDemo($0) },
                        onStopDemo: { Task { await viewModel.stopDemo(location: env.location) } }
                    )
                    .fadeUp(delay: 0.15)

                    tripCard.fadeUp(delay: 0.2)
                    quickActions.fadeUp(delay: 0.25)
                    lastCheckIn.fadeUp(delay: 0.3)
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
            .fullScreenCover(isPresented: $showingNearbyHelp) {
                RecoveryView(user: user, outcome: nil)
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

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.textSecondary)
                Text(user.firstName)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isMonitoring || isDriving ? Brand.greenInk : Brand.textSecondary.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text(viewModel.isMonitoring || isDriving ? "Protected" : "Not driving")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Brand.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.stroke))
            .accessibilityElement(children: .combine)
        }
        .padding(.top, Space.sm)
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

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickAction(title: "CarPlay", systemImage: "car.rear.fill", tint: Brand.indigo) {
                env.router.showingCarPlay = true
            }
            QuickAction(title: "Nearby help", systemImage: "cross.case.fill", tint: Brand.green) {
                showingNearbyHelp = true
            }
            QuickAction(title: "Test crash", systemImage: "car.side.rear.and.collision.and.car.side.front", tint: Brand.red) {
                viewModel.simulateCrash()
            }
        }
    }

    @ViewBuilder
    private var lastCheckIn: some View {
        if let last = checkIns.first {
            HStack(spacing: 12) {
                Image(systemName: last.outcome.systemImage)
                    .foregroundStyle(last.outcome == .ok ? Brand.greenInk : Brand.redInk)
                Text("Last check-in · \(last.outcome.shortLabel)")
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(last.date.formatted(.relative(presentation: .named)))
                    .foregroundStyle(Brand.textSecondary)
            }
            .font(.footnote)
            .padding(.horizontal, Space.xs)
        }
    }

    private func enableLocation() {
        if env.location.isDenied, let url = URL(string: "app-settings:") {
            UIApplication.shared.open(url)
        } else {
            env.location.requestPermission()
        }
    }
}

struct QuickAction: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                IconBadge(systemName: systemImage, tint: tint, size: 44)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
        }
        .buttonStyle(.pressable)
    }
}
