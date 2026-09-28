import XCTest
@testable import TougeTracker
import CoreLocation

final class GeoMathTests: XCTestCase {

    private let earthR = 6371008.8

    func testHaversineOneDegreeLatitude() {
        // 1 degree of latitude ≈ 111.1949 km (haversine, R = 6371008.8 m).
        let p1 = GeoPoint(lon: 0, lat: 0)
        let p2 = GeoPoint(lon: 0, lat: 1)
        let d = GeoMath.distanceMeters(p1, p2)
        XCTAssertEqual(d, .pi / 180 * earthR, accuracy: 1)
    }

    func testHaversineIsSymmetric() {
        let a = GeoPoint(lon: 2.1, lat: 3.4)
        let b = GeoPoint(lon: -4.5, lat: 6.7)
        XCTAssertEqual(GeoMath.distanceMeters(a, b), GeoMath.distanceMeters(b, a), accuracy: 1e-3)
    }

    func testBearingCardinalDirections() {
        XCTAssertEqual(GeoMath.bearing(GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 0, lat: 1)), 0, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearing(GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 1, lat: 0)), 90, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearing(GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 0, lat: -1)), 180, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearing(GeoPoint(lon: 0, lat: 0), GeoPoint(lon: -1, lat: 0)), -90, accuracy: 1e-9)
    }

    func testDestinationRoundTrip() {
        let origin = GeoPoint(lon: 2.35, lat: 48.85)
        let target = GeoMath.destination(origin, 1000, 45)     // 1 km northeast
        let back = GeoMath.bearing(target, origin)
        XCTAssertEqual(back, -135, accuracy: 0.01)            // opposite bearing (spherical deviation ~0.007° at lat 49)
    }

    func testDestination1000mEast() {
        let origin = GeoPoint(lon: 0, lat: 0)
        let target = GeoMath.destination(origin, 1000, 90)    // 1 km due east
        XCTAssertEqual(target.lon, 1000 / (earthR * .pi / 180), accuracy: 1e-6)
        XCTAssertEqual(target.lat, 0, accuracy: 1e-9)
    }

    func testCircumradiusCollinearIsInfinity() {
        let p1 = GeoPoint(lon: 0, lat: 0)
        let p2 = GeoPoint(lon: 0, lat: 0.01)
        let p3 = GeoPoint(lon: 0, lat: 0.02)
        XCTAssertEqual(GeoMath.circumRadiusMeters(p1, p2, p3), .infinity)
    }

    func testCircumradiusKnownValue() {
        // Equilateral triangle, 50 m sides → circumradius = side / √3 ≈ 28.87 m.
        let o = GeoPoint(lon: 0, lat: 0)
        let a = GeoMath.destination(o, 50, 0)
        let b = GeoMath.destination(o, 50, 60)
        let r = GeoMath.circumRadiusMeters(o, a, b)
        XCTAssertEqual(r, 50 / sqrt(3), accuracy: 0.5)
    }

    func testChaikinSmoothingGrowsPoints() {
        let pts = (0..<5).map { GeoPoint(lon: Double($0), lat: Double($0)) }
        let smooth = GeoMath.chaikinSmooth(pts, iterations: 2)
        XCTAssertEqual(smooth.count, 20) // 5 → 10 → 20 (Chaikin: 2n per iteration)
        XCTAssertEqual(smooth.first, pts.first)
        XCTAssertEqual(smooth.last, pts.last)
    }

    func testAlongInterpolatesToEndpoint() {
        let p1 = GeoPoint(lon: 0, lat: 0)
        let p2 = GeoPoint(lon: 0.001, lat: 0)                // ~69 m east
        let total = GeoMath.distanceMeters(p1, p2)
        let mid = GeoMath.along([p1, p2], distance: total / 2)
        XCTAssertEqual(GeoMath.distanceMeters(p1, mid), total / 2, accuracy: 0.01)
    }
}
