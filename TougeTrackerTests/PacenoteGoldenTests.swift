import XCTest
@testable import TougeTracker

/// Verifies the Swift PacenoteGenerator port produces byte-identical results to
/// Tougefinder's JS implementation (refresh via `node scripts/dump-pacenotes.mjs`).
final class PacenoteGoldenTests: XCTestCase {

    struct Fixture: Decodable {
        let name: String
        let reverse: Bool?
        let format: String?
        let coordinates: [[Double]]
        let expectedText: String
        let expectedTurns: [ExpectedTurn]
    }
    struct ExpectedTurn: Decodable {
        let text: String
        let coordinate: [Double]
    }

    private func loadFixtures() throws -> [Fixture] {
        let url = Bundle(for: PacenoteGoldenTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json")!
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    func testFixturesDecode() throws {
        let f = try loadFixtures()
        XCTAssertEqual(f.count, 16)
        XCTAssertTrue(f.contains { $0.name == "syn_hairpin" })
        XCTAssertTrue(f.contains { $0.name == "db_top_descriptive" })
        XCTAssertTrue(f.contains { $0.name == "syn_zigzag_sharp" })
    }

    func testGeneratorMatchesJS() throws {
        let fixtures = try loadFixtures()
        for f in fixtures {
            let coords = f.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
            let opts = PacenoteOptions(reverse: f.reverse ?? false,
                                       format: PacenoteFormat(rawValue: f.format ?? "rally") ?? .rally)
            let result = PacenoteGenerator.generate(coords, options: opts)

            XCTAssertEqual(result.text, f.expectedText, "Text mismatch for \(f.name)")
            XCTAssertEqual(result.turns.count, f.expectedTurns.count,
                           "Turn count mismatch for \(f.name)")
            for (i, (got, exp)) in zip(result.turns, f.expectedTurns).enumerated() {
                XCTAssertEqual(got.text, exp.text, "Turn \(i) text mismatch for \(f.name) (swift=\(got.text) js=\(exp.text))")
                XCTAssertEqual(got.apex.lon, exp.coordinate[0], accuracy: 1e-7, "Turn \(i) apex lon mismatch for \(f.name)")
                XCTAssertEqual(got.apex.lat, exp.coordinate[1], accuracy: 1e-7, "Turn \(i) apex lat mismatch for \(f.name)")
            }
        }
    }

    func testTooShortRoad() {
        let r = PacenoteGenerator.generate([GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 0, lat: 0.001)])
        XCTAssertEqual(r.text, "Road too short for pacenotes.")
        XCTAssertTrue(r.turns.isEmpty)
    }
}
