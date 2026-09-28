import SwiftUI
import MapKit
import CoreLocation

/// The live driving HUD shown while a drive is being recorded.
struct DriveHUDView: View {
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(AppSettings.self) private var settings: AppSettings
    @Environment(RouteStore.self) private var store: RouteStore
    @State private var position = MapCameraPosition.region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
                           span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)))

    private var hudSpan: MKCoordinateSpan {
        MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
    }

    var body: some View {
        ZStack {
            Map(position: $position, interactionModes: .all) {
                if engine.routeCoordinates.count > 1 {
                    MapPolyline(coordinates: engine.routeCoordinates)
                        .stroke(Color.blue.opacity(0.5), lineWidth: 3)
                }
                if engine.drivenPath.count > 1 {
                    MapPolyline(coordinates: engine.drivenPath)
                        .stroke(Color.orange, lineWidth: 3)
                }
                ForEach(engine.pacenoteAnnotations) { marker in
                    Annotation(coordinate: marker.coordinate) {
                        EmptyView()
                    } label: {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red).font(.caption2).offset(y: -10)
                    }
                }
                if let loc = engine.lastLocation {
                    Annotation(coordinate: loc) {
                        EmptyView()
                    } label: {
                        Circle().fill(Color.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    }
                }
            }
            .ignoresSafeArea()

            // Explicit VStack + Spacer: bare ZStack children float in the
            // vertical centre, which is where these bars used to land.
            VStack(spacing: 8) {
                topStatusBar
                Spacer(minLength: 0)
                bottomCallout
            }
        }
        .toast(Binding(get: { engine.toast }, set: { engine.toast = $0 }))
        .onChange(of: engine.locationTick) { _ in
            if let loc = engine.lastLocation {
                position = .region(MKCoordinateRegion(center: loc, span: hudSpan))
            }
        }
    }

    // MARK: - Top: status + controls

    private var topStatusBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                Text(settings.units.speedString(engine.currentSpeedMps))
                    .font(.system(size: 34, weight: .thin, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading) {
                    Text("lat \(String(format: "%+.2f", engine.lateralG)) g")
                    Text("lon \(String(format: "%+.2f", engine.forwardG)) g")
                }
                .font(.caption).foregroundStyle(.secondary)

                Spacer(minLength: 8)

                GMeterView(forwardG: engine.forwardG, lateralG: engine.lateralG)
                    .frame(width: 52, height: 52)
            }

            HStack(spacing: 8) {
                Text("\(Int(engine.elapsed))s · \(settings.units.distanceString(engine.currentDistance))")
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer(minLength: 8)

                if engine.offRoute {
                    Label("Off route", systemImage: "location.north")
                        .labelStyle(.titleOnly)
                        .font(.caption).foregroundStyle(.yellow)
                }

                Button(engine.state == .paused ? "Resume" : "Pause") {
                    engine.state == .paused ? engine.resume() : engine.pause()
                }
                .font(.caption).fontWeight(.semibold)
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .tint(engine.state == .paused ? .green : .gray)

                Button("Mark") { engine.toast = "Corner noted" }
                    .font(.caption).fontWeight(.semibold)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .tint(.yellow)

                Button("Stop") {
                    if let d = engine.stop() { store.addDrive(d) }
                }
                .font(.caption).fontWeight(.semibold)
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: - Bottom: pacenote callout

    private var bottomCallout: some View {
        VStack(spacing: 6) {
            if let note = engine.currentNote {
                Text(note)
                    .font(.title3).fontWeight(.bold)
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .background(.ultraThickMaterial, in: Capsule())
            }
            if !engine.nextNotes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(engine.nextNotes.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            ProgressView(value: engine.progress)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
