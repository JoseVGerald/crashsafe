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
    @Query private var trips: [Trip]

    init(userID: String) {
        _viewModel = State(initialValue: TripPlannerViewModel(userID: userID))
        _trips = Query(filter: #Predicate<Trip> { $0.ownerID == userID }, sort: \Trip.startDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md + 4) {
                    Text("Plan a trip")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                        .padding(.top, Space.sm)
                        .fadeUp()

                    mapCard.fadeUp(delay: 0.05)
                    routeCard.fadeUp(delay: 0.1)
                    datesCard.fadeUp(delay: 0.15)

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
                    .stroke(Brand.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let origin = viewModel.origin, !origin.isCurrentLocation {
                Marker(origin.title, systemImage: "circle.fill", coordinate: origin.coordinate).tint(Brand.green)
            }
            if let destination = viewModel.destination {
                Marker(destination.title, systemImage: "flag.checkered", coordinate: destination.coordinate).tint(Brand.red)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
        .overlay(alignment: .bottomLeading) {
            if viewModel.isRouting || viewModel.routeSummary != nil {
                HStack(spacing: 6) {
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
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: viewModel.routeSummary)
    }

    private var routeCard: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                placeRow(field: .origin, icon: "circle.circle.fill", tint: Brand.greenInk, label: "From",
                         value: viewModel.origin, placeholder: "Choose a starting point", error: viewModel.originError)
                Divider().overlay(Brand.stroke).padding(.leading, 40)
                placeRow(field: .destination, icon: "mappin.circle.fill", tint: Brand.redInk, label: "To",
                         value: viewModel.destination, placeholder: "Search or drop a pin", error: viewModel.destinationError)
            }
            Button {
                withAnimation(.spring(response: 0.35)) { viewModel.swap() }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Brand.fieldFill, in: Circle())
            }
            .disabled(viewModel.origin == nil && viewModel.destination == nil)
            .accessibilityLabel("Swap start and destination")
        }
        .card(padding: Space.md)
    }

    private func placeRow(field: LocationPickerSheet.Field, icon: String, tint: Color, label: String,
                          value: PlaceSelection?, placeholder: String, error: String?) -> some View {
        HStack(spacing: 12) {
            Button {
                picking = field
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                        if let value {
                            Text(value.isCurrentLocation ? "Current location" : value.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Brand.textPrimary)
                                .lineLimit(1)
                            if !value.subtitle.isEmpty {
                                Text(value.subtitle).font(.caption).foregroundStyle(Brand.textSecondary).lineLimit(1)
                            }
                        } else {
                            Text(error ?? placeholder)
                                .font(.body)
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

    private var datesCard: some View {
        VStack(spacing: 4) {
            DatePicker(selection: $viewModel.startDate, displayedComponents: [.date, .hourAndMinute]) {
                Label("Leave", systemImage: "calendar").foregroundStyle(Brand.textPrimary)
            }
            .frame(minHeight: 44)
            Divider().overlay(Brand.stroke)
            DatePicker(selection: $viewModel.endDate, in: viewModel.startDate..., displayedComponents: .date) {
                Label("Return", systemImage: "calendar.badge.clock").foregroundStyle(Brand.textPrimary)
            }
            .frame(minHeight: 44)
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
