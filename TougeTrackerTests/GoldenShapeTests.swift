import XCTest
@testable import TougeTracker
import CoreLocation

/// The two newest golden shapes actually reach the code they were written for.
///
/// Both were originally built with a *constant* heading, which is a straight
/// line with a kink rather than an arc. The generator was right to call them
/// straights, and nothing said otherwise: the fixtures decoded, the suite went
/// green, and two features sat unexercised while looking tested.
final class GoldenShapeTests: XCTestCase {

    private func coordinates(_ name: String) throws -> [GeoPoint] {
        let url = try XCTUnwrap(Bundle(for: GoldenShapeTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(
            [PacenoteGoldenTests.Fixture].self, from: Data(contentsOf: url))
        let fixture = try XCTUnwrap(fixtures.first { $0.name == name })
        return fixture.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
    }

    /// A 240m-radius arc is inside the Flat band, and must be called one.
    func testTheFlatFixtureProducesAFlatCorner() throws {
        let notes = PacenoteGenerator.generate(try coordinates("syn_flat_bend")).turns
        XCTAssertTrue(notes.contains { $0.grade == "Flat" },
                      "no flat corner: \(notes.map(\.text))")
    }

    /// A corner whose radius falls by a factor of ten must be called as tightening.
    func testTheTighteningFixtureProducesATightensCall() throws {
        let notes = PacenoteGenerator.generate(try coordinates("syn_tightening")).turns
        XCTAssertTrue(notes.contains { $0.trend == .tightens },
                      "no tightening corner: \(notes.map(\.text))")
    }

    /// And the word reaches the written note, not only the model.
    func testTheTighteningCallIsSpelledOut() throws {
        let notes = PacenoteGenerator.generate(try coordinates("syn_tightening")).turns
        let text = PacenoteGenerator.renderedList(notes, format: .rally).joined(separator: " ")
        XCTAssertTrue(text.contains("tightens"), text)
    }
}
