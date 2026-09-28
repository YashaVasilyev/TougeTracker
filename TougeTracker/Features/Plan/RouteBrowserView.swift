import SwiftUI
import MapKit
import CoreLocation

struct RouteBrowserView: View {
    @Environment(AppSettings.self) private var settings: AppSettings
    @Environment(RouteStore.self) private var store: RouteStore
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(TabRouter.self) private var router: TabRouter

    /// Shown as a leading "Done" control. Set when this view is presented modally
    /// (the Drive tab's "Browse roads…" sheet), where the navigation bar is
    /// hidden and there would otherwise be no way back.
    var onDismiss: (() -> Void)? = nil

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
    /// Whether the floating search field is expanded. Driven by the magnifying
    /// glass button in the top-right of the custom header.
    @State private var isSearchVisible = false
    @FocusState private var isSearchFocused: Bool

    @State private var tileLoadTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    /// In-flight OSM route lookup between the two segment taps.
    @State private var routeTask: Task<Void, Never>?
    /// True while the route is being fetched, so the map can show a spinner
    /// instead of appearing to ignore the second tap.
    @State private var isRouting = false
    /// Message shown when the two taps cannot be joined by a drivable road.
    @State private var routeError: String?
    private let planner = RoutePlanner.shared

    // MARK: Segment mode

    /// When true, taps define a custom route instead of selecting a whole
    /// road. See `handleSegmentTap`.
    @State private var isSegmentMode = false
    /// First of the two taps, kept as a raw coordinate: the user is allowed
    /// to tap a road the app has never heard of.
    @State private var segmentStart: CLLocationCoordinate2D?
    /// Name of the road at the first tap, used to name the finished route.
    /// Resolved from the bundled tiles when we can, and from OSM otherwise.
    @State private var segmentStartRoadName: String?
    /// Live preview of the route so far, and the finished road once routed.
    @State private var customSegment: TougeRoad?
    @State private var segmentError: String?

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    roadOverlays
                    savedRouteLines
                    segmentOverlays
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
                    if isSegmentMode {
                        handleSegmentTap(at: coordinate)
                    } else if let hit = nearestRoad(to: coordinate, in: visibleRoads) {
                        selectedRoad = hit
                    } else if let saved = nearestSavedRoute(to: coordinate) {
                        // A saved route is not in the tile data, so it is only
                        // reachable by hit-testing the store's own geometry.
                        selectedRoad = saved.asRoad
                    } else {
                        selectedRoad = nil
                    }
                }
                .overlay(alignment: .top) {
                    topOverlay
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        // Recenter sits above the card so an appearing card
                        // pushes the arrow up instead of burying it.
                        HStack {
                            Spacer()
                            recenterButton
                        }
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
                }
                .animation(.snappy(duration: 0.25), value: selectedRoad?.id)
                .animation(.snappy(duration: 0.25), value: customSegment?.id)
                // The header is drawn in the top overlay so "Plan" can sit at the
                // very top of the map with the search button beside it.
                .toolbar(.hidden, for: .navigationBar)
                .onChange(of: searchText) { _, _ in
                    searchLocation()
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
        MapPolyline(coordinates: displayPoints(for: road).map(\.clLocation))
            .stroke(ScoreStyle.color(for: road.totalScore ?? 0), lineWidth: lineWidth(for: road))
    }

    /// The geometry actually handed to MapKit for this road.
    ///
    /// Thinned when zoomed out: at a wide span a full-detail polyline is far
    /// more vertices than the pixels it occupies, and every one of them costs
    /// tessellation time. At street zoom this returns the road untouched.
    private func displayPoints(for road: TougeRoad) -> [GeoPoint] {
        let points = road.geoPoints
        let span = currentSpanDegrees
        let budget = RenderBudget.maxPoints(spanDegrees: span)
        guard budget < points.count else { return points }

        // Convert the view width to metres-per-degree so the spacing tolerance
        // tracks how much screen space a vertex really covers.
        let metersPerDegree = 111_320.0
        let tolerance = max(span * metersPerDegree / 600, 1)
        return PolylineSimplifier.thin(points, maxPoints: budget,
                                       minSpacingMeters: tolerance)
    }

    /// Longest edge of the current view, in degrees.
    private var currentSpanDegrees: Double {
        max(visibleRegion.span.latitudeDelta, visibleRegion.span.longitudeDelta)
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

    /// Saved routes are drawn from the store, not from the in-progress
    /// selection.
    ///
    /// The polyline used to come from `customSegment`, which holds only the most
    /// recent route — so building a second custom route made the first vanish
    /// from the map even though it was safely saved. Reading geometry back out
    /// of the store is what makes "save" mean the route stays.
    @MapContentBuilder
    private var savedRouteLines: some MapContent {
        ForEach(store.routes()) { route in
            if route.coordinates.count >= 2 {
                MapPolyline(coordinates: route.coordinates.map(\.clLocation))
                    .stroke(routeColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
    }

    @MapContentBuilder
    private var segmentOverlays: some MapContent {
        // The route currently being previewed, before it is saved. Once saved it
        // is drawn by `savedRouteLines`, so this is only the unsaved draft.
        if let segment = customSegment,
           segment.geoPoints.count >= 2,
           !store.isSaved(id: segment.id) {
            // Solid red, matching the selected-road convention on this map
            // rather than the dashed "pending selection" styling.
            MapPolyline(coordinates: segment.geoPoints.map(\.clLocation))
                .stroke(routeColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        // While picking, show the first anchor so the user can see what the
        // second tap will be routed from.
        if let start = segmentStart {
            Annotation("Start", coordinate: start) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundStyle(routeColor)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
        }
    }

    /// The colour of a custom route line and its start pin, so the pin always
    /// matches the line it anchors.
    private let routeColor = Color(red: 0.929, green: 0.239, blue: 0.196)

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

    /// Custom map header: the "Plan" title with a search button in the top-right,
    /// plus the search field itself when expanded. The score legend was removed
    /// so nothing else sits over the map while panning.
    private var topOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // Only when presented modally: on the Plan tab there is no
                // title to displace, and the tab bar already provides a way out.
                if let onDismiss {
                    Button("Done", action: onDismiss)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                } else {
                    Text("Plan")
                        .font(.largeTitle.bold())
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }

                Spacer(minLength: 12)

                segmentToggleButton
                searchToggleButton
            }

            if isSegmentMode {
                segmentHint
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isSearchVisible {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isLoading {
                loadingIndicator
            }

            if isRouting {
                // The second tap triggered an OSM lookup; without this the map
                // looks like it ignored the tap for a second or two.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Routing…")
                        .font(.footnote).fontWeight(.medium)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .animation(.snappy(duration: 0.25), value: isSearchVisible)
        .animation(.snappy(duration: 0.25), value: isLoading)
        .animation(.snappy(duration: 0.25), value: isRouting)
        .toast($routeError)
    }

    /// Enters "make a segment" mode. Pairs with the search button; the filled
    /// state keeps the active mode readable at a glance.
    private var segmentToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                if isSegmentMode { exitSegmentMode() } else {
                    isSegmentMode = true
                    selectedRoad = nil
                }
            }
        } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSegmentMode ? Color.white : Color.primary)
                .frame(width: 46, height: 46)
                .background(isSegmentMode ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.regularMaterial),
                            in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .accessibilityLabel(isSegmentMode ? "Cancel segment" : "Make a segment")
    }

    /// Coaching line for the two-tap gesture. It doubles as the error surface so
    /// a failed second tap tells the user what to do next, not just what failed.
    private var segmentHint: some View {
        HStack(spacing: 8) {
            Image(systemName: segmentStart == nil ? "hand.tap" : "arrow.left.and.right")
                .foregroundStyle(.orange)
            Text(segmentHintText)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Cancel") { exitSegmentMode() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var segmentHintText: String {
        if let segmentError { return segmentError }
        if isRouting { return "Finding the road between those points…" }
        return segmentStart == nil
            ? "Tap the start of the road you want to drive."
            : "Now tap the end."
    }

    /// Circular magnifier that expands/collapses the search field. Mirrors the
    /// styling of the floating recenter button so the two read as a pair.
    private var searchToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { isSearchVisible.toggle() }
            isSearchFocused = isSearchVisible
        } label: {
            Image(systemName: isSearchVisible ? "xmark" : "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .accessibilityLabel(isSearchVisible ? "Close search" : "Search")
    }

    /// Replaces the old `.searchable` bar — a floating field under the header.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .onChange(of: isSearchFocused) { _, focused in
            // Tapping the magnifier should also raise the keyboard; dismissing
            // the keyboard collapses the field so the header stays compact.
            if !focused, searchText.isEmpty { isSearchVisible = false }
        }
    }

    /// Floating recenter control, bottom-right. Replaces the old "Near me"
    /// toolbar button so the nav bar stays uncluttered and the button sits
    /// within thumb reach.
    private var recenterButton: some View {
        Button {
            Task { await centerOnUser() }
        } label: {
            Image(systemName: "location.north.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .disabled(locationReader.loading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityLabel("Center on my location")
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

        // Zoomed out past the point where any road is legible, load nothing.
        // Decoding dozens of tiles to then draw none of them was most of the
        // cost, and it happened on every camera settle.
        guard currentSpanDegrees <= RenderBudget.detailSpanDegrees * 2 else {
            visibleRoads = []
            isLoading = false
            return
        }

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

        let visible = roads.filter { road in
            guard let la = road.centerLat, let lo = road.centerLon else { return false }
            return la >= minLat && la <= maxLat && lo >= minLon && lo <= maxLon
        }

        // Zoomed out the view spans many tiles, and the uncapped list is what
        // MapKit chokes on. `RenderBudget` keeps the best roads; the sort below
        // then restores the draw order (best last) that the map relies on.
        let budgeted = RenderBudget.roads(visible, spanDegrees: currentSpanDegrees)
        return budgeted.sorted { ($0.totalScore ?? 0) < ($1.totalScore ?? 0) }
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
        let threshold = snapToleranceMeters()
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

    /// Finds a saved route whose stored geometry passes close to a tap.
    ///
    /// Uses the same zoom-scaled tolerance as road selection so a saved route is
    /// as grabbable as a road, and so it is not stolen by a parallel tile road
    /// that merely sits nearer the finger.
    private func nearestSavedRoute(to point: CLLocationCoordinate2D) -> SavedRoute? {
        let tolerance = snapToleranceMeters()
        let candidates = store.routes().filter { $0.coordinates.count >= 2 }

        let hits = candidates.compactMap { route -> (SavedRoute, CLLocationDistance)? in
            guard let hit = RoadSegmentBuilder.snap(point, in: [route.asRoad],
                                                   toleranceMeters: tolerance) else { return nil }
            return (route, hit.perpendicularDistance)
        }
        return hits.min { $0.1 < $1.1 }?.0
    }

    // MARK: - Segment mode

    /// Two taps make a route: the first sets the start, the second the end, and
    /// the driving line between them comes back from OpenStreetMap.
    ///
    /// The taps are raw coordinates, not snapped to a known road — the whole
    /// point is to be able to route a stretch the bundled tiles never covered.
    /// When both taps do happen to land on the same ranked road we still take
    /// the local geometry, which is instant and needs no network.
    private func handleSegmentTap(at coordinate: CLLocationCoordinate2D) {
        segmentError = nil
        routeError = nil

        guard let start = segmentStart else {
            segmentStart = coordinate
            // Start the name lookup now so it overlaps the user choosing their
            // end point, rather than adding a round-trip after the route.
            segmentStartRoadName = nearestRoad(to: coordinate, in: visibleRoads)?.displayName
            Task { segmentStartRoadName = await planner.roadName(near: coordinate)
                        ?? segmentStartRoadName }
            return
        }

        // Fast path: both ends sit on one road we already hold, so the
        // segment can be carved locally with no network round-trip.
        if let points = localSegment(from: start, to: coordinate) {
            finish(points: points)
            return
        }
        routeBetween(start, coordinate)
    }

    /// Extracts the local stretch when both taps are on the same ranked road.
    /// Returns nil whenever the local path does not apply — different roads, or
    /// either end off any road we know — and the caller falls back to routing.
    private func localSegment(from start: CLLocationCoordinate2D,
                              to end: CLLocationCoordinate2D) -> [GeoPoint]? {
        let tolerance = snapToleranceMeters(segment: true)
        guard let a = RoadSegmentBuilder.snap(start, in: visibleRoads, toleranceMeters: tolerance),
              let b = RoadSegmentBuilder.snap(end, in: visibleRoads, toleranceMeters: tolerance),
              a.road.id == b.road.id,
              let points = try? RoadSegmentBuilder.extract(from: a, to: b),
              points.count >= 2 else { return nil }
        return points
    }

    /// Routes between the two taps over OSM and shows the result.
    private func routeBetween(_ start: CLLocationCoordinate2D,
                              _ end: CLLocationCoordinate2D) {
        routeTask?.cancel()
        routeError = nil
        isRouting = true

        routeTask = Task {
            defer { isRouting = false }
            do {
                let road = try await planner.road(from: start, to: end,
                                                   name: segmentStartRoadName)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    customSegment = road
                    selectedRoad = road
                    segmentStart = nil
                    isSegmentMode = false
                }
            } catch RoutePlanner.Failure.noRoute {
                // Keep the first tap: the user most likely mis-tapped the end,
                // and re-aiming is cheaper than starting over.
                routeError = "No drivable road connects those two points."
            } catch RoutePlanner.Failure.tooShort {
                segmentStart = nil
                routeError = "Those two points are too close together."
            } catch {
                routeError = "Couldn't reach OpenStreetMap. Check your connection."
            }
        }
    }

    /// Wraps a freshly built line and hands it to the preview card.
    private func finish(points: [GeoPoint]) {
        // Named after the road at the first tap so the route reads as a place,
        // not a measurement. Falls back to the length when that road is
        // unnamed, which is the only distinguishing handle left.
        let meters = GeoMath.lengthMeters(points)
        let fallback = "Segment \(settings.units.distanceString(meters))"
        let road = RoadSegmentBuilder.makeRoad(
            points: points,
            name: segmentStartRoadName ?? fallback
        )
        withAnimation(.snappy(duration: 0.25)) {
            customSegment = road
            selectedRoad = road
            segmentStart = nil
            isSegmentMode = false
        }
    }

    /// Leaves segment mode and discards any half-finished selection.
    private func exitSegmentMode() {
        isSegmentMode = false
        segmentStart = nil
        segmentStartRoadName = nil
        customSegment = nil
        segmentError = nil
    }

    // MARK: - Tap handling

    /// Half the road's own length, so long roads stay hittable near their ends
    /// even when the tap is far from the midpoint.
    private func roadSpanRadius(_ road: TougeRoad) -> CLLocationDistance {
        max(0, road.lengthMeters / 2)
    }

    /// Tap tolerance in meters, scaled to the zoom so a road is grabbable at
    /// every scale. A fixed radius is untappable when zoomed out (a 0.25° region
    /// spans ~28km) and far too greedy zoomed all the way in. Clamped to
    /// roughly 15–400m.
    ///
    /// Segment mode uses a tighter clamp than road selection: a segment is
    /// defined by where you tap on a *specific* stretch, so grabbing the
    /// nearest of several near-parallel roads is more likely to be wrong here.
    private func snapToleranceMeters(segment: Bool = false) -> CLLocationDistance {
        let spanKm = max(visibleRegion.span.latitudeDelta, visibleRegion.span.longitudeDelta) * 111.0
        let fraction = segment ? 0.006 : 0.012
        return min(max(spanKm * 1000 * fraction, 15), segment ? 200 : 400)
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
