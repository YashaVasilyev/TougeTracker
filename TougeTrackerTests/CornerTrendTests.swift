import XCTest
@testable import TougeTracker

/// Pins the tightens/opens detector.
///
/// The thresholds are measured, not chosen. Over the real road set a ratio of
/// end-radius to start-radius is a smooth continuum centred on 1.00, and a 25%
/// band either side of that fires on 20% of corners. Fitting a line to
/// log(radius) along the corner is what separates them.
final class CornerTrendTests: XCTestCase {

    /// A corner that tightens as it goes: straight in, a progressively tighter
    /// bend, then away.
    private func roadTightening() -> [GeoPoint] {
        var points: [GeoPoint] = []
        let origin = GeoPoint(lon: -71.0, lat: 42.0)
        // Straight approach.
        for i in 0...20 { points.append(GeoMath.destination(origin, Double(i) * 10, 0)) }
        // The corner, tightening exponentially. Radius is the reciprocal of the
        // turn rate, so a turn rate that merely *increases* makes the radius
        // fall as 1/x and the log-radius curve comes out concave — which the
        // fit rightly rejects. A road that tightens tightens geometrically, and
        // that is what makes log-radius a straight line.
        var bearing = 0.0
        for i in 1...40 {
            bearing += 0.5 * pow(1.06, Double(i))
            points.append(GeoMath.destination(points.last!, 5, bearing))
        }
        // Straight away.
        for i in 1...20 {
            points.append(GeoMath.destination(points.last!, 10, bearing))
        }
        return points
    }

    func testATighteningCornerIsCalledTightens() {
        let road = roadTightening()
        XCTAssertEqual(CornerTrendDetector.trend(along: road, from: 200, to: 400), .tightens)
    }

    func testAShallowCornerIsNotCalled() {
        // Under the length floor there is no signal to find, and guessing at one
        // is worse than saying nothing.
        XCTAssertEqual(CornerTrendDetector.trend(along: roadTightening(), from: 200, to: 215), .none)
    }

    func testAStraightHasNoTrend() {
        var points: [GeoPoint] = []
        for i in 0...60 { points.append(GeoMath.destination(GeoPoint(lon: -71, lat: 42), Double(i) * 10, 0)) }
        XCTAssertEqual(CornerTrendDetector.trend(along: points, from: 0, to: 600), .none)
    }

    func testTooFewPointsIsNotCalled() {
        XCTAssertEqual(CornerTrendDetector.trend(along: [GeoPoint(lon: -71, lat: 42)], from: 0, to: 100), .none)
    }

    /// The word a co-driver uses, and nothing for a straight.
    func testSpelling() {
        XCTAssertEqual(CornerTrend.tightens.word, " tightens")
        XCTAssertEqual(CornerTrend.opens.word, " opens")
        XCTAssertEqual(CornerTrend.none.word, "")
    }

    /// A saved route written before this existed must still load.
    func testDecodesNotesSavedBeforeTrendsExisted() throws {
        let json = """
        {"grade":"3","direction":"R","startDist":0,"endDist":40,"length":40,
         "isLong":false,"isVeryLong":false,"apex":{"lat":42.0,"lon":-71.0},"text":"3 R"}
        """
        let note = try JSONDecoder().decode(Pacenote.self, from: Data(json.utf8))
        XCTAssertEqual(note.trend, .none)
        XCTAssertEqual(note.text, "3 R")
    }

    func testRoundTripsATrend() throws {
        var note = Pacenote(grade: "3", direction: .right, startDist: 0, endDist: 40,
                            length: 40, isLong: false, isVeryLong: false,
                            apex: GeoPoint(lon: -71, lat: 42), text: "3 R",
                            trend: .opens)
        let data = try JSONEncoder().encode(note)
        note = try JSONDecoder().decode(Pacenote.self, from: data)
        XCTAssertEqual(note.trend, .opens)
    }

    /// The pack stitches the corner clip and the trend clip into one call.
    func testVoiceStitchesCornerAndTrend() {
        let pack = VoicePack(available: ["Left3", "Long", "Tightens", "Opens"])
        XCTAssertEqual(pack.clips(for: "three left long tightens"), ["Left3", "Long", "Tightens"])
        XCTAssertEqual(pack.clips(for: "two right opens"), [],
                       "no Right2 clip, so the call is left to the system voice")
        let pack2 = VoicePack(available: ["Right2", "Opens"])
        XCTAssertEqual(pack2.clips(for: "two right opens"), ["Right2", "Opens"])
    }
}
