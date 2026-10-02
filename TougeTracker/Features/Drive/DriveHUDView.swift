import SwiftUI
import MapKit
import CoreLocation
import QuartzCore

/// The live driving HUD shown while a drive is being recorded.
///
/// The map is the instrument, not the backdrop: it is heading-up, it leads the
/// car by however far the speed says it should, and it is eased toward all of
/// that on every frame rather than snapped to it once a second. See
/// `DriveNavigationCamera` for the camera and `NavCamera` for the arithmetic.
struct DriveHUDView: View {
    @Environment(DriveEngine.self) private var engine: DriveEngine
    @Environment(AppSettings.self) private var settings: AppSettings
    @Environment(RouteStore.self) private var store: RouteStore
    @State private var camera = DriveNavigationCamera()

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea()

            // Explicit VStack + Spacer: bare ZStack children float in the
            // vertical centre, which is where these bars used to land.
            VStack(spacing: 8) {
                topStatusBar
                Spacer(minLength: 0)
                mapControls
                bottomCallout
            }
        }
        .toast(Binding(get: { engine.toast }, set: { engine.toast = $0 }))
        .onChange(of: engine.locationTick) { _ in
            // Only the arrival of a fix is interesting here. The camera's own
            // easing runs on its display link, so nothing in this view has to
            // ask the map to move.
            guard let coordinate = engine.lastLocation else { return }
            camera.ingest(NavFix(
                coordinate: coordinate,
                course: engine.courseDegrees,
                compass: engine.compassHeadingValid ? engine.compassHeading : nil,
                speed: engine.currentSpeedMps,
                timestamp: CACurrentMediaTime()))
        }
        .onDisappear { camera.stop() }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $camera.position, interactionModes: .all) {
            if engine.routeCoordinates.count > 1 {
                // The planned line is muted: it is context for the line you
                // actually drove, not the thing you are reading.
                MapPolyline(coordinates: engine.routeCoordinates)
                    .stroke(Theme.textTertiary, lineWidth: 3)
            }
            if engine.drivenPath.count > 1 {
                MapPolyline(coordinates: engine.drivenPath)
                    .stroke(Theme.accent, lineWidth: 3)
            }
            ForEach(engine.pacenoteAnnotations) { marker in
                // The pin goes in the *content*, not the `label`. The content is
                // laid out in screen space and does not turn with the map, which
                // is what a pin wants; MapKit's default label is a callout that
                // is hidden and re-shown by the annotation system.
                Annotation("", coordinate: marker.coordinate, content: {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.red).font(.caption2).offset(y: -10)
                })
            }
            if let loc = engine.lastLocation {
                // The point of the arrow: annotation content is laid out on
                // the screen rather than turned with the map, so rotating it
                // by the bearing relative to the camera's heading leaves it
                // pointing up the screen in heading-up, and swinging round to
                // the car's real direction the moment the map is north-up.
                //
                // In the content closure, not the label: a label is a callout
                // bubble, and MapKit is free to drop, defer or occlude one —
                // which is why the arrow was never on screen at all.
                Annotation("", coordinate: loc, content: {
                    DrivePuckView(rotationDegrees: camera.puckRotationDegrees,
                                  showsBeam: engine.currentSpeedMps > 1.5)
                })
            }
        }
        // Standard, flat, and without the points-of-interest layer. Navigation
        // is about the road; a hillside of restaurant labels on top of it is
        // clutter, and it is clutter that moves.
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // Nothing is gained from MapKit's own chrome: there is no user-location
        // dot to go looking for, because the arrow *is* the user location, and
        // the scale bar would sit under the callout.
        .mapControls { }
        .onMapCameraChange(frequency: .onEnd) { context in
            camera.userMovedCamera(to: context.camera)
        }
        .onMapCameraChange(frequency: .continuous) { context in
            camera.cameraSettled(on: context.camera)
        }
    }

    // MARK: - Map controls

    /// The two things a navigation map needs, and the recenter one only while
    /// it can do something. Small and out of the way: they sit between the
    /// driver and the road, and the road is the point.
    private var mapControls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if !camera.isFollowing {
                recenterChip
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            compassChip
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: camera.isFollowing)
        .padding(.horizontal, 12)
    }

    private var recenterChip: some View {
        Button {
            camera.resumeFollowing()
        } label: {
            Label("Recenter", systemImage: "location.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }

    /// Returns the camera to heading-up from wherever the driver left it — the
    /// same gesture Maps offers, and the only way back from a map someone has
    /// spun round to check what is behind them.
    private var compassChip: some View {
        Button {
            camera.resumeFollowing()
        } label: {
            Image(systemName: "location.north.fill")
                .font(.footnote.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter on the car")
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
            // Not a corner, so it is not styled as one: amber, smaller, and
            // never chained onto a severity. This is the line that says exactly
            // what is ahead even when the recorded pack can only say "caution".
            if let feature = engine.currentFeature {
                Label(feature, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
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
