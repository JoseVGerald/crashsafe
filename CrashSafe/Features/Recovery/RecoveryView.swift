import MapKit
import Observation
import SwiftData
import SwiftUI

@Observable
final class NearbyHelpViewModel {
    enum Source: Equatable { case live, tripPack, none }

    private(set) var places: [HelpPlace] = []
    private(set) var source: Source = .none
    private(set) var isLoading = false
    @ObservationIgnored private var loadedFor: CLLocation?

    func load(near location: CLLocation?, isOnline: Bool, fallback: TripPack?) async {
        guard let location else {
            useFallback(fallback)
            return
        }
        if let loadedFor, loadedFor.distance(from: location) < 300, !places.isEmpty { return }
        isLoading = places.isEmpty
        defer { isLoading = false }
        let live = isOnline ? await PlaceSearch.helpPlaces(near: location.coordinate, radiusMeters: 12_000, perCategory: 3) : []
        if live.isEmpty {
            useFallback(fallback, sortedFrom: location)
        } else {
            places = sorted(live, from: location)
            source = .live
            loadedFor = location
        }
    }

    private func useFallback(_ pack: TripPack?, sortedFrom location: CLLocation? = nil) {
        guard let pack else {
            places = []
            source = .none
            return
        }
        places = location.map { sorted(pack.allPlaces, from: $0) } ?? pack.allPlaces
        source = .tripPack
    }

    private func sorted(_ places: [HelpPlace], from location: CLLocation) -> [HelpPlace] {
        places.sorted { $0.distanceMiles(from: location) < $1.distanceMiles(from: location) }
    }
}

struct RecoveryBanner: Equatable {
    let text: String
    let systemImage: String
    let tint: Color
}

/// Everything a driver needs after a crash, in one place: help nearby, 911, Pulse, family, medical and insurance info.
/// Shown after the check-in, and from Home → Nearby help.
struct RecoveryView: View {
    let user: AuthUser
    let outcome: CheckInOutcome?
    var banner: RecoveryBanner?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var help = NearbyHelpViewModel()
    @State private var filter: HelpPlace.Category?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var checked: Set<String> = []
    @State private var placeToCall: HelpPlace?

    @Query private var profiles: [Profile]
    @Query private var activeTrips: [Trip]

    init(user: AuthUser, outcome: CheckInOutcome?, banner: RecoveryBanner? = nil) {
        self.user = user
        self.outcome = outcome
        self.banner = banner
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
        _activeTrips = Query(filter: #Predicate<Trip> { $0.ownerID == id && $0.isActive })
    }

    private var profile: Profile? { profiles.first }
    private var here: CLLocation? { env.location.location }
    private var visiblePlaces: [HelpPlace] {
        help.places.filter { filter == nil || $0.category == filter }
    }

    private let scenePhotos = [
        "Every vehicle, from all four corners",
        "License plates",
        "The road, signs and traffic lights",
        "Weather and lighting (rain, darkness)",
        "Other driver's license and insurance card",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md + 4) {
                    if let banner {
                        Label {
                            Text(banner.text).foregroundStyle(Brand.textPrimary)
                        } icon: {
                            Image(systemName: banner.systemImage).foregroundStyle(banner.tint)
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(banner.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .animation(.easeOut, value: banner)
                    }

                    emergencyActions.fadeUp(delay: 0.03)
                    mapCard.fadeUp(delay: 0.06)
                    nearbyHelp.fadeUp(delay: 0.1)
                    shareLocation.fadeUp(delay: 0.14)
                    if let profile { medicalCard(profile).fadeUp(delay: 0.18) }
                    if let profile { familyCard(profile).fadeUp(delay: 0.2) }
                    documentScene.fadeUp(delay: 0.22)
                    if let profile, !profile.insurer.isEmpty { insuranceCard(profile).fadeUp(delay: 0.24) }
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(BrandBackground())
            .navigationTitle("Get help")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { close() }
                        .labelStyle(.iconOnly)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .task(id: here.map { Int($0.coordinate.latitude * 1_000) }) {
            await help.load(near: here, isOnline: env.connectivity.isOnline, fallback: activeTrips.first?.tripPack)
        }
        .onAppear { env.location.requestPermission() }
        .confirmationDialog(placeToCall?.name ?? "", isPresented: Binding(
            get: { placeToCall != nil }, set: { if !$0 { placeToCall = nil } }
        ), titleVisibility: .visible) {
            if let place = placeToCall {
                if !place.phone.isEmpty {
                    Button("Call \(place.phone)") { call(place.phone) }
                }
                Button("Directions in Maps") { openInMaps(place) }
            }
        }
    }

    // MARK: Sections

    private var emergencyActions: some View {
        HStack(spacing: 12) {
            Button {
                call("911")
            } label: {
                Label("Call 911", systemImage: "phone.fill")
            }
            .buttonStyle(.pill(.danger, height: 60))

            Button {
                if let outcome {
                    env.router.openAssistant(after: outcome)
                } else {
                    env.router.selectedTab = .assistant
                    dismiss()
                }
            } label: {
                Label("Talk to Pulse", systemImage: "waveform")
            }
            .buttonStyle(.pill(.primary, height: 60))
        }
    }

    private var mapCard: some View {
        ZStack(alignment: .bottomLeading) {
            Map(position: $position) {
                UserAnnotation()
                if let here, outcome != nil {
                    Annotation("Crash location", coordinate: here.coordinate, anchor: .bottom) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white, Brand.red)
                            .shadow(radius: 4)
                    }
                }
                ForEach(visiblePlaces) { place in
                    Marker(place.name, systemImage: place.category.systemImage, coordinate: place.coordinate)
                        .tint(tint(for: place.category))
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .mapControls { MapUserLocationButton() }

            if here != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome != nil ? "Crash location" : "You're here")
                        .font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                    Text(env.location.streetName ?? env.location.placeName ?? "Finding address…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(12)
            }
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
    }

    private var nearbyHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby help").font(.title3.weight(.semibold)).foregroundStyle(Brand.textPrimary)
                Spacer()
                if help.source == .tripPack {
                    StatusChip(text: "Offline · trip pack", systemImage: "icloud.slash", tint: Brand.amberInk)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(nil, "All")
                    ForEach(HelpPlace.Category.allCases, id: \.self) { filterChip($0, $0.title) }
                }
            }

            VStack(spacing: 0) {
                if help.isLoading {
                    ForEach(0..<3, id: \.self) { _ in
                        placeholderRow
                    }
                } else if visiblePlaces.isEmpty {
                    Text(here == nil ? "Turn on location to find help nearby." : "Nothing found nearby. Call 911 for emergencies.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(visiblePlaces.prefix(8).enumerated()), id: \.element.id) { index, place in
                        if index > 0 { Divider().overlay(Brand.stroke).padding(.leading, 70) }
                        placeRow(place)
                    }
                }
            }
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
            .animation(.easeOut(duration: 0.25), value: filter)
        }
    }

    private func placeRow(_ place: HelpPlace) -> some View {
        Button {
            placeToCall = place
        } label: {
            HStack(spacing: 14) {
                IconBadge(systemName: place.category.systemImage, tint: tint(for: place.category), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.headline)
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                    Text(distanceText(place))
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                }
                Spacer()
                Image(systemName: place.phone.isEmpty ? "arrow.triangle.turn.up.right.circle.fill" : "phone.circle.fill")
                    .font(.title)
                    .foregroundStyle(Brand.greenInk)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityHint(place.phone.isEmpty ? "Opens directions" : "Call or get directions")
    }

    private var placeholderRow: some View {
        HStack(spacing: 14) {
            Circle().fill(Brand.fieldFill).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Brand.fieldFill).frame(width: 160, height: 12)
                Capsule().fill(Brand.fieldFill).frame(width: 90, height: 10)
            }
            Spacer()
        }
        .padding(Space.md)
        .phaseAnimator([0.5, 1]) { content, phase in content.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
    }

    private func filterChip(_ category: HelpPlace.Category?, _ title: String) -> some View {
        let selected = filter == category
        return Button {
            filter = category
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .foregroundStyle(selected ? .white : Brand.textPrimary)
                .background(selected ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(Brand.fieldFill), in: Capsule())
        }
        .buttonStyle(.pressable)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var shareLocation: some View {
        if let here {
            let url = URL(string: "https://maps.apple.com/?ll=\(here.coordinate.latitude),\(here.coordinate.longitude)&q=My%20location")!
            ShareLink(item: url, message: Text("I've been in a car crash. I'm here:")) {
                Label("Share my location", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.secondary)
        }
    }

    private func medicalCard(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("For responders", systemImage: "staroflife.fill")
                    .font(.headline)
                    .foregroundStyle(Brand.redInk)
                Spacer()
                if !profile.bloodType.isEmpty {
                    Text(profile.bloodType)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .foregroundStyle(.white)
                        .background(Brand.red, in: Capsule())
                        .accessibilityLabel("Blood type \(profile.bloodType)")
                }
            }
            Text(user.name).font(.title3.weight(.semibold)).foregroundStyle(Brand.textPrimary)
            Text(profile.medicalNotes.isEmpty ? "No medical notes added." : profile.medicalNotes)
                .font(.body)
                .foregroundStyle(Brand.textPrimary)
            if let vehicle = profile.primaryVehicle {
                Label("\(vehicle.displayName)\(vehicle.plate.isEmpty ? "" : " · \(vehicle.plate)")", systemImage: vehicle.type.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
        .card(padding: Space.md + 4)
    }

    @ViewBuilder
    private func familyCard(_ profile: Profile) -> some View {
        if !profile.familyContacts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Family").font(.headline).foregroundStyle(Brand.textPrimary)
                ForEach(profile.sortedContacts) { contact in
                    HStack {
                        ContactRow(contact: contact)
                        Button {
                            call(contact.phone)
                        } label: {
                            Image(systemName: "phone.circle.fill").font(.title).foregroundStyle(Brand.greenInk)
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Call \(contact.name)")
                    }
                }
            }
            .card(padding: Space.md + 4)
        }
    }

    private var documentScene: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Document the scene").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text("\(checked.count)/\(scenePhotos.count)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .contentTransition(.numericText())
            }
            Text("Only once you're safely off the road. Photograph:")
                .font(.subheadline)
                .foregroundStyle(Brand.textSecondary)
            ForEach(scenePhotos, id: \.self) { item in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        if checked.contains(item) { checked.remove(item) } else { checked.insert(item) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: checked.contains(item) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(checked.contains(item) ? Brand.greenInk : Brand.textSecondary)
                        Text(item)
                            .foregroundStyle(Brand.textPrimary)
                            .strikethrough(checked.contains(item), color: Brand.textSecondary)
                        Spacer()
                    }
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: checked.contains(item))
            }
        }
        .card(padding: Space.md + 4)
    }

    private func insuranceCard(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insurance").font(.headline).foregroundStyle(Brand.textPrimary)
            StatusRow(systemImage: "building.columns.fill", title: profile.insurer,
                      value: profile.policyNumber.isEmpty ? "No policy number saved" : "Policy \(profile.policyNumber)",
                      tint: Brand.blueInk)
            Text("Report it promptly and stick to facts: time, place, weather, what you saw. Don't guess or admit fault at the scene. Not legal advice.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
            if !profile.insurerPhone.isEmpty {
                Button("Call \(profile.insurer)", systemImage: "phone.fill") { call(profile.insurerPhone) }
                    .buttonStyle(.pill(.secondary, height: 48))
            }
        }
        .card(padding: Space.md + 4)
    }

    // MARK: Helpers

    private func tint(for category: HelpPlace.Category) -> Color {
        switch category {
        case .hospital: Brand.red
        case .police: Brand.blue
        case .towing: Brand.amber
        }
    }

    private func distanceText(_ place: HelpPlace) -> String {
        guard let here else { return place.category.title }
        let miles = place.distanceMiles(from: here)
        let minutes = max(1, Int((miles / 30 * 60).rounded()) + 1)
        return String(format: "%.1f mi · ~%d min", miles, minutes)
    }

    private func call(_ number: String) {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        if let url = URL(string: "tel://\(digits)") { openURL(url) }
    }

    private func openInMaps(_ place: HelpPlace) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func close() {
        if outcome != nil {
            env.router.activeCrash = nil
        } else {
            dismiss()
        }
    }
}
