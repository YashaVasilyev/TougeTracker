import XCTest
@testable import TougeTracker
import CoreLocation

final class RoadSegmentBuilderTests: XCTestCase {

    /// A straight west-to-east road along the equator. 0.001° of longitude at the
    /// equator is ~111.19m, so consecutive vertices are ~111m apart. Coordinates
    /// are GeoJSON-ordered `[lon, lat]`.
    private func straightRoad() -> TougeRoad {
        let coords = (0...10).map { [Double($0) * 0.001, 0.0] }
        return TougeRoad(id: 1, name: "Straight", type: "road", coordinates: coords,
                         lengthMiles: 1.0, curvatureScore: 50, flowScore: 50,
                         totalScore: 50, centerLat: 0, centerLon: 0.005)
    }

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Snapping

    func testSnapLandsOnNearestGeometry() throws {
        // ~20m north of the road's midpoint; well within tolerance.
        let road = straightRoad()
        let s = RoadSegmentBuilder.snap(at(0.00018, 0.005), in: [road], toleranceMeters: 50)
        XCTAssertNotNil(s)
        // Snapped onto the road itself, not left floating at the tap.
        XCTAssertEqual(s!.point.lat, 0, accuracy: 1e-9)
        XCTAssertEqual(s!.road.id, road.id)
    }

    func testSnapRejectsPointBeyondTolerance() throws {
        XCTAssertNil(RoadSegmentBuilder.snap(at(0.5, 0.5), in: [straightRoad()], toleranceMeters: 50))
    }

    func testSnapPrefersTheCloserOfTwoOverlappingRoads() throws {
        let near = straightRoad()                                            // lat 0
        let far = TougeRoad(id: 2, name: "Far", type: "road",
                            coordinates: (0...10).map { [Double($0) * 0.001, 0.0005] },
                            lengthMiles: 1, curvatureScore: nil, flowScore: nil, totalScore: nil,
                            centerLat: 0.0005, centerLon: 0.005)
        // 10m north of `near`, ~45m south of `far`.
        let s = RoadSegmentBuilder.snap(at(0.00009, 0.005), in: [far, near], toleranceMeters: 100)
        XCTAssertEqual(s?.road.id, near.id)
    }

    // MARK: - Extraction

    func testExtractKeepsTapOrder() throws {
        let road = straightRoad()
        let a = RoadSegmentBuilder.snap(at(0, 0.001), in: [road], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0, 0.004), in: [road], toleranceMeters: 50)!
        let pts = try RoadSegmentBuilder.extract(from: a, to: b)
        // Running west→east, so longitude must increase.
        XCTAssertEqual(pts.first!.lon, 0.001, accuracy: 1e-6)
        XCTAssertEqual(pts.last!.lon, 0.004, accuracy: 1e-6)
    }

    func testExtractReversesWhenTapsAreInReverseOrder() throws {
        let road = straightRoad()
        let a = RoadSegmentBuilder.snap(at(0, 0.001), in: [road], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0, 0.004), in: [road], toleranceMeters: 50)!
        let forward = try RoadSegmentBuilder.extract(from: a, to: b)
        let reversed = try RoadSegmentBuilder.extract(from: b, to: a)
        XCTAssertEqual(forward, reversed.reversed())
    }

    func testExtractRejectsTapsOnDifferentRoads() throws {
        let one = straightRoad()
        let two = TougeRoad(id: 2, name: "Other", type: "road",
                            coordinates: [[0, 0.5], [0.01, 0.5]],
                            lengthMiles: nil, curvatureScore: nil, flowScore: nil,
                            totalScore: nil, centerLat: 0.5, centerLon: 0)
        let a = RoadSegmentBuilder.snap(at(0, 0.001), in: [one], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0.5, 0.005), in: [two], toleranceMeters: 50)!
        XCTAssertThrowsError(try RoadSegmentBuilder.extract(from: a, to: b)) {
            XCTAssertEqual($0 as? RoadSegmentBuilder.Failure, .differentRoads)
        }
    }

    /// Regression: taps landing exactly on vertices must not cause the vertex to
    /// be emitted twice (which showed up as a repeated trailing point and
    /// corrupted the reversed direction).
    func testExtractWithTapsExactlyOnVertices() throws {
        let road = straightRoad()
        let a = RoadSegmentBuilder.snap(at(0, 0.001), in: [road], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0, 0.004), in: [road], toleranceMeters: 50)!
        let forward = try RoadSegmentBuilder.extract(from: a, to: b)
        let reversed = try RoadSegmentBuilder.extract(from: b, to: a)
        XCTAssertEqual(forward.count, 4)              // 0.001, 0.002, 0.003, 0.004
        XCTAssertEqual(forward, reversed.reversed())
    }

    func testExtractDoesNotEmitZeroLengthSegments() throws {
        // Both taps on the same segment at its endpoints — the exact case that
        // would otherwise produce a duplicated vertex.
        let road = straightRoad()
        let a = RoadSegmentBuilder.snap(at(0, 0), in: [road], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0, 0.001), in: [road], toleranceMeters: 50)!
        let pts = try RoadSegmentBuilder.extract(from: a, to: b)
        for i in 0..<(pts.count - 1) {
            XCTAssertGreaterThan(GeoMath.distanceMeters(pts[i], pts[i + 1]), 0.5)
        }
    }

    // MARK: - Distance-based stretch

    /// The live pacenote source asks for "this bit of this road" by distance
    /// rather than by tap. It has to behave like `extract`, and it has to stop
    /// at the ends of the road rather than invent a point past them.
    func testStretchBetweenDistancesMatchesExtract() throws {
        let road = straightRoad()   // 10 vertices, ~111m apart, ~1.1km long
        let a = RoadSegmentBuilder.snap(at(0, 0.001), in: [road], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0, 0.004), in: [road], toleranceMeters: 50)!
        let tapped = try RoadSegmentBuilder.extract(from: a, to: b)
        let byDistance = RoadSegmentBuilder.stretch(of: road, from: a.distanceAlongRoad,
                                                    to: b.distanceAlongRoad, forward: true)
        XCTAssertEqual(tapped.map(\.lon), byDistance?.map(\.lon))
    }

    func testStretchIsClampedToTheEndsOfTheRoad() throws {
        let road = straightRoad()
        let total = GeoMath.lengthMeters(road.geoPoints)
        // A window that runs off both ends comes back the whole road, not the
        // road plus a fabricated stretch beyond it.
        let whole = RoadSegmentBuilder.stretch(of: road, from: -500, to: total + 500,
                                               forward: true)
        XCTAssertEqual(whole?.first?.lon, road.geoPoints.first?.lon)
        XCTAssertEqual(whole?.last?.lon, road.geoPoints.last?.lon)
    }

    func testStretchReversesForTheOtherDirection() throws {
        let road = straightRoad()
        let a = RoadSegmentBuilder.snap(at(0, 0.001), in: [road], toleranceMeters: 50)!
        let b = RoadSegmentBuilder.snap(at(0, 0.004), in: [road], toleranceMeters: 50)!
        let forward = RoadSegmentBuilder.stretch(of: road, from: a.distanceAlongRoad,
                                                 to: b.distanceAlongRoad, forward: true)!
        let backward = RoadSegmentBuilder.stretch(of: road, from: a.distanceAlongRoad,
                                                  to: b.distanceAlongRoad, forward: false)!
        XCTAssertEqual(forward, backward.reversed())
    }

    func testStretchWithNoLengthIsRejected() throws {
        XCTAssertNil(RoadSegmentBuilder.stretch(of: straightRoad(), from: 500, to: 500,
                                                 forward: true))
    }

    // MARK: - Length

    func testBuiltRoadCarriesMeasuredLength() throws {
        let road = straightRoad()
        let seg = try RoadSegmentBuilder.makeRoad(start: at(0, 0.001), end: at(0, 0.004),
                                                 in: [road], toleranceMeters: 50)
        // Three 0.001° gaps ≈ 3 × 111.19m.
        XCTAssertEqual(seg.lengthMeters, 333.6, accuracy: 2)
        // 1.6km in miles, matching how tile roads express length.
        XCTAssertEqual(seg.lengthMiles!, 0.2072, accuracy: 0.002)
        XCTAssertEqual(seg.type, "segment")
    }

    func testBuiltRoadHasNoScores() throws {
        // A hand-drawn segment is unranked, so it must not borrow a tile road's
        // score — that would make it indistinguishable from ranked data.
        let seg = try RoadSegmentBuilder.makeRoad(start: at(0, 0.001), end: at(0, 0.004),
                                                  in: [straightRoad()], toleranceMeters: 50)
        XCTAssertNil(seg.totalScore)
        XCTAssertNil(seg.curvatureScore)
    }

    func testSameGeometryYieldsStableId() throws {
        let a = try RoadSegmentBuilder.makeRoad(start: at(0, 0.001), end: at(0, 0.004),
                                                in: [straightRoad()], toleranceMeters: 50)
        let b = try RoadSegmentBuilder.makeRoad(start: at(0, 0.001), end: at(0, 0.004),
                                                in: [straightRoad()], toleranceMeters: 50)
        XCTAssertEqual(a.id, b.id)
        // Must be positive for the SwiftData unique constraint.
        XCTAssertGreaterThan(a.id, 0)
    }

    func testSegmentIdDoesNotCollideWithTileRoadIds() throws {
        let seg = try RoadSegmentBuilder.makeRoad(start: at(0, 0.001), end: at(0, 0.004),
                                                  in: [straightRoad()], toleranceMeters: 50)
        // Tile ids are the raw FNV hash; segments are OR'd with a high bit.
        XCTAssertNotEqual(TougeRoad.stableId(from: "segment:x"), seg.id)
    }

    func testBuiltRoadFeedsPacenoteGenerator() throws {
        // The whole point: a segment drops straight into the existing pipeline.
        let seg = try RoadSegmentBuilder.makeRoad(start: at(0, 0.001), end: at(0, 0.004),
                                                  in: [straightRoad()], toleranceMeters: 50)
        let result = PacenoteGenerator.generate(seg.geoPoints)
        // A dead-straight road has no corners, so no turns — but it must not crash.
        XCTAssertTrue(result.turns.isEmpty)
    }
}
