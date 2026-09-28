import XCTest
@testable import TougeTracker
import CoreLocation

/// The zoom-out crash: a wide view spans many tiles, and the uncapped overlay
/// list overwhelmed MapKit. These pin the budget that prevents it.
final class RenderBudgetTests: XCTestCase {

    private func road(id: Int64, score: Int, points: Int) -> TougeRoad {
        TougeRoad(
            id: id, name: "R\(id)", type: "road",
            coordinates: (0..<points).map { [Double($0) * 0.001, 0] },
            lengthMiles: 1, curvatureScore: score, flowScore: score,
            totalScore: score, centerLat: 0, centerLon: 0
        )
    }

    // MARK: - Road cap

    func testZoomedInKeepsEveryRoad() {
        // Street zoom must be untouched — this is what you drive from.
        let roads = (0..<40).map { road(id: Int64($0), score: 50, points: 30) }
        XCTAssertEqual(RenderBudget.roads(roads, spanDegrees: 0.1).count, 40)
    }

    func testZoomedOutCapsTheRoadCount() {
        // The crash case: hundreds of overlays is what MapKit cannot hold.
        let roads = (0..<800).map { road(id: Int64($0), score: $0, points: 30) }
        let capped = RenderBudget.roads(roads, spanDegrees: 4)
        XCTAssertEqual(capped.count, RenderBudget.maxRoads)
    }

    func testCapKeepsTheBestScoringRoads() {
        // A zoomed-out map should still show the good roads, not an arbitrary
        // prefix of whatever the tiles happened to list first.
        let roads = (0..<400).map { road(id: Int64($0), score: $0, points: 10) }
        let capped = RenderBudget.roads(roads, spanDegrees: 4)
        let scores = capped.compactMap { $0.totalScore }.sorted()
        XCTAssertEqual(scores.last, 399, "the top-scoring road must survive the cap")
        XCTAssertEqual(scores.first, 400 - RenderBudget.maxRoads)
    }

    // MARK: - Point budget

    func testPointBudgetIsUnlimitedWhenZoomedIn() {
        XCTAssertEqual(RenderBudget.maxPoints(spanDegrees: 0.2), Int.max)
    }

    func testPointBudgetTightensAsYouZoomOut() {
        let near = RenderBudget.maxPoints(spanDegrees: 0.4)
        let far = RenderBudget.maxPoints(spanDegrees: 1.5)
        XCTAssertLessThan(far, near, "more zoomed out must mean fewer vertices")
        XCTAssertGreaterThanOrEqual(near, RenderBudget.maxPointsPerRoad)
        XCTAssertGreaterThanOrEqual(far, 2)
    }

    func testPointBudgetIsMonotonic() {
        var last = Int.max
        for span in stride(from: 0.25, through: 8.0, by: 0.25) {
            let budget = RenderBudget.maxPoints(spanDegrees: span)
            XCTAssertLessThanOrEqual(budget, last, "budget grew at span \(span)")
            last = budget
        }
    }
}

final class PolylineSimplifierTests: XCTestCase {

    /// A straight east-bound line: 0.0005° per step is ~55m.
    private func line(count: Int) -> [GeoPoint] {
        (0..<count).map { GeoPoint(lon: Double($0) * 0.0005, lat: 0) }
    }

    func testShortPolylineIsUntouched() {
        let points = line(count: 20)
        XCTAssertEqual(PolylineSimplifier.thin(points, maxPoints: 50,
                                              minSpacingMeters: 1).count, 20)
    }

    func testThinningRespectsTheBudget() {
        let points = line(count: 500)
        let out = PolylineSimplifier.thin(points, maxPoints: 24, minSpacingMeters: 50)
        XCTAssertLessThanOrEqual(out.count, 24)
        XCTAssertGreaterThanOrEqual(out.count, 2, "a road must keep at least two points")
    }

    func testThinningKeepsBothEndpoints() {
        // Otherwise the drawn line stops short of where the road actually goes.
        let points = line(count: 500)
        let out = PolylineSimplifier.thin(points, maxPoints: 24, minSpacingMeters: 50)
        XCTAssertEqual(out.first?.lon, points.first?.lon)
        XCTAssertEqual(out.last?.lon, points.last?.lon)
    }

    func testThinningAlwaysMeetsTheBudget() {
        // The pathological case that motivated the per-road cap: one very long
        // road among many short ones.
        for spacing in [0.1, 1.0, 25.0, 200.0, 5000.0] {
            let points = line(count: 2000)
            let out = PolylineSimplifier.thin(points, maxPoints: 24,
                                              minSpacingMeters: spacing)
            XCTAssertLessThanOrEqual(out.count, 24, "budget missed at spacing \(spacing)")
        }
    }

    func testThinningPreservesTheShapeOfASwitchback() {
        // Radial decimation must keep alternating corners; a naive every-Nth
        // stride would collapse these and straighten the hairpin.
        var points: [GeoPoint] = []
        for i in 0..<200 {
            let lat = (i.isMultiple(of: 2) ? 1.0 : -1.0) * 0.0005
            points.append(GeoPoint(lon: Double(i) * 0.0005, lat: lat))
        }
        let out = PolylineSimplifier.thin(points, maxPoints: 40, minSpacingMeters: 1)
        let swingsBothWays = out.contains { $0.lat > 0 } && out.contains { $0.lat < 0 }
        XCTAssertTrue(swingsBothWays, "the switchback was flattened")
    }

    func testThinningDoesNotAddOrReorderPoints() {
        let points = line(count: 300)
        let out = PolylineSimplifier.thin(points, maxPoints: 20, minSpacingMeters: 10)
        for (i, p) in out.enumerated() {
            XCTAssertGreaterThanOrEqual(p.lon, out[max(0, i - 1)].lon,
                                       "points must stay in travel order")
        }
        XCTAssertLessThanOrEqual(out.count, points.count)
    }
}

/// Verifies the Swift PacenoteGenerator port against golden fixtures.
///
/// The fixtures were originally produced by Tougefinder's JS implementation
/// (`scripts/dump-pacenotes.mjs`) and this port reproduced its output byte for
/// byte. Straights and the "followed by" connector are a deliberate
/// divergence from that reference, so the expected values have since been
/// refreshed from this generator. The JS port remains authoritative for turn
/// *detection* — grades, directions, and apexes are still expected to match.
