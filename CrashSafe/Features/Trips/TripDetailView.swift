import MapKit
import SwiftData
import SwiftUI

struct TripDetailView: View {
    @Bindable var trip: Trip
    @State private var viewModel: TripPackViewModel
    @Environment(\.openURL) private var openURL

    init(trip: Trip, viewModel: TripPackViewModel) {
        self.trip = trip
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md + 4) {
                if let from = trip.originCoordinate, let to = trip.destinationCoordinate {
                    Map(initialPosition: .automatic, interactionModes: []) {
                        Marker(trip.origin, systemImage: "circle.fill", coordinate: from).tint(Brand.green)
                        Marker(trip.destination, systemImage: "flag.checkered", coordinate: to).tint(Brand.red)
                        ForEach(trip.tripPack?.allPlaces ?? []) { place in
                            Marker(place.name, systemImage: place.category.systemImage, coordinate: place.coordinate)
                                .tint(tint(for: place.category))
                        }
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .fadeUp()
                }

                VStack(alignment: .leading, spacing: 12) {
                    StatusRow(systemImage: "circle.circle.fill", title: "From", value: trip.origin, tint: Brand.greenInk)
                    StatusRow(systemImage: "mappin.circle.fill", title: "To", value: trip.destination, tint: Brand.redInk)
                    StatusRow(systemImage: "calendar", title: "Dates",
                              value: "\(trip.startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())) – \(trip.endDate.formatted(.dateTime.month(.abbreviated).day()))")
                    if let summary = trip.routeSummary {
                        StatusRow(systemImage: "car.fill", title: "Drive", value: summary)
                    }
                }
                .card(padding: Space.md + 4)
                .fadeUp(delay: 0.05)

                packCard.fadeUp(delay: 0.1)
            }
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.lg)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(BrandBackground())
        .navigationTitle(trip.destination)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.4), value: trip.tripPackStatus)
    }

    private var packCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Offline trip pack").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                if trip.tripPackStatus == .downloading {
                    ProgressView()
                } else {
                    StatusChip(text: trip.tripPackStatus.label,
                               tint: trip.tripPackStatus == .ready ? Brand.greenInk : Brand.textSecondary)
                }
            }
            Text("Tow companies, hospitals and police along your route, saved so help works with no signal.")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)

            if let pack = trip.tripPack {
                ForEach(pack.allPlaces.prefix(9)) { place in
                    HStack(spacing: 12) {
                        IconBadge(systemName: place.category.systemImage, tint: tint(for: place.category), size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                            Text(place.phone.isEmpty ? place.category.title : place.phone)
                                .font(.caption).foregroundStyle(Brand.textSecondary)
                        }
                        Spacer()
                        if !place.phone.isEmpty {
                            Button {
                                if let url = URL(string: "tel://\(place.phone.filter(\.isNumber))") { openURL(url) }
                            } label: {
                                Image(systemName: "phone.circle.fill").font(.title2).foregroundStyle(Brand.greenInk)
                            }
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Call \(place.name)")
                        }
                    }
                }
                if let updated = trip.tripPackUpdatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(Brand.textSecondary)
                }
            }

            Button {
                Task { await viewModel.download(for: trip) }
            } label: {
                Text(trip.tripPackStatus == .ready ? "Refresh trip pack" : "Download trip pack")
            }
            .buttonStyle(trip.tripPackStatus == .ready ? .secondary : .primary)
            .disabled(trip.tripPackStatus == .downloading)
        }
        .card(padding: Space.md + 4)
    }

    private func tint(for category: HelpPlace.Category) -> Color {
        switch category {
        case .hospital: Brand.red
        case .police: Brand.blue
        case .towing: Brand.amber
        }
    }
}
