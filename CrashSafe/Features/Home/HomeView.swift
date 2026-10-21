import SwiftData
import SwiftUI

struct HomeView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel: HomeViewModel
    @State private var showingTripPicker = false

    @Query private var trips: [Trip]
    @Query private var checkIns: [CheckInRecord]
    @Query private var profiles: [Profile]

    init(user: AuthUser, viewModel: HomeViewModel) {
        self.user = user
        _viewModel = State(initialValue: viewModel)
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

    private var activeTrip: Trip? { trips.first(where: \.isActive) }
    private var upcomingTrips: [Trip] { trips.filter { !$0.isActive && $0.endDate >= .now } }
    private var currentTrip: Trip? { activeTrip ?? upcomingTrips.first }
    private var carType: CarType { profiles.first?.carType ?? .sedan }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusHeader
                    tripButton
                    currentTripCard
                    lastCheckInCard
                    debugSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Hi, \(firstName)")
            .confirmationDialog("Start a trip", isPresented: $showingTripPicker, titleVisibility: .visible) {
                ForEach(upcomingTrips.prefix(3)) { trip in
                    Button(trip.routeLabel) {
                        viewModel.start(trip, among: trips, carType: carType)
                    }
                }
                Button("Quick drive (no route)") {
                    viewModel.startQuickTrip(among: trips, carType: carType, in: context)
                }
                Button("Plan a new trip") { env.router.selectedTab = .trips }
            } message: {
                Text("Crash detection runs while a trip is active.")
            }
            .onAppear {
                viewModel.resumeMonitoringIfNeeded(activeTrip: activeTrip, carType: carType)
            }
        }
    }

    private var firstName: String {
        user.name.split(separator: " ").first.map(String.init) ?? "there"
    }

    // MARK: - Sections

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isMonitoring ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(viewModel.isMonitoring ? "Crash detection on" : "Crash detection off")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Label(env.connectivity.isOnline ? "Online" : "Offline",
                  systemImage: env.connectivity.isOnline ? "wifi" : "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tripButton: some View {
        if let activeTrip {
            Button {
                withAnimation { viewModel.end(activeTrip) }
            } label: {
                Label("End trip", systemImage: "stop.circle.fill")
                    .frame(minHeight: 72)
            }
            .buttonStyle(.primary(tint: Color(.systemGray)))
        } else {
            Button {
                showingTripPicker = true
            } label: {
                Label("Start a trip", systemImage: "car.fill")
                    .font(.title2.weight(.bold))
                    .frame(minHeight: 72)
            }
            .buttonStyle(.primary)
        }
    }

    private var currentTripCard: some View {
        Card {
            Text(activeTrip != nil ? "Current trip" : "Next trip")
                .font(.headline)
            if let trip = currentTrip {
                StatusRow(systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill",
                          title: trip.isActive ? "In progress" : "Planned",
                          value: trip.routeLabel,
                          tint: Theme.accent)
                StatusRow(systemImage: "calendar",
                          title: trip.isActive ? "Started" : "Dates",
                          value: trip.isActive
                            ? (trip.startedAt ?? .now).formatted(date: .omitted, time: .shortened)
                            : "\(trip.startDate.formatted(date: .abbreviated, time: .omitted)) – \(trip.endDate.formatted(date: .abbreviated, time: .omitted))")
                StatusRow(systemImage: trip.tripPackStatus == .ready ? "arrow.down.circle.fill" : "arrow.down.circle",
                          title: "Trip pack",
                          value: trip.tripPackStatus.label,
                          tint: trip.tripPackStatus == .ready ? .green : .secondary)
            } else {
                Text("No trips planned yet. Plan one so we can save tow companies and hospitals along your route for offline use.")
                    .foregroundStyle(.secondary)
                Button("Plan a trip") { env.router.selectedTab = .trips }
                    .font(.headline)
                    .frame(minHeight: 44)
            }
        }
    }

    private var lastCheckInCard: some View {
        Card {
            Text("Last check-in").font(.headline)
            if let last = checkIns.first {
                StatusRow(systemImage: last.outcome.systemImage,
                          title: last.date.formatted(.relative(presentation: .named)) + (last.wasSimulated ? " · simulated" : ""),
                          value: last.outcome.label,
                          tint: last.outcome == .ok ? .green : Theme.danger)
            } else {
                StatusRow(systemImage: "checkmark.seal", title: "Status", value: "No check-ins yet")
            }
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEBUG")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Button {
                viewModel.simulateCrash()
            } label: {
                Label("Simulate crash", systemImage: "car.side.rear.and.collision.and.car.side.front")
            }
            .buttonStyle(.secondary(tint: Theme.danger))
            Text("Shows the \"Are you OK?\" check-in exactly as a real detection would.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}

#Preview("Active trip") {
    let env = PreviewData.environment()
    HomeView(user: PreviewData.user, viewModel: HomeViewModel(detector: env.crashDetector, userID: PreviewData.user.id))
        .environment(env)
        .modelContainer(PreviewData.container())
}

#Preview("Empty") {
    let env = PreviewData.environment()
    HomeView(user: PreviewData.user, viewModel: HomeViewModel(detector: env.crashDetector, userID: PreviewData.user.id))
        .environment(env)
        .modelContainer(PreviewData.container(empty: true))
}
