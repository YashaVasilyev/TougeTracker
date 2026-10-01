import SwiftUI
import MapKit

struct RouteDetailView: View {
    @Environment(AppSettings.self) private var settings: AppSettings
    @Environment(RouteStore.self) private var store: RouteStore
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(TabRouter.self) private var router: TabRouter
    @Environment(\.dismiss) private var dismiss

    /// The route as currently shown. Reversal replaces it here, and the
    /// pacenotes below are regenerated from the new geometry — which is what
    /// makes a reversed road read as a different drive rather than the same one
    /// relabelled.
    @State private var road: TougeRoad

    @State private var pacenotes: [Pacenote] = []

    /// Whether the labelled turn map is presented over this sheet.
    @State private var showingTurnMap = false
    /// The sheet the share action presents.
    @State private var exportFile: ExportFile?

    struct ExportFile: Identifiable {
        let id = UUID()
        let name: String
        let text: String
    }

    /// The call sheet, which is the one output of this whole pipeline that can
    /// be read without a map and without a signal.
    private var callSheet: String {
        RouteExporter.callSheet(road: road, notes: pacenotes, settings: settings)
    }

    private func export(text: String, name: String) {
        exportFile = ExportFile(name: RouteExporter.fileName(for: road, pathExtension: name),
                                text: text)
    }

    /// Notes rendered with the connector between each pair, measured apex to
    /// apex. Rendering each note on its own showed a bare column of grades with
    /// no indication of how the corners related.
    private var lines: [String] {
        PacenoteGenerator.renderedList(pacenotes, format: settings.pacenoteFormat)
    }

    /// The whole pacenote run as one line, for the road that has no turns.
    ///
    /// Computed alongside the turns rather than in `body`: generating walks
    /// every coordinate of the road — smoothing, resampling, the whole pipeline
    /// — and a computed property would repeat that on every redraw, for a
    /// string used only when there are no turns to show.
    private let emptyRunText: String

    init(road: TougeRoad) {
        _road = State(initialValue: road)
        let preview = PacenoteGenerator.generate(road.geoPoints)
        _pacenotes = State(wrappedValue: preview.turns)
        emptyRunText = preview.text
    }

    /// Flips the route end to end and rebuilds its notes.
    ///
    /// Reversing the geometry is enough: the notes carry the direction of
    /// travel, so a corner that was a left becomes a right once the line runs
    /// the other way. Anything cached from the old line has to be thrown away
    /// with it.
    private func reverseRoute() {
        road = road.reversed()
        pacenotes = PacenoteGenerator.generate(road.geoPoints).turns
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                roadMap

                Form {
                    Section("About") {
                        Text(road.displayName).font(.headline)
                        Text(String(format: "%.1f mi · Curvature %d/100", road.lengthMiles ?? 0, road.curvatureScore ?? 0))
                            .font(.caption).foregroundStyle(.secondary)
                        if road.direction.isKnown {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up")
                                    .rotationEffect(.degrees(road.direction.arrowRotation))
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                Text("Runs \(road.direction.compass), ends \(road.direction.reversedCompass)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Runs towards \(road.direction.compass)")
                        }
                    }
                    Section("Pacenotes (\(pacenotes.count))") {
                        if pacenotes.isEmpty {
                            Text(emptyRunText)
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
            .sheet(isPresented: $showingTurnMap) {
                TurnMapView(road: road, settings: settings)
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.text])
            }
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
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        reverseRoute()
                    } label: {
                        Label("Reverse", systemImage: "arrow.left.arrow.right")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingTurnMap = true
                    } label: {
                        Label("Turn map", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(pacenotes.allSatisfy(\.isStraight))
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button {
                            export(text: callSheet, name: "txt")
                        } label: {
                            Label("Call sheet", systemImage: "doc.text")
                        }
                        Button {
                            export(text: RouteExporter.gpx(road: road), name: "gpx")
                        } label: {
                            Label("GPX track", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export this route")
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

    /// The road, its pacenote apexes, and nothing else.
    ///
    /// Split out of `body` because the marker content is enough to push the
    /// whole view past what the type checker will do in reasonable time.
    private var roadMap: some View {
        Map(initialPosition: .region(MapFit.region(for: road.geoPoints.map { $0.clLocation })),
            interactionModes: .all) {
            if road.geoPoints.count > 1 {
                MapPolyline(coordinates: road.geoPoints.map { $0.clLocation })
                    .stroke(.blue.opacity(0.5), lineWidth: 3)
            }
            // Labelled with the grade, not an identical red pin: the point of a
            // marker is to say what the corner is, and an unlabelled pin only
            // says where it is. Straights are skipped — they are a distance,
            // not a place.
            ForEach(Array(pacenotes.enumerated()), id: \.offset) { _, note in
                if !note.isStraight {
                    Annotation(TurnMapView.turnLabel(for: note),
                               coordinate: note.apex.clLocation) {
                        GradeMarker(text: TurnMapView.turnLabel(for: note),
                                    grade: note.grade,
                                    spokenLabel: TurnMapView.spokenCall(for: note))
                    }
                }
            }
        }
        .mapStyle(.standard)
    }
}
