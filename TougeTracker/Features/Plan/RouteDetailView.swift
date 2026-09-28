import SwiftUI
import MapKit

struct RouteDetailView: View {
    @Environment(AppSettings.self) private var settings: AppSettings
    @Environment(RouteStore.self) private var store: RouteStore
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(TabRouter.self) private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    let road: TougeRoad

    @State private var pacenotes: [Pacenote] = []

    /// Notes rendered with the connector between each pair, measured apex to
    /// apex. Rendering each note on its own showed a bare column of grades with
    /// no indication of how the corners related.
    private var lines: [String] {
        PacenoteGenerator.renderedList(pacenotes, format: settings.pacenoteFormat)
    }

    init(road: TougeRoad) {
        self.road = road
        let preview = PacenoteGenerator.generate(road.geoPoints)
        _pacenotes = State(wrappedValue: preview.turns)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(initialPosition: .region(fittedRegion(for: road.geoPoints.map { $0.clLocation })), interactionModes: .all) {
                    if road.geoPoints.count > 1 {
                        MapPolyline(coordinates: road.geoPoints.map { $0.clLocation })
                            .stroke(.blue.opacity(0.5), lineWidth: 3)
                    }
                    ForEach(Array(pacenotes.enumerated()), id: \.offset) { _, note in
                        Annotation(coordinate: note.apex.clLocation) {
                            EmptyView()
                        } label: {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.red).font(.caption).offset(y: -10)
                        }
                    }
                }
                .frame(height: 200)
                .mapStyle(.standard)

                Form {
                    Section("About") {
                        Text(road.displayName).font(.headline)
                        Text(String(format: "%.1f mi · Curvature %d/100", road.lengthMiles ?? 0, road.curvatureScore ?? 0))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Pacenotes (\(pacenotes.count))") {
                        if pacenotes.isEmpty {
                            Text(PacenoteGenerator.generate(road.geoPoints).text)
                                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                    HStack(alignment: .top) {
                                        Text("\(idx + 1)")
                                            .font(.caption).frame(width: 22, alignment: .leading)
                                            .foregroundStyle(.secondary)
                                        Text(line)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        engine.start(route: RecordedRoute(
                            coordinates: road.geoPoints.map { $0.clLocation },
                            annotations: pacenotes.map {
                                TurnMarker(coordinate: $0.apex.clLocation, title: $0.text, subtitle: "")
                            },
                            totalLengthMeters: road.lengthMeters,
                            callDistanceMeters: 120,
                            roadID: road.id,
                            name: road.displayName
                        ))
                        dismiss()
                        // Pull the user onto the Drive tab so the HUD is
                        // visible immediately rather than behind the map.
                        router.enterDriveMode()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if store.isSaved(id: road.id) {
                        Text("Saved")
                    } else {
                        Button("Save") {
                            _ = store.saveRoute(road)
                            engine.toast = "Saved"
                        }
                    }
                }
            }
        }
    }

    private func fittedRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard coords.count > 1 else { return MKCoordinateRegion() }
        var minLat = coords[0].latitude, maxLat = minLat
        var minLon = coords[0].longitude, maxLon = minLon
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let span = max(0.002, max(maxLat - minLat, maxLon - minLon) * 1.2)
        let lat = (minLat + maxLat) / 2
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span / abs(cos(lat * .pi / 180))))
    }
}
