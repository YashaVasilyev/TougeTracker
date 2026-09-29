import XCTest
@testable import TougeTracker

/// Pins the corner-severity ladder.
///
/// The ladder once had four bands (1/3/5/6), so grades 2 and 4 were listed in
/// the severity order and the descriptive map but could never be produced. A
/// driver asking for a tighter corner had no way to say one, and the step
/// between neighbouring severities was a whole grade.
final class SeverityBandTests: XCTestCase {

    // MARK: - The ladder

    /// Every severity must be reachable. This is the regression: with four
    /// bands, 2 and 4 were dead vocabulary.
    func testAllSixSeveritiesAreReachable() {
        let bands = PacenoteGenerator.severityRadiusBands
        XCTAssertEqual(bands.count, 6, "one band per severity")
        for (index, edge) in bands.enumerated() {
            // A radius just inside each band is that band, and only that one.
            let inside = index == 0 ? edge / 2 : (bands[index - 1] + edge) / 2
            XCTAssertEqual(PacenoteGenerator.grade(forRadius: inside), "\(index + 1)",
                           "radius \\(inside) should be severity \\(index + 1)")
        }
    }

    func testWiderThanTheLastBandIsNotACorner() {
        let widest = PacenoteGenerator.severityRadiusBands.last!
        XCTAssertEqual(PacenoteGenerator.grade(forRadius: widest), "S")
        XCTAssertEqual(PacenoteGenerator.grade(forRadius: widest * 10), "S")
    }

    func testBandsAreStrictlyIncreasing() {
        let bands = PacenoteGenerator.severityRadiusBands
        for (a, b) in zip(bands, bands.dropFirst()) {
            XCTAssertLessThan(a, b, "a wider corner must not be called tighter")
        }
    }

    /// A tighter corner must never read milder than a wider one.
    ///
    /// `severity` counts up towards the tight end, so halving the radius must
    /// never lower it — that is what makes the bands ordered rather than merely
    /// adjacent.
    func testSeverityNeverDecreasesWithTighterRadius() {
        var radius = 150.0
        while radius > 0.5 {
            let here = PacenoteGenerator.severity(PacenoteGenerator.grade(forRadius: radius))
            let tighter = PacenoteGenerator.severity(
                PacenoteGenerator.grade(forRadius: radius - 0.5))
            XCTAssertGreaterThanOrEqual(tighter, here, "radius \(radius)")
            radius -= 0.5
        }
    }

    /// The original four boundaries are unchanged, so roads graded under the
    /// old ladder keep their outer edges.
    func testOriginalBoundariesArePreserved() {
        let bands = PacenoteGenerator.severityRadiusBands
        XCTAssertEqual([bands[0], bands[2], bands[4], bands[5]], [20, 50, 80, 150])
    }

    // MARK: - The vocabulary around it

    /// Grades 2 and 4 need a spoken word, a descriptive name and a voice clip.
    func testNewSeveritiesAreSpokenDescribedAndHaveClips() {
        let pack = VoicePack(available: ["Left1", "Left2", "Left3",
                                         "Left4", "Left5", "Left6"])
        // The co-driver speaks words, not digits: "two left", never "2 L".
        XCTAssertEqual(pack.clips(for: "two left"), ["Left2"])
        XCTAssertEqual(pack.clips(for: "four left"), ["Left4"])
        for grade in ["1", "2", "3", "4", "5", "6"] {
            XCTAssertNotNil(PacenoteGenerator.descriptiveMap[grade],
                            "severity \\(grade) has no descriptive name")
        }
    }

    // MARK: - End to end

    /// On real roads the new severities actually come out, not just in theory.
    func testRealFixtureRoadsProduceTheNewSeverities() throws {
        let url = try XCTUnwrap(Bundle(for: SeverityBandTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(
            [PacenoteGoldenTests.Fixture].self, from: Data(contentsOf: url))
        var seen: Set<String> = []
        for f in fixtures {
            let pts = f.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
            for t in PacenoteGenerator.generate(pts).turns { seen.insert(t.grade) }
        }
        XCTAssertTrue(seen.contains("2"), "severity 2 never appears on a real road")
        XCTAssertTrue(seen.contains("4"), "severity 4 never appears on a real road")
    }
}
