import MapKit
import Observation
import SwiftUI

/// A chosen place: from search, the current location, or a dropped pin.
struct PlaceSelection: Equatable {
    var title: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var isCurrentLocation = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(title: String, subtitle: String, coordinate: CLLocationCoordinate2D, isCurrentLocation: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.isCurrentLocation = isCurrentLocation
    }
}

/// Apple Maps autocomplete.
@Observable
final class LocationSearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { completer.queryFragment = query }
    }
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func bias(to location: CLLocation?) {
        guard let location else { return }
        completer.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(8))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> PlaceSelection? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return PlaceSelection(title: completion.title,
                              subtitle: completion.subtitle.isEmpty ? (item.placemark.locality ?? "") : completion.subtitle,
                              coordinate: item.placemark.coordinate)
    }
}

/// Sheet for picking the start or destination.
struct LocationPickerSheet: View {
    enum Field { case origin, destination }

    let field: Field
    var onPick: (PlaceSelection) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var search = LocationSearchModel()
    @State private var showingMap = false
    @State private var resolving = false
    @State private var searchPresented = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: useCurrentLocation) {
                        row(icon: "location.fill", tint: Brand.blue, title: "Use current location",
                            subtitle: env.location.placeName ?? (env.location.isAuthorized ? "Locating…" : "Location is off"))
                    }
                    .disabled(env.location.location == nil)
                    Button {
                        showingMap = true
                    } label: {
                        row(icon: "mappin.and.ellipse", tint: Brand.red, title: "Choose on map", subtitle: "Drop a pin anywhere")
                    }
                }

                if !search.results.isEmpty {
                    Section("Results") {
                        ForEach(search.results, id: \.self) { result in
                            Button {
                                Task { await pick(result) }
                            } label: {
                                row(icon: "magnifyingglass", tint: Color(hex: 0x6B7280), title: result.title, subtitle: result.subtitle)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(BrandBackground())
            .overlay {
                if resolving { ProgressView().controlSize(.large) }
            }
            .searchable(text: $search.query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: field == .origin ? "Search for a starting point" : "Search for a place or address")
            .navigationTitle(field == .origin ? "Starting point" : "Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingMap) {
                MapPinPickerView(start: env.location.location?.coordinate) { selection in
                    onPick(selection)
                    dismiss()
                }
            }
            .onAppear {
                search.bias(to: env.location.location)
                if field == .destination { searchPresented = true }
            }
        }
        .presentationCornerRadius(28)
    }

    private func row(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            IconBadge(systemName: icon, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Brand.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(Brand.textSecondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func useCurrentLocation() {
        guard let location = env.location.location else { return }
        onPick(PlaceSelection(title: "Current location", subtitle: env.location.placeName ?? "",
                              coordinate: location.coordinate, isCurrentLocation: true))
        dismiss()
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        defer { resolving = false }
        if let selection = await search.resolve(completion) {
            onPick(selection)
            dismiss()
        }
    }
}

/// Tap the map to drop a pin; confirm the reverse-geocoded address.
struct MapPinPickerView: View {
    let start: CLLocationCoordinate2D?
    var onPick: (PlaceSelection) -> Void

    @State private var pin: CLLocationCoordinate2D?
    @State private var label: (title: String, subtitle: String)?
    @State private var position: MapCameraPosition

    init(start: CLLocationCoordinate2D?, onPick: @escaping (PlaceSelection) -> Void) {
        self.start = start
        self.onPick = onPick
        let center = start ?? CLLocationCoordinate2D(latitude: 47.6101, longitude: -122.2015)
        _position = State(initialValue: .region(MKCoordinateRegion(center: center, latitudinalMeters: 30_000, longitudinalMeters: 30_000)))
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                if let pin {
                    Annotation(label?.title ?? "Pin", coordinate: pin, anchor: .bottom) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white, Brand.red)
                            .shadow(radius: 4)
                            .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { pin = coordinate }
                label = nil
                Task { label = await LocationService.describe(coordinate) }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if let pin {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label?.title ?? "Finding address…").font(.headline).foregroundStyle(Brand.textPrimary)
                        Text(label?.subtitle ?? " ").font(.subheadline).foregroundStyle(Brand.textSecondary)
                    }
                    Button("Use this location") {
                        onPick(PlaceSelection(title: label?.title ?? "Dropped pin", subtitle: label?.subtitle ?? "", coordinate: pin))
                    }
                    .buttonStyle(.primary)
                } else {
                    Label("Tap the map to drop a pin", systemImage: "hand.tap.fill")
                        .font(.headline)
                        .foregroundStyle(Brand.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(Space.md + 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, Space.md)
            .padding(.bottom, Space.sm)
            .animation(.spring(response: 0.35), value: pin != nil)
        }
        .navigationTitle("Drop a pin")
        .navigationBarTitleDisplayMode(.inline)
    }
}
