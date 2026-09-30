import XCTest
@testable import TougeTracker
import CoreLocation

/// The rules behind multi-point routing, which until now were reachable only
/// by driving the interface. There are no UI tests in the project, so this is
/// the only thing standing behind the newest routing features.
final class RouteBuilderTests: XCTestCase {

    private let start = CLLocationCoordinate2D(latitude: 42.0, longitude: -71.0)

    private func place(_ metresEast: Double, _ metresNorth: Double) -> CLLocationCoordinate2D {
        GeoMath.destination(GeoPoint(lon: -71.0, lat: 42.0),
                            metresEast, metresNorth).clLocation
    }

    func testPointsAccumulateInOrder() {
        let b = RouteBuilder()
        XCTAssertTrue(b.add(start))
        XCTAssertTrue(b.add(place(500, 0)))
        XCTAssertTrue(b.add(place(500, 500)))
        XCTAssertEqual(b.points.count, 3)
    }

    /// The rule that keeps a double-tap from becoming an unroutable leg.
    func testATapOnTopOfTheLastIsRefused() {
        let b = RouteBuilder()
        b.add(start)
        XCTAssertFalse(b.add(place(5, 0)), "5m away is the same point")
        XCTAssertEqual(b.points.count, 1)
        XCTAssertNotNil(b.error)
    }

    func testAPointJustFarEnoughIsAccepted() {
        let b = RouteBuilder()
        b.add(start)
        XCTAssertTrue(b.add(place(30, 0)), "30m is a real second point")
    }

    func testRoutingNeedsTwoPoints() {
        let b = RouteBuilder()
        XCTAssertNil(b.routable)
        b.add(start)
        XCTAssertNil(b.routable)
        b.add(place(400, 0))
        XCTAssertNotNil(b.routable)
    }

    func testUndoRemovesTheLastPointAndClearsTheError() {
        let b = RouteBuilder()
        b.add(start)
        b.add(place(5, 0))          // refused, so the error is showing
        XCTAssertNotNil(b.error)
        b.add(place(400, 0))
        b.undo()
        XCTAssertEqual(b.points.count, 1)
        XCTAssertNil(b.error)
    }

    /// The same road driven the other way, without re-tapping every point.
    func testReverseSwapsStartAndFinish() {
        let b = RouteBuilder()
        b.add(start)
        b.add(place(400, 0))
        b.add(place(400, 400))
        b.reverse()
        XCTAssertEqual(b.points.first?.latitude, place(400, 400).latitude)
        XCTAssertEqual(b.points.last?.latitude ?? .nan, start.latitude, accuracy: 0.0001)
    }

    func testReverseDoesNothingWithFewerThanTwoPoints() {
        let b = RouteBuilder()
        b.add(start)
        b.reverse()
        XCTAssertEqual(b.points.count, 1)
    }

    func testClearEmptiesEverything() {
        let b = RouteBuilder()
        b.add(start)
        b.add(place(400, 0))
        b.clear()
        XCTAssertTrue(b.isEmpty)
        XCTAssertFalse(b.canRoute)
    }

    /// The pins say which end is which, which with three or more points is the
    /// whole question.
    func testPointLabels() {
        let b = RouteBuilder()
        b.add(start)
        b.add(place(400, 0))
        b.add(place(800, 0))
        XCTAssertEqual(b.label(for: 0), "Start")
        XCTAssertEqual(b.label(for: 1), "Stop 1")
        XCTAssertEqual(b.label(for: 2), "Finish")
        XCTAssertTrue(b.isFirst(0))
        XCTAssertTrue(b.isLast(2))
        XCTAssertFalse(b.isLast(0))
    }
}
