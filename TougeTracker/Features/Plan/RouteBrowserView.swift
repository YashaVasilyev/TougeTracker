import SwiftUI
import MapKit
import CoreLocation

struct RouteBrowserView: View {
    @Environment(AppSettings.self) private var settings: AppSettings
    @Environment(RouteStore.self) private var store: RouteStore
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(TabRouter.self) private var router: TabRouter

    @State private var locationReader = LocationReader()

    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.35, longitude: -71.1),
        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
    ))
    @State private var visibleRoads: [TougeRoad] = []
    @State private var selectedRoad: TougeRoad?
    /// Set when the user taps "Details" on the preview card to open the full sheet.
    @State private var detailedRoad: TougeRoad?
    @State private var isLoading = false
    @State private var searchText = ""

    @State private var tileLoadTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    roadOverlays
                    savedRouteAnnotations
                    userMarker
                }
                .mapStyle(.standard)
                // Fires continuously while panning/zooming, unlike onChange of the
                // camera binding — this is what makes roads rescore as you scroll.
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleRegion = context.region
                    loadVisibleRoads()
                }
                // MapPolyline is not selectable, so `Map(selection:)` never fires
                // for roads. Hit-test the tap ourselves against visible geometry.
                .onTapGesture { screenPoint in
                    guard let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                    selectedRoad = nearestRoad(to: coordinate, in: visibleRoads)
                }
                .overlay(alignment: .top) {
                    topOverlay
                }
                .overlay(alignment: .bottom) {
                    if let road = selectedRoad {
                        RoadPreviewCard(
                            road: road,
                            settings: settings,
                            isSaved: store.isSaved(id: road.id),
                            onSave: { _ = store.saveRoute(road) },
                            onStart: { startDrive(road) },
                            onDetails: { detailedRoad = road },
                            onDismiss: { selectedRoad = nil }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: selectedRoad?.id)
                .navigationTitle("Plan")
                .searchable(text: $searchText)
                .onChange(of: searchText) { _, _ in
                    searchLocation()
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Near me") {
                            Task { await centerOnUser() }
                        }
                        .disabled(locationReader.loading)
                    }
                }
                .sheet(item: $detailedRoad) { road in
                    NavigationStack {
                        RouteDetailView(road: road)
                    }
                }
                .task {
                    locationReader.requestAuthorization()
                    loadVisibleRoads()
                }
            }
        }
    }

    // MARK: - Preview card actions

    /// Starts a drive directly from the map preview, generating pacenotes on
    /// the spot and pulling the user onto the Drive tab.
    private func startDrive(_ road: TougeRoad) {
        let coords = road.geoPoints
        let result = PacenoteGenerator.generate(coords)
        engine.start(route: RecordedRoute(
            coordinates: coords.map { $0.clLocation },
            annotations: result.turns.map {
                TurnMarker(coordinate: $0.apex.clLocation, title: $0.text, subtitle: "")
            },
            totalLengthMeters: road.lengthMeters,
            callDistanceMeters: 120,
            roadID: road.id,
            name: road.displayName
        ))
        selectedRoad = nil
        router.enterDriveMode()
    }

    // MARK: - Map content (extracted to keep the type-checker tractable)

    @MapContentBuilder
    private var roadOverlays: some MapContent {
        ForEach(visibleRoads) { road in
            if road.geoPoints.count >= 2 {
                roadOverlay(for: road)
            }
        }
    }

    private func roadOverlay(for road: TougeRoad) -> some MapContent {
        MapPolyline(coordinates: road.geoPoints.map(\.clLocation))
            .stroke(ScoreStyle.color(for: road.totalScore ?? 0), lineWidth: lineWidth(for: road))
    }

    private func lineWidth(for road: TougeRoad) -> CGFloat {
        (selectedRoad?.id == road.id) ? 6 : 3
    }

    @MapContentBuilder
    private var savedRouteAnnotations: some MapContent {
        ForEach(store.routes()) { route in
            routeAnnotation(for: route)
        }
    }

    private func routeAnnotation(for route: SavedRoute) -> some MapContent {
        Annotation(
            coordinate: CLLocationCoordinate2D(latitude: route.centerLat, longitude: route.centerLon)
        ) {
            EmptyView()
        } label: {
            RouteMarkerView(route: route)
        }
    }

    @MapContentBuilder
    private var userMarker: some MapContent {
        UserAnnotation {
            Circle()
                .fill(Color.blue)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
    }

    // MARK: - Overlays

    /// Loading spinner only — the score legend was removed so nothing sits
    /// over the map while panning.
    private var topOverlay: some View {
        Group {
            if isLoading {
                loadingIndicator
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var loadingIndicator: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .padding(8)
    }

    // MARK: - Tile loading

    /// Tracks the visible span independently of `MapCameraPosition.region`.
    ///
    /// `position.region` is nil as soon as the user pans (the camera switches
    /// out of a plain region), so the old `onChange(of: position)` +
    /// `position.region ?? defaultRegion` fell back to the Boston default and
    /// rescored the same roads no matter where you scrolled. `onMapCameraChange`
    /// gives the real visible rect on every camera update.
    private func loadVisibleRoads() {
        tileLoadTask?.cancel()
        tileLoadTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run { isLoading = true }

            let region = visibleRegion
            let roads = (try? await store.localRoads(in: region)) ?? []
            await MainActor.run {
                visibleRoads = scored(roads, in: region)
                isLoading = false
            }
        }
    }

    /// Last known visible region, fed by `onMapCameraChange`.
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.35, longitude: -71.1),
        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
    )

    /// Colours each road by score and drops anything scrolled far off-screen.
    ///
    /// Sorting by score puts the best roads last so they draw on top of the
    /// lower-value ones they overlap with.
    private func scored(_ roads: [TougeRoad], in region: MKCoordinateRegion) -> [TougeRoad] {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        return roads
            .filter { road in
                guard let la = road.centerLat, let lo = road.centerLon else { return false }
                return la >= minLat && la <= maxLat && lo >= minLon && lo <= maxLon
            }
            .sorted { ($0.totalScore ?? 0) < ($1.totalScore ?? 0) }
    }

    // MARK: - Location

    private func centerOnUser() async {
        do {
            let loc = try await locationReader.currentLocation()
            position = .region(MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
            ))
        } catch {
            // Location failed — user can retry
        }
    }

    // MARK: - Search

    private func searchLocation() {
        searchTask?.cancel()
        guard !searchText.isEmpty else { return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)

            // First, try finding a road by name among visible roads.
            if let road = visibleRoads.first(where: {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }) {
                await flyTo(road: road)
                return
            }

            // Fallback: geocode as a location string.
            let geocoder = CLGeocoder()
            do {
                let placemarks = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CLPlacemark]?, Error>) in
                    geocoder.geocodeAddressString(searchText) { placemarks, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: placemarks)
                        }
                    }
                }
                if let placemark = placemarks?.first, let location = placemark.location {
                    await MainActor.run {
                        position = .region(MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
                        ))
                    }
                }
            } catch {
                // Geocode failed — silently ignore
            }
        }
    }

    private func flyTo(road: TougeRoad) async {
        guard let lat = road.centerLat, let lon = road.centerLon,
              road.geoPoints.count >= 2 else { return }
        await MainActor.run {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
        }
    }

    // MARK: - Tap handling

    /// Finds the road whose geometry passes closest to a tapped coordinate.
    ///
    /// The tolerance scales with the visible span. A fixed 50m radius is
    /// effectively untappable when zoomed out (a 0.25° region spans ~28km, so
    /// 50m is a fraction of a percent of the screen) but far too greedy when
    /// zoomed all the way in. Clamped to roughly 15–400m.
    private func nearestRoad(to point: CLLocationCoordinate2D, in roads: [TougeRoad]) -> TougeRoad? {
        let spanKm = max(visibleRegion.span.latitudeDelta, visibleRegion.span.longitudeDelta) * 111.0
        let threshold = min(max(spanKm * 1000 * 0.012, 15), 400)
        let tapped = GeoPoint.from(point)

        var nearest: (road: TougeRoad, distance: CLLocationDistance)?
        for road in roads {
            guard road.geoPoints.count >= 2 else { continue }
            // Cheap reject before the per-point distance loop.
            guard let centerLat = road.centerLat, let centerLon = road.centerLon,
                  GeoMath.distanceMeters(
                      tapped,
                      GeoPoint(lon: centerLon, lat: centerLat)
                  ) <= threshold + roadSpanRadius(road) else { continue }

            for gp in road.geoPoints {
                let dist = GeoMath.distanceMeters(tapped, gp)
                if dist <= threshold,
                   nearest == nil || dist < nearest!.distance {
                    nearest = (road, dist)
                }
            }
        }
        return nearest?.road
    }

    /// Half the road's own length, so long roads stay hittable near their ends
    /// even when the tap is far from the midpoint.
    private func roadSpanRadius(_ road: TougeRoad) -> CLLocationDistance {
        max(0, road.lengthMeters / 2)
    }

    // MARK: - Styling

    private func scoreColor(_ score: Int) -> Color {
        if score >= 80 { return Color(red: 0.929, green: 0.239, blue: 0.196) }
        if score >= 50 { return Color(red: 1.0, green: 0.757, blue: 0.031) }
        return Color(red: 0.275, green: 0.651, blue: 0.196)
    }
}

private struct RouteMarkerView: View {
    let route: SavedRoute
    var body: some View {
        Text(route.name)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 4))
    }
}
