import XCTest
@testable import TougeTracker
import CoreLocation
import MapKit
import SwiftUI

/// Covers the drive map's navigation camera: which way it points, where it
/// aims, and how it gets there.
///
/// These are numbers rather than pixels on purpose. Every one of them is a
/// decision that looks fine at one speed and is wrong at another, and a
/// screenshot cannot tell a 0.3 s lag from a 0.2 s one.
final class NavCameraTests: XCTestCase {

    private let cupertino = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)

    private func fix(course: Double? = 90, compass: Double? = nil,
                     speed: Double = 20, age: CFTimeInterval = 0) -> NavFix {
        NavFix(coordinate: cupertino, course: course, compass: compass,
               speed: speed, timestamp: 100 - age)
    }

    // MARK: - Which way it points

    func testCourseWinsOverCompassWhileMoving() {
        // Driving north-east with the phone held facing east: the road is the
        // answer, the phone is not.
        let bearing = NavCamera.travelBearing(for: fix(course: 45, compass: 90, speed: 20))
        XCTAssertEqual(bearing ?? -1, 45, accuracy: 0.001)
    }

    func testCompassWinsWhenStopped() {
        // A receiver sitting still will happily report a course for a road it is
        // not on, so below walking pace the course is discarded.
        let bearing = NavCamera.travelBearing(for: fix(course: 200, compass: 15, speed: 0.4))
        XCTAssertEqual(bearing ?? -1, 15, accuracy: 0.001)
    }

    func testNoCompassAndNoUsableCourseFallsBackToTheCourseItself() {
        // Crawling slowly but definitely pointed somewhere: a course is better
        // than nothing even when it is not yet trusted.
        XCTAssertEqual(NavCamera.travelBearing(for: fix(course: 300, compass: nil, speed: 1.0)) ?? -1,
                       300, accuracy: 0.001)
    }

    func testBearingIsNilWhenNothingKnowsWhichWayItIsGoing() {
        XCTAssertNil(NavCamera.travelBearing(for: fix(course: nil, compass: nil, speed: 20)))
    }

    func testBearingsAreNormalisedRatherThanPassedThrough() {
        // Core Location reports course in 0..<360, but a negative one from a
        // fused source would put the camera at -80° and spin it through north.
        XCTAssertEqual(NavCamera.travelBearing(for: fix(course: -80, speed: 20)) ?? -1,
                       280, accuracy: 0.001)
    }

    // MARK: - Where it aims

    func testCameraLeadsTheCarByMoreTheFasterYouGo() {
        // The whole premise of the predictive camera: at speed you can see the
        // road before you reach it.
        XCTAssertEqual(NavCamera.leadDistance(speed: 0), 0, accuracy: 0.001)
        let slow = NavCamera.leadDistance(speed: 10)
        let fast = NavCamera.leadDistance(speed: 30)
        XCTAssertGreaterThan(fast, slow)
        XCTAssertEqual(fast, 36, accuracy: 0.001)
    }

    func testLeadIsCappedSoTheCameraCannotOutrunTheCar() {
        // A downhill at 200 km/h would otherwise put the camera 200 m up the
        // road, showing a corner the driver has no way of reaching yet.
        XCTAssertEqual(NavCamera.leadDistance(speed: 200), NavCamera.maximumLeadMeters, accuracy: 0.001)
    }

    func testTargetSitsAheadOfTheCarAlongTheDirectionOfTravel() {
        let target = NavCamera.target(for: fix(course: 90, speed: 25), now: 100)
        let centre = target?.centre
        XCTAssertNotNil(centre)
        guard let centre else { return }
        // Due east: latitude unchanged, longitude increased.
        XCTAssertEqual(centre.latitude, cupertino.latitude, accuracy: 1e-4)
        XCTAssertGreaterThan(centre.longitude, cupertino.longitude)
        let ahead = GeoMath.distanceMeters(GeoPoint.from(cupertino), GeoPoint.from(centre))
        XCTAssertEqual(ahead, NavCamera.leadDistance(speed: 25), accuracy: 0.5)
    }

    func testTargetTurnsTheCameraTheWayTheCarIsGoing() {
        XCTAssertEqual(NavCamera.target(for: fix(course: 215, speed: 15), now: 100)?.heading ?? -1,
                       215, accuracy: 0.001)
    }

    func testZoomOpensUpWithSpeed() {
        // You need longer to react at 140 km/h than at 20.
        let crawling = NavCamera.distance(for: 1)
        let fast = NavCamera.distance(for: 35)
        XCTAssertGreaterThan(fast, crawling)
        // Only a genuinely stopped car sits at the closest zoom: 5 m/s is 18 km/h,
        // which is still a road the driver is reading, not a car park.
        XCTAssertGreaterThan(NavCamera.distance(for: 5), NavCamera.standstillDistance)
        XCTAssertEqual(NavCamera.distance(for: 0), NavCamera.standstillDistance, accuracy: 0.001)
        XCTAssertEqual(NavCamera.distance(for: 500), NavCamera.maximumDistance, accuracy: 0.001)
    }

    // MARK: - Between the fixes

    func testPositionIsExtrapolatedBetweenOneHzFixes() {
        // Without this the camera glides to a halt and lurches forward once a
        // second, which is the single most obvious tell of a naive follow-cam.
        let drifted = NavCamera.carPosition(fix(course: 90, speed: 20, age: 0.5), now: 100)
        XCTAssertGreaterThan(drifted.longitude, cupertino.longitude)
        XCTAssertEqual(GeoMath.distanceMeters(GeoPoint.from(cupertino), GeoPoint.from(drifted)),
                       10, accuracy: 0.2)
    }

    func testExtrapolationIsCappedSoALostFixCannotSendTheCameraAway() {
        // Ten seconds of silence is a lost signal, not ten seconds of driving.
        let stale = NavCamera.carPosition(fix(course: 90, speed: 30, age: 10), now: 100)
        let distance = GeoMath.distanceMeters(GeoPoint.from(cupertino), GeoPoint.from(stale))
        XCTAssertEqual(distance, 30 * NavCamera.maximumDeadReckonSeconds, accuracy: 0.5)
    }

    func testStationaryCarDoesNotDrift() {
        // Dead-reckoning a car that is not moving would walk the map down the
        // road on its own.
        let still = NavCamera.carPosition(fix(course: 90, speed: 0, age: 0.5), now: 100)
        XCTAssertEqual(still.latitude, cupertino.latitude, accuracy: 1e-9)
        XCTAssertEqual(still.longitude, cupertino.longitude, accuracy: 1e-9)
    }

    // MARK: - Getting there smoothly

    func testSmoothingIsFrameRateIndependent() {
        // The same wall-clock second must land in the same place at 30 fps and
        // at 120 fps. A naive `alpha = dt / duration` does not, and drifts
        // further from the target the slower the device is — exactly backwards.
        let from = NavCameraState(center: cupertino, heading: 0, distance: 220)
        let target = (centre: GeoMath.destination(GeoPoint.from(cupertino), 100, 0).clLocation,
                      heading: 90.0, distance: 500.0)

        var quick = from
        for _ in 0..<120 { quick = NavCamera.smoothed(from: quick, towards: target, dt: 1.0 / 120.0) }
        var slow = from
        for _ in 0..<30 { slow = NavCamera.smoothed(from: slow, towards: target, dt: 1.0 / 30.0) }

        XCTAssertEqual(quick.distance, slow.distance, accuracy: 0.5)
        XCTAssertEqual(GeoMath.wrap180(quick.heading - slow.heading).magnitude, 0, accuracy: 0.5)
        XCTAssertEqual(GeoMath.distanceMeters(GeoPoint.from(quick.center), GeoPoint.from(slow.center)),
                       0, accuracy: 0.5)
    }

    func testCameraClosesMostOfTheGapWithinItsTimeConstant() {
        // 0.26 s constant, so after 0.26 s roughly 63% of the gap is gone: close
        // enough to feel attached, far enough that a fix never shows as a jump.
        let from = NavCameraState(center: cupertino, heading: 0, distance: 220)
        let target = (centre: GeoMath.destination(GeoPoint.from(cupertino), 100, 0).clLocation,
                      heading: 0.0, distance: 220.0)
        let after = NavCamera.smoothed(from: from, towards: target,
                                       dt: NavCamera.centreTimeConstant)
        let moved = GeoMath.distanceMeters(GeoPoint.from(cupertino), GeoPoint.from(after.center))
        XCTAssertEqual(moved, 100 * 0.632, accuracy: 1.0)
    }

    func testRotationTakesTheShortWayRound() {
        // 350° to 10° is 20° right, not 340° left. This is the reason the map
        // does not spin through north on every northbound bend.
        let eased = NavCamera.interpolateAngle(350, 10, fraction: 0.5)
        XCTAssertEqual(GeoMath.wrap180(eased - 0).magnitude, 0, accuracy: 0.001)
    }

    func testAHairpinRotatesTheShortWayToo() {
        // Downhill hairpins are the defining corner of a touge, and the camera
        // has to take them at a pace a person can read.
        let eased = NavCamera.interpolateAngle(90, 270, fraction: 0.5)
        XCTAssertEqual(GeoMath.wrap180(eased - 180).magnitude, 0, accuracy: 0.001)
    }

    func testHeadingStaysInZeroToThreeSixty() {
        XCTAssertEqual(NavCamera.interpolateAngle(10, 350, fraction: 1.0), 350, accuracy: 0.001)
        XCTAssertEqual(NavCamera.normalise(-90), 270, accuracy: 0.001)
        XCTAssertEqual(NavCamera.normalise(450), 90, accuracy: 0.001)
    }

    func testZeroTimestepDoesNotDivideByZero() {
        // A display link resuming from the background delivers one frame with no
        // elapsed time; a naive 1 - exp(-0/0) is a NaN that would poison the
        // camera for the rest of the drive.
        let factor = NavCamera.smoothingFactor(dt: 0, timeConstant: NavCamera.centreTimeConstant)
        XCTAssertTrue(factor.isFinite)
        XCTAssertEqual(factor, 0, accuracy: 0.0001)
    }

    // MARK: - The arrow

    func testArrowPointsUpTheScreenInHeadingUp() {
        // The Maps behaviour, and the reason the camera heading is subtracted
        // rather than added: annotation content is laid out on the screen, not
        // turned with the map.
        XCTAssertEqual(NavCamera.puckRotation(bearing: 215, cameraHeading: 215), 0, accuracy: 0.001)
    }

    func testArrowSwingsToTheCarWhenTheMapIsNorthUp() {
        // The driver has spun the map round; the arrow must still say which way
        // the car is actually going.
        XCTAssertEqual(NavCamera.puckRotation(bearing: 90, cameraHeading: 0), 90, accuracy: 0.001)
        XCTAssertEqual(NavCamera.puckRotation(bearing: 270, cameraHeading: 0), -90, accuracy: 0.001)
    }

    func testArrowStaysLevelWhileTheCameraTurnsTowardsTheCar() {
        // Mid-turn the camera has not caught up with the car, and that lag is
        // exactly what makes the arrow read as a car turning rather than a
        // spinning icon.
        let rotation = NavCamera.puckRotation(bearing: 90, cameraHeading: 45)
        XCTAssertEqual(rotation, 45, accuracy: 0.001)
    }

    // MARK: - Following, and letting go of it

    @MainActor
    func testPanningTheMapGivesUpFollowing() {
        let camera = DriveNavigationCamera()
        camera.ingest(fix())
        // The driver drags the map a long way off the car.
        camera.userMovedCamera(to: MapCamera(centerCoordinate: displaced(300),
                                            distance: 900, heading: 12))
        XCTAssertFalse(camera.isFollowing)
    }

    @MainActor
    func testAnOrdinaryCameraMoveIsNotMistakenForAPan() {
        // MapKit settling into the camera we asked for must not read as the
        // driver intervening, or the map quietly stops following itself.
        let camera = DriveNavigationCamera()
        camera.ingest(fix())
        // Echo back the camera the map was actually given — centre, heading and
        // altitude alike. Asserting against a distance the camera never
        // commanded would not be testing the gesture threshold at all; it would
        // be testing a zoom the driver never made.
        let commanded = camera.state
        camera.userMovedCamera(to: MapCamera(centerCoordinate: commanded.center,
                                            distance: commanded.distance,
                                            heading: commanded.heading))
        XCTAssertTrue(camera.isFollowing)
    }

    @MainActor
    func testRecenterPutsTheCameraBackOnTheCarAndKeepsFollowing() {
        // The regression this whole section exists for: Recenter used to restart
        // the display link *after* the link had thrown its frame callback away,
        // so the camera reported itself as following again while nothing could
        // move it. The flag was true and the map was dead.
        let camera = DriveNavigationCamera()
        camera.ingest(fix())
        camera.userMovedCamera(to: MapCamera(centerCoordinate: displaced(300),
                                            distance: 900, heading: 12))
        camera.resumeFollowing()
        XCTAssertTrue(camera.isFollowing)

        // Now deliver frames the way the display link would, through the ticker's
        // own callback. Against a camera whose `stop()` cleared that callback,
        // every one of these is a no-op and the camera stays stranded 300 m away.
        let car = GeoPoint(lon: -122.0090, lat: 37.3349)
        var now: CFTimeInterval = 100
        for _ in 1...240 {
            now += 1.0 / 60.0
            let ahead = GeoMath.destination(car, 20 * (now - 100), 90)
            camera.ingest(NavFix(coordinate: ahead.clLocation, course: 90,
                                 compass: nil, speed: 20, timestamp: now))
            camera.deliverFrame(at: now)
        }

        // Measured against where the car has got to, not where it started. Over
        // four seconds at 20 m/s it is 80 m down the road, so a camera still near
        // the start point would be reporting progress it did not make.
        let carNow = GeoMath.destination(car, 20 * (now - 100), 90)
        let centre = GeoPoint.from(camera.state.center)
        let lag = GeoMath.distanceMeters(centre, carNow)
        // The lead is 12 m at this speed, so the camera is *meant* to sit about
        // that far ahead of the car; what must not happen is the 300 m of
        // separation the pan left behind. Anything under a car's length of
        // lag beyond the lead means the glide has caught up.
        XCTAssertLessThan(lag, NavCamera.leadDistance(speed: 20) + 20,
                          "camera did not glide back to the car after Recenter "
                          + "(lag \(lag) m)")
    }

    private func displaced(_ meters: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(GeoPoint(lon: -122.0090, lat: 37.3349), meters, 0).clLocation
    }
}
