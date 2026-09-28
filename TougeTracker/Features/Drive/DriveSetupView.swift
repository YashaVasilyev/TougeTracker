import SwiftUI

struct DriveSetupView: View {
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(RouteStore.self) private var store: RouteStore
    @Environment(AppSettings.self) private var settings: AppSettings
    @State private var showBrowser = false

    var body: some View {
        NavigationStack {
            List {
                Section("Saved routes") {
                    let routes = store.routes()
                    if routes.isEmpty {
                        Text("No saved routes yet. Browse roads from the Plan tab to save a route.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(routes) { route in
                        RouteRowView(route: route, settings: settings)
                            .contentShape(Rectangle())
                            .onTapGesture { start(route) }
                    }
                }

                Section {
                    Button("Free Drive — pacenotes off", systemImage: "aq.hifispeaker") { startFree() }
                    Button("Browse roads…", systemImage: "magnifyingglass") { showBrowser = true }
                }

                Section {
                    if !engine.locationAuthorized {
                        Button("Grant location + motion permission", systemImage: "location") {
                            engine.requestAuthorization()
                        }
                    }
                }
            }
            .navigationTitle("Drive")
            // The browser hides its navigation bar, so it needs its own way
            // back to here; without it this sheet is a dead end.
            .sheet(isPresented: $showBrowser) {
                RouteBrowserView { showBrowser = false }
            }
        }
    }

    private func start(_ route: SavedRoute) {
        engine.start(route: recordedRoute(for: route))
    }

    private func startFree() { engine.start(route: nil) }

    private func recordedRoute(for route: SavedRoute) -> RecordedRoute {
        let coords = route.coordinates
        let turnMarkers = route.pacenotes.map {
            TurnMarker(coordinate: $0.apex.clLocation, title: $0.text, subtitle: "")
        }
        return RecordedRoute(
            coordinates: coords.map { $0.clLocation },
            annotations: turnMarkers,
            totalLengthMeters: route.lengthMeters,
            callDistanceMeters: 120,
            roadID: route.id,
            name: route.name
        )
    }
}
