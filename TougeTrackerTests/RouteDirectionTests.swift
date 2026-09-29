import XCTest
@testable import TougeTracker
import CoreLocation

/// Covers reversing a road and reading its direction — the two things the
/// preview and detail panels show.
final class RouteDirectionTests: XCTestCase {

    /// A short leg running north-east: latitude and longitude both increase.
    private func northEastRoad(id: Int64 = 1) -> TougeRoad {
        TougeRoad(id: id, name: "Test", type: "route",
                  coordinates: [[-71.100, 42.350], [-71.090, 42.360]],
                  lengthMiles: 1, curvatureScore: nil, flowScore: nil,
                  totalScore: nil, centerLat: 42.355, centerLon: -71.095)
    }

    // MARK: - Compass points

    func testCompassPointsUseEightSectors() {
        let expected: [(Double, String)] = [
            (0, "N"), (22.4, "N"), (22.6, "NE"), (45, "NE"),
            (67.4, "NE"), (67.6, "E"), (90, "E"),
            (180, "S"), (270, "W"), (359, "N"),
            // The wrap: due north expressed as -90.
            (-90, "W"), (-180, "S"),
        ]
        for (bearing, point) in expected {
            XCTAssertEqual(RouteDirection.compassPoint(for: bearing), point,
                           "bearing \(bearing)")
        }
    }

    func testDirectionReadsBearingFromTheGeometry() {
        let direction = northEastRoad().direction
        XCTAssertTrue(direction.isKnown)
        XCTAssertEqual(direction.compass, "NE")
        XCTAssertEqual(direction.start?.lat, 42.350)
        XCTAssertEqual(direction.end?.lat, 42.360)
    }

    func testDirectionIsUnknownWithoutEnoughGeometry() {
        // A single point has no direction, and the panels must not claim one.
        let single = TougeRoad(id: 2, name: nil, type: nil,
                               coordinates: [[-71.1, 42.35]],
                               lengthMiles: 0, curvatureScore: nil, flowScore: nil,
                               totalScore: nil, centerLat: 42.35, centerLon: -71.1)
        XCTAssertFalse(single.direction.isKnown)
        XCTAssertEqual(single.direction.compass, "")
    }

    func testReversedCompassIsTheOppositeBearing() {
        let direction = northEastRoad().direction
        XCTAssertEqual(direction.reversedCompass, "SW")
    }

    // MARK: - Reversal

    func testReversingFlipsTheGeometry() {
        let road = northEastRoad()
        let flipped = road.reversed()
        XCTAssertEqual(flipped.coordinates.first, road.coordinates.last)
        XCTAssertEqual(flipped.coordinates.last, road.coordinates.first)
        XCTAssertEqual(flipped.coordinates.count, road.coordinates.count)
    }

    func testReversingKeepsTheIdentityAndTheMeasurements() {
        // It is the same road driven the other way, so it must keep its id —
        // otherwise saving a reversed road files a second copy of the same
        // stretch of tarmac.
        let road = northEastRoad(id: 4242)
        let flipped = road.reversed()
        XCTAssertEqual(flipped.id, 4242)
        XCTAssertEqual(flipped.lengthMeters, road.lengthMeters, accuracy: 0.001)
        XCTAssertEqual(flipped.displayName, road.displayName)
        XCTAssertEqual(flipped.centerLat, road.centerLat)
    }

    func testReversedRoadPointsTheOppositeWay() {
        XCTAssertEqual(northEastRoad().reversed().direction.compass, "SW")
    }

    func testReversingTwiceIsTheOriginal() {
        let road = northEastRoad()
        XCTAssertEqual(road.reversed().reversed().coordinates, road.coordinates)
    }

    func testReversingASinglePointRoadIsHarmless() {
        let single = TougeRoad(id: 3, name: nil, type: nil,
                               coordinates: [[-71.1, 42.35]],
                               lengthMiles: 0, curvatureScore: nil, flowScore: nil,
                               totalScore: nil, centerLat: 42.35, centerLon: -71.1)
        XCTAssertEqual(single.reversed().coordinates, single.coordinates)
    }

    /// Reversing must hand the route back the other way round: the last corner
    /// driven one way is the first corner driven the other, with its handedness
    /// flipped. That is the property the panels and the pacenotes rely on.
    ///
    /// It is deliberately *not* asserted note-for-note. Two things stop that
    /// from being true, and both are pre-existing properties of
    /// `PacenoteGenerator` rather than anything reversal introduces:
    ///
    ///  * Some passes run in one direction — the grade-6 squiggle sweep and the
    ///    50m straight/corner split — so a run sitting on one of those
    ///    thresholds is called as a corner one way and a straight the other.
    ///    That moves a note or two on four of the sixteen fixture roads.
    ///  * A symmetric road genuinely reads identically either way, so "reversing
    ///    changed the notes" is false for one fixture by construction.
    ///
    /// The generator is therefore not exactly reversible. Closing that gap means
    /// making those passes order-independent, which is a change to the note
    /// output for every road and is not something to do quietly.
    func testReversalCorrespondsAtTheEnds() throws {
        let url = try XCTUnwrap(Bundle(for: RouteDirectionTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(
            [PacenoteGoldenTests.Fixture].self, from: Data(contentsOf: url))
        var checked = 0

        for fixture in fixtures {
            let coords = fixture.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
            guard coords.count > 2 else { continue }
            let forward = PacenoteGenerator.generate(coords).turns
            guard let firstNote = forward.first, let lastNote = forward.last,
                  forward.count >= 2 else { continue }
            let backward = PacenoteGenerator.generate(coords.reversed()).turns
            guard let reverseFirst = backward.first, let reverseLast = backward.last else {
                XCTFail("\(fixture.name): reversing produced no notes")
                continue
            }

            XCTAssertEqual(reverseFirst.text, mirror(lastNote.text),
                           "\(fixture.name): the reverse should open on the mirrored end")
            XCTAssertEqual(reverseLast.text, mirror(firstNote.text),
                           "\(fixture.name): the reverse should close on the mirrored start")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no fixture produced enough notes to check")
    }

    /// Flips every "L" to "R" and back, leaving everything else alone.
    private func mirror(_ text: String) -> String {
        text.replacingOccurrences(of: "L", with: "\u{0}")
            .replacingOccurrences(of: "R", with: "L")
            .replacingOccurrences(of: "\u{0}", with: "R")
    }
}
