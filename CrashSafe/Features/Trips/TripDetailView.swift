import SwiftData
import SwiftUI

struct TripDetailView: View {
    @Bindable var trip: Trip
    @State private var viewModel: TripPackViewModel

    init(trip: Trip, viewModel: TripPackViewModel) {
        self.trip = trip
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            Section("Route") {
                LabeledContent("From", value: trip.origin)
                LabeledContent("To", value: trip.destination)
                LabeledContent("Leave", value: trip.startDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Return", value: trip.endDate.formatted(date: .abbreviated, time: .omitted))
            }

            Section {
                LabeledContent {
                    if trip.tripPackStatus == .downloading {
                        ProgressView()
                    } else {
                        Text(trip.tripPackStatus.label)
                            .foregroundStyle(trip.tripPackStatus == .ready ? .green : .secondary)
                    }
                } label: {
                    Label("Trip pack", systemImage: "arrow.down.circle")
                }
                if let summary = trip.tripPackSummary {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                if let updated = trip.tripPackUpdatedAt {
                    LabeledContent("Updated", value: updated.formatted(.relative(presentation: .named)))
                }
                Button {
                    Task { await viewModel.download(for: trip) }
                } label: {
                    Text(trip.tripPackStatus == .ready ? "Refresh trip pack" : "Download trip pack")
                }
                .buttonStyle(.primary)
                .disabled(trip.tripPackStatus == .downloading)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text("Offline data")
            } footer: {
                Text("Demo data — the real version searches Apple Maps for towing and hospitals along this route.")
            }
        }
        .navigationTitle(trip.destination)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    let container = PreviewData.container()
    let trip = try! container.mainContext.fetch(FetchDescriptor<Trip>()).first!
    NavigationStack {
        TripDetailView(trip: trip, viewModel: TripPackViewModel(service: MockTripPackService()))
    }
    .modelContainer(container)
}
