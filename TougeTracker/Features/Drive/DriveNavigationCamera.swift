import SwiftUI
import MapKit
import CoreLocation
import QuartzCore

/// Drives the drive map's navigation camera.
///
/// The GPS fixes arrive about once a second, and a camera that jumps to each
/// one in turn looks like a slideshow of the road. So the camera is not driven
/// by the fixes at all: the fixes are the *target*, and a `CADisplayLink` eases
/// the camera toward that target on every frame the screen draws. The pan is
/// then continuous by construction rather than by tuning, and the maths in
/// `NavCamera` decides where the target is and how eagerly it is approached.
///
/// Heading-up is the default, as in any navigation app: the map turns to face
/// the way the car is travelling. Panning or rotating the map takes that away —
/// a driver who looks somewhere else should not have the map snatch it back
/// mid-corner — and `isFollowing` going false is what puts the recenter chip on
/// screen.
@MainActor
@Observable
final class DriveNavigationCamera {

    // MARK: - Observable state

    /// Bound straight to `Map(position:)`. Reassigned every frame, which is the
    /// point: the binding is the output of the easing, not a request for one.
    ///
    /// Settable because `Map` writes a user's pan back through it, and those
    /// writes are how the camera learns it has been overridden. The read side is
    /// the one that matters, and it is only ever written from `frame()`.
    var position: MapCameraPosition

    /// False once the driver has panned or rotated the map away from the car.
    private(set) var isFollowing = true

    /// The direction the car is travelling, for the puck to point along. Nil
    /// until a fix carries a course or the compass reports one.
    private(set) var bearing: Double?

    /// What the puck should be rotated to on screen, in degrees clockwise from
    /// up. Precomputed here so the view never has to know the rule.
    private(set) var puckRotationDegrees: Double = 0

    /// The camera as it currently stands. Exposed for the heading toggle, and
    /// so tests can watch it converge.
    private(set) var state: NavCameraState

    // MARK: - Internal

    private var fix: NavFix?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    /// The last camera we handed to MapKit. Used to tell a user gesture from
    /// our own writes: ours comes back unchanged, a gesture's does not.
    private var lastCommanded: NavCameraState?

    /// Metres the map has to move, degrees it has to turn, or metres of altitude
    /// before a new frame's worth of motion is worth telling MapKit about.
    /// Below these the camera is effectively still, and the writes are pure
    /// cost: MapKit animates toward whatever the binding holds, so a stream of
    /// near-identical cameras is a stream of animation restarts, which reads as
    /// a stutter rather than as stillness.
    private static let minimumMoveMeters: Double = 0.05
    private static let minimumTurnDegrees: Double = 0.05
    private static let minimumZoomDelta: Double = 0.5

    /// The display link and its target, in one box.
    ///
    /// Boxed because `CADisplayLink` retains its target, so the link cannot be
    /// owned by the camera without the camera being unable to let go of it. The
    /// box is `Sendable` and its methods are not actor-isolated, which is what
    /// lets `deinit` — which is not on the main actor — invalidate a link that
    /// would otherwise keep firing for the life of the tab.
    private let ticker: DisplayLinkTicker

    // MARK: - Lifecycle

    init() {
        // Apple Park, as a last resort before the first fix: a drive that has
        // just started is somewhere on a road, and a map opened on Null Island
        // is the one frame everyone remembers.
        let placeholder = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        let initial = NavCameraState.initial(center: placeholder)
        state = initial
        lastCommanded = initial
        position = DriveNavigationCamera.mapPosition(for: initial)
        ticker = DisplayLinkTicker()
        ticker.onFrame = { [weak self] in self?.frame() }
    }

    deinit {
        // A live display link retains its target, so without this the camera —
        // and the view tree holding it — would outlive the drive by however long
        // the tab stayed open, ticking at 120 Hz the whole while.
        ticker.invalidate()
    }

    /// Feeds a new fix in. Called at the GPS rate; the smoothing happens later,
    /// on the display link.
    func ingest(_ fix: NavFix) {
        // A fix older than the one already held is a re-delivery, not news, and
        // stepping the camera backwards is worse than ignoring it.
        if let previous = self.fix, fix.timestamp < previous.timestamp { return }
        self.fix = fix
        bearing = NavCamera.travelBearing(for: fix)
        start()
    }

    /// Begins easing the camera on every frame. Cheap to call when already
    /// running, because the GPS keeps calling it.
    func start() {
        guard !ticker.isRunning else { return }
        lastFrameTime = CACurrentMediaTime()
        ticker.start()
    }

    func stop() {
        ticker.invalidate()
    }


    // MARK: - The frame

    private func frame() {
        let now = CACurrentMediaTime()
        // A first frame, or a resume from the background, has no meaningful
        // `dt`. Easing by one nominal frame is harmless; easing by the several
        // seconds that were missed would snap the map across the countryside.
        let dt = lastFrameTime == 0 ? 0 : min(max(now - lastFrameTime, 0), 1.0 / 20.0)
        lastFrameTime = now

        guard let fix, isFollowing else { return }
        // The lead is laid out along the heading the camera has already eased
        // to, not along the raw course in this second's fix. Course over ground
        // is recomputed from scratch on every fix and can differ by a dozen
        // degrees between one and the next; a 30 m lead swung through 12° throws
        // the target six metres sideways in one frame, which is a visible lurch
        // once a second — through the corner, where it is least welcome.
        guard let target = NavCamera.target(for: fix, now: now,
                                            leadBearing: state.heading) else { return }

        let next = NavCamera.smoothed(from: state, towards: target, dt: dt)
        guard isWorthRedrawing(from: state, to: next) else { return }

        state = next
        if let bearing {
            puckRotationDegrees = NavCamera.puckRotation(bearing: bearing, cameraHeading: next.heading)
        }
        lastCommanded = next
        position = DriveNavigationCamera.mapPosition(for: next)
    }

    private func isWorthRedrawing(from old: NavCameraState, to new: NavCameraState) -> Bool {
        if GeoMath.distanceMeters(GeoPoint.from(old.center), GeoPoint.from(new.center))
            >= Self.minimumMoveMeters { return true }
        if GeoMath.wrap180(new.heading - old.heading).magnitude >= Self.minimumTurnDegrees { return true }
        if abs(new.distance - old.distance) >= Self.minimumZoomDelta { return true }
        return false
    }

    private static func mapPosition(for state: NavCameraState) -> MapCameraPosition {
        // Flat, not tilted. A pitched camera at speed buries the far road behind
        // the near geometry — exactly the road the driver is trying to read —
        // and Apple Maps keeps navigation flat for the same reason.
        .camera(MapCamera(centerCoordinate: state.center,
                          distance: state.distance,
                          heading: state.heading,
                          pitch: 0))
    }

    // MARK: - User control

    /// Called with the camera MapKit reports once a gesture has finished.
    ///
    /// Comparing against the last camera we asked for is what separates "the
    /// driver panned the map" from "the map settled into the position we set":
    /// ours comes back unchanged, a gesture's does not.
    func userMovedCamera(to reported: MapCamera) {
        guard isFollowing, let commanded = lastCommanded else { return }
        let reportedState = NavCameraState(center: reported.centerCoordinate,
                                           heading: reported.heading,
                                           distance: reported.distance)
        let moved = GeoMath.distanceMeters(GeoPoint.from(commanded.center),
                                            GeoPoint.from(reportedState.center))
        let turned = GeoMath.wrap180(reportedState.heading - commanded.heading).magnitude
        let zoomed = abs(reportedState.distance - commanded.distance)
        // Generous thresholds, because a gesture in progress reports a camera
        // that has only travelled a little by the time it is delivered, and
        // dropping follow on a rounding difference would strand the driver on a
        // frozen map with a chip they have to notice to clear.
        guard moved > 8 || turned > 6 || zoomed > max(20, commanded.distance * 0.15) else { return }

        isFollowing = false
        stop()
        // The camera stays exactly where the driver put it, and `state` follows
        // it there, so resuming glides back to the car from what they were just
        // looking at rather than cutting to it.
        state = reportedState
    }

    /// Called with the camera MapKit reports while the driver is off following,
    /// so the puck keeps pointing the right way in a map they moved themselves.
    func cameraSettled(on reported: MapCamera) {
        guard !isFollowing else { return }
        state = NavCameraState(center: reported.centerCoordinate,
                               heading: reported.heading,
                               distance: reported.distance)
    }

    /// Hands control back to the camera. The recenter chip's whole job.
    func resumeFollowing() {
        guard !isFollowing else { return }
        isFollowing = true
        start()
}

/// Owns the `CADisplayLink` that drives the camera, and nothing else.
///
/// It exists as its own object because `CADisplayLink` retains its target: a
/// link owned by the camera would keep the camera — and the whole view tree
/// holding it — alive and ticking after the drive ended. Being `Sendable` and
/// unisolated is what lets the camera's `deinit` reach in and stop it, since
/// `deinit` does not run on the main actor.
private final class DisplayLinkTicker: NSObject, @unchecked Sendable {

    /// Set by the owner. Held as a closure rather than a target reference so the
    /// owner can capture itself weakly.
    ///
    /// `nonisolated(unsafe)` because `invalidate()` nils it and is called from
    /// `deinit`, which is not on the main actor. It is only ever *written* on the
    /// main actor — from `init` and from `invalidate` — and only ever called on
    /// it, so there is no race here; the attribute is simply the price of being
    /// able to stop the link from a deinit at all.
    nonisolated(unsafe) var onFrame: (@MainActor () -> Void)?

    private var link: CADisplayLink?

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // As fast as the display will draw, but never faster than 30: past that
        // the easing has converged and the extra frames buy nothing but heat.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        // `.common`, so a finger on the map or the co-driver talking does not
        // stop the camera mid-corner.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Delivered on the main run loop, so this is not a hop in practice; it
        // is written as `assumeIsolated` because a `Task` here can be scheduled
        // late and land after a newer frame.
        MainActor.assumeIsolated { onFrame?() }
    }
}

    }

