import SwiftData
import SwiftUI

struct TripPlannerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var viewModel: TripPlannerViewModel
    @FocusState private var focus: Field?
    @Query private var trips: [Trip]

    private enum Field { case origin, destination }

    init(userID: String) {
        _viewModel = State(initialValue: TripPlannerViewModel(userID: userID))
        _trips = Query(filter: #Predicate<Trip> { $0.ownerID == userID }, sort: \Trip.startDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                planSection
                tripPackPlaceholder
                savedTripsSection
            }
            .navigationTitle("Trip planner")
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip, viewModel: TripPackViewModel(service: env.tripPacks))
            }
        }
    }

    private var planSection: some View {
        Section {
            LabeledContent {
                TextField("City or address", text: $viewModel.origin)
                    .focused($focus, equals: .origin)
                    .textContentType(.addressCity)
                    .submitLabel(.next)
                    .onSubmit { focus = .destination }
            } label: {
                Label("From", systemImage: "circle.circle")
            }
            if let error = viewModel.originError { fieldError(error) }

            LabeledContent {
                TextField("City or address", text: $viewModel.destination)
                    .focused($focus, equals: .destination)
                    .textContentType(.addressCity)
                    .submitLabel(.done)
            } label: {
                Label("To", systemImage: "mappin.circle.fill")
            }
            if let error = viewModel.destinationError { fieldError(error) }

            DatePicker(selection: $viewModel.startDate, displayedComponents: [.date, .hourAndMinute]) {
                Label("Leave", systemImage: "calendar")
            }
            DatePicker(selection: $viewModel.endDate, in: viewModel.startDate..., displayedComponents: .date) {
                Label("Return", systemImage: "calendar.badge.clock")
            }
            if let error = viewModel.datesError { fieldError(error) }

            Button {
                focus = nil
                withAnimation { _ = viewModel.save(in: context) }
            } label: {
                Text("Save trip")
            }
            .buttonStyle(.primary)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        } header: {
            Text("Plan a trip")
        } footer: {
            if let saved = viewModel.lastSaved {
                Label("Saved \(saved). Download its trip pack below.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.footnote.weight(.medium))
            }
        }
        .onChange(of: viewModel.origin) { _, new in
            // Hide the "Saved" notice once the user starts planning another trip.
            if !new.isEmpty { viewModel.dismissSavedNotice() }
        }
    }

    private var tripPackPlaceholder: some View {
        Section {
            LabeledContent {
                Text("Not downloaded").foregroundStyle(.secondary)
            } label: {
                Label("Trip pack", systemImage: "arrow.down.circle")
            }
        } footer: {
            Text("A trip pack saves tow companies, hospitals and step-by-step guides along your route so the assistant still works with no signal.")
        }
    }

    @ViewBuilder
    private var savedTripsSection: some View {
        Section("Saved trips") {
            if trips.isEmpty {
                Text("No saved trips yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(trips) { trip in
                NavigationLink(value: trip) {
                    TripRow(trip: trip)
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(trips[index]) }
            }
        }
    }

    private func fieldError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.danger)
    }
}

struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.routeLabel).font(.headline)
                if trip.isActive {
                    Text("ACTIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            Text("\(trip.startDate.formatted(date: .abbreviated, time: .omitted)) – \(trip.endDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Trip pack: \(trip.tripPackStatus.label.lowercased())",
                  systemImage: trip.tripPackStatus == .ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(trip.tripPackStatus == .ready ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    TripPlannerView(userID: PreviewData.user.id)
        .environment(PreviewData.environment())
        .modelContainer(PreviewData.container())
}
