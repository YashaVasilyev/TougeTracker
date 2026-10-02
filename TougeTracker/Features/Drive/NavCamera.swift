import Foundation
import CoreLocation

/// One GPS fix, as the drive camera needs to see it.
///
/// `course` and `compass` are kept apart because they are honest about different
/// things. `course` is where the car is actually going over the ground, but a
/// receiver will not report it at a standstill — and reports it as noise while
/// crawling. `compass` is which way the phone is pointed, which is what you want
/// when stopped and useless as a direction of travel. Choosing between them is
/// `NavCamera.travelBearing(for:)`.
struct NavFix: Equatable {
    var coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from true north. Nil when the receiver has no course.
    var course: Double?
    /// Degrees clockwise from magnetic/true north. Nil when unavailable or
    /// uncalibrated.
    var compass: Double?
    /// Metres per second.
    var speed: Double
    /// When the fix arrived, on the `CACurrentMediaTime` clock the driver and
    /// the dead-reckoning both run on.
    var timestamp: CFTimeInterval

    /// Spelled out because `CLLocationCoordinate2D` does not vend its own
    /// `Equatable`, and a camera test that cannot compare two cameras is not a
    /// camera test.
    static func == (lhs: NavFix, rhs: NavFix) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.course == rhs.course
            && lhs.compass == rhs.compass
            && lhs.speed == rhs.speed
            && lhs.timestamp == rhs.timestamp
    }
}

/// The camera as it is this frame: what is on screen right now.
///
/// This is deliberately not the same thing as where the camera is being taken.
/// A camera snapped to each 1 Hz fix steps visibly along the road; one that
/// eases toward a predicted target glides. `NavCamera.smoothed(from:towards:dt:)`
/// is the gap between the two.
struct NavCameraState: Equatable {
    /// The point under the middle of the screen.
    var center: CLLocationCoordinate2D
    /// Which compass direction is at the top of the screen, degrees clockwise
    /// from true north. This is what "heading-up" means, and what the puck is
    /// rotated against.
    var heading: Double
    /// Metres from the camera down to the ground beneath it.
    var distance: Double

    static func initial(center: CLLocationCoordinate2D) -> NavCameraState {
        NavCameraState(center: center, heading: 0, distance: NavCamera.standstillDistance)
    }

    static func == (lhs: NavCameraState, rhs: NavCameraState) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.heading == rhs.heading
            && lhs.distance == rhs.distance
    }
}

/// The maths behind the drive map's navigation camera.
///
/// Split out from the view and the display link so it can be tested against
/// numbers rather than pixels: a camera only ever judged by looking at it is a
/// camera whose 1 Hz stutter nobody catches until they are driving.
enum NavCamera {

    // MARK: - Tuning

    /// How quickly the camera centre chases its target. Short enough to feel
    /// attached to the car, long enough that a 1 Hz fix never shows as a jump.
    static let centreTimeConstant: TimeInterval = 0.26
    /// Rotation is eased more slowly than position. A hairpin is a real 180°,
    /// and taking that at the same rate as the pan makes the whole map spin
    /// like a record; a driver needs the turn to read as a turn.
    static let headingTimeConstant: TimeInterval = 0.55
    /// Zoom is the slowest of the three by a wide margin, because a camera that
    /// breathes in and out with every speed change is seasick.
    static let distanceTimeConstant: TimeInterval = 1.1

    /// How far ahead of the car, in metres, the camera looks, per metre per
    /// second of speed. At 100 km/h that is a little over 30 m of road read
    /// before you reach it — the difference between a map that trails you and
    /// one you can corner on.
    static let leadSeconds = 1.2
    static let maximumLeadMeters: Double = 120
    /// Below this the GPS course is noise about a stationary car, and the
    /// compass is the better answer.
    static let courseUsableSpeed: Double = 2.5

    /// Never extrapolate further than this from the last fix. A fix that
    /// stopped arriving must not send the camera down the road on its own.
    static let maximumDeadReckonSeconds: CFTimeInterval = 1.0

    static let standstillDistance: Double = 220
    static let maximumDistance: Double = 900
    /// Extra metres of altitude per metre per second of speed: you see further
    /// ahead the faster you go, as in any navigation app.
    static let distancePerMetrePerSecond: Double = 12

    // MARK: - Choosing a direction to point in

    /// Which way the car is travelling, in degrees, or nil when nothing knows.
    ///
    /// Course over ground beats the compass the moment the car is actually
    /// moving — it is measured along the road rather than off the phone's
    /// orientation, so it does not lie through a hairpin. Below walking pace it
    /// is discarded entirely and the compass is used, because a receiver
    /// sitting still will happily report a course for a road it is not on.
    public static func travelBearing(for fix: NavFix) -> Double? {
        if fix.speed >= courseUsableSpeed, let course = fix.course {
            return normalise(course)
        }
        if let compass = fix.compass {
            return normalise(compass)
        }
        return fix.course.map(normalise)
    }

    // MARK: - Where the car is now

    /// The car's position at `now`, extrapolated from the fix along its course.
    ///
    /// GPS arrives about once a second. Without this the camera would glide to
    /// a stop between fixes and lurch forward on the next one — the single
    /// most obvious thing that gives away a naive follow-cam. Extrapolation is
    /// capped, because past a second the fix is more likely to have been lost
    /// than the car to have kept its heading.
    public static func carPosition(_ fix: NavFix, now: CFTimeInterval) -> CLLocationCoordinate2D {
        let elapsed = min(max(now - fix.timestamp, 0), maximumDeadReckonSeconds)
        guard elapsed > 0, fix.speed > 0, let course = fix.course else { return fix.coordinate }
        let ahead = GeoMath.destination(GeoPoint.from(fix.coordinate), fix.speed * elapsed, course)
        return ahead.clLocation
    }

    /// How far past the car the camera centres itself, in metres. Zero at a
    /// standstill: there is nothing to anticipate when you are not moving.
    public static func leadDistance(speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        return min(speed * leadSeconds, maximumLeadMeters)
    }

    // MARK: - The target

    /// The camera the maths is aiming at this frame, or nil while there is
    /// nothing to aim from.
    ///
    /// The centre is the car's position pushed `leadDistance` further along
    /// `leadBearing`, so the road you are about to be on is already on screen
    /// when you get to it.
    ///
    /// `leadBearing` defaults to the direction of travel, which is right for a
    /// single isolated fix and wrong in a live camera. Course over ground is
    /// re-derived from scratch every second and can differ by 15° between one
    /// fix and the next, and a lead offset swung through 15° throws the target
    /// metres sideways in a single frame — a visible hiccup once per fix, right
    /// through the corner where the driver is busiest. A live camera therefore
    /// passes the heading it has *already* eased to, which moves continuously.
    public static func target(for fix: NavFix, now: CFTimeInterval,
                              leadBearing: Double? = nil) -> (centre: CLLocationCoordinate2D, heading: Double, distance: Double)? {
        let car = carPosition(fix, now: now)
        guard let bearing = travelBearing(for: fix) else {
            // No direction yet: sit on the car and keep the last heading rather
            // than inventing one. The camera is already initialised somewhere
            // sensible by the time the first fix lands.
            return (car, 0, distance(for: fix.speed))
        }
        let lead = leadDistance(speed: fix.speed)
        let centre = GeoMath.destination(GeoPoint.from(car), lead,
                                         leadBearing ?? bearing).clLocation
        return (centre, bearing, distance(for: fix.speed))
    }

    /// Camera altitude for a speed. Zooming out with speed is what gives the
    /// driver the time to react at 140 km/h that they do not need at 20.
    public static func distance(for speed: Double) -> Double {
        let speed = max(speed, 0)
        return min(max(standstillDistance + speed * distancePerMetrePerSecond, standstillDistance),
                   maximumDistance)
    }

    // MARK: - Easing

    /// The fraction of the remaining gap to close over `dt` seconds.
    ///
    /// Frame-rate independent by construction: a 30 fps device and a 120 fps
    /// one converge on the same place over the same wall-clock second. The
    /// naive `alpha = dt / duration` does not, and the camera drifts further
    /// from its target the slower the device is — which is exactly backwards.
    public static func smoothingFactor(dt: TimeInterval, timeConstant: TimeInterval) -> Double {
        // A non-positive `timeConstant` has no meaningful answer, so it is
        // treated as "no easing" rather than divided by. A zero `dt` is not an
        // error case at all: it is the first frame after the app comes back from
        // the background, and no time having passed means the camera must not
        // move. Returning 1 there would fling it across the countryside.
        guard timeConstant > 0 else { return 1 }
        guard dt > 0 else { return 0 }
        return 1 - exp(-dt / timeConstant)
    }

    /// Eases `state` toward `target`. Pure: no MapKit, no clock, no globals.
    public static func smoothed(from state: NavCameraState,
                                towards target: (centre: CLLocationCoordinate2D, heading: Double, distance: Double),
                                dt: TimeInterval) -> NavCameraState {
        NavCameraState(
            center: glide(from: state.center, to: target.centre,
                          fraction: smoothingFactor(dt: dt, timeConstant: centreTimeConstant)),
            heading: interpolateAngle(state.heading, target.heading,
                                      fraction: smoothingFactor(dt: dt, timeConstant: headingTimeConstant)),
            distance: state.distance + (target.distance - state.distance)
                * smoothingFactor(dt: dt, timeConstant: distanceTimeConstant))
    }

    /// Eases the centre along a geodesic toward `to`. Interpolating raw
    /// latitudes and longitudes would drift off the road across a line of
    /// longitude; moving a real distance along a real bearing cannot.
    public static func glide(from: CLLocationCoordinate2D,
                             to: CLLocationCoordinate2D,
                             fraction: Double) -> CLLocationCoordinate2D {
        let a = GeoPoint.from(from), b = GeoPoint.from(to)
        let gap = GeoMath.distanceMeters(a, b)
        guard gap > 0.01 else { return to }
        let step = gap * min(max(fraction, 0), 1)
        return GeoMath.destination(a, step, GeoMath.bearing(a, b)).clLocation
    }

    /// Interpolates an angle the short way round, so 350° → 10° turns 20° right
    /// rather than 340° left. This is the whole reason the camera does not spin
    /// through north on every northbound bend.
    public static func interpolateAngle(_ from: Double, _ to: Double, fraction: Double) -> Double {
        let delta = GeoMath.wrap180(to - from)
        return normalise(from + delta * min(max(fraction, 0), 1))
    }

    /// The rotation to draw the puck at, in screen degrees clockwise from up.
    ///
    /// Annotation content is laid out on the screen, not turned with the map,
    /// so the arrow's angle on screen is the bearing relative to whatever the
    /// camera has put at the top. Heading-up therefore parks it at 0°, pointing
    /// straight up the way a navigation app's does, and north-up swings it round
    /// to where the car is actually going.
    public static func puckRotation(bearing: Double, cameraHeading: Double) -> Double {
        GeoMath.wrap180(bearing - cameraHeading)
    }

    /// Folds an angle into 0..<360.
    public static func normalise(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}
