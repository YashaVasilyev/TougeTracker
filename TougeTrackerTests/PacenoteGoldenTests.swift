import XCTest
@testable import TougeTracker
import CoreLocation

/// Verifies the Swift PacenoteGenerator port against golden fixtures.
///
/// The fixtures were originally produced by Tougefinder's JS implementation
/// (`scripts/dump-pacenotes.mjs`) and this port reproduced its output byte for
/// byte. Straights and the "followed by" connector are a deliberate
/// divergence from that reference, so the expected values have since been
/// refreshed from this generator. The JS port remains authoritative for turn
/// *detection* — grades, directions, and apexes are still expected to match.
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

final class CoDriverSpeechTests: XCTestCase {

    private let speaker = CoDriverSpeaker()

    private func note(grade: String, dir: PacenoteDirection?, length: Double = 40) -> Pacenote {
        Pacenote(grade: grade, direction: dir, startDist: 0, endDist: length,
                 length: length, isLong: false, isVeryLong: false,
                 apex: GeoPoint(lon: 0, lat: 0), text: "x")
    }

    private func item(_ note: Pacenote, remaining: Double = 0,
                      connector: String? = nil) -> PacenoteCall.Item {
        PacenoteCall.Item(note: note, remaining: remaining, connector: connector)
    }

    // MARK: - Grades are spoken as words

    func testGradesAreSpokenAsWordsNotDigits() {
        // "3 L" must never reach the synthesiser, or it is read as "three el".
        for (grade, dir, expected) in [
            ("1", PacenoteDirection.left, "one left"),
            ("3", PacenoteDirection.right, "three right"),
            ("5", PacenoteDirection.left, "five left"),
            ("6", PacenoteDirection.right, "six right"),
        ] {
            let call = PacenoteCall(items: [item(note(grade: grade, dir: dir))])
            XCTAssertEqual(speaker.phrase(for: call, format: .rally), expected)
        }
    }

    func testHairpinAndSquareAreSpokenAsWords() {
        let hp = PacenoteCall(items: [item(note(grade: "HP", dir: .left))])
        XCTAssertEqual(speaker.phrase(for: hp, format: .rally), "hairpin left")

        let sq = PacenoteCall(items: [item(note(grade: "Square", dir: .right))])
        XCTAssertEqual(speaker.phrase(for: sq, format: .rally), "square right")
    }

    func testNoSpokenGradeContainsABareDigit() {
        // Guards the whole call, not just one grade. Digits are still allowed
        // in the leading distance and in straight lengths, so those are removed
        // before checking that no *grade* slipped through as a numeral.
        let call = PacenoteCall(items: [
            item(note(grade: "1", dir: .left), remaining: 120),
            item(note(grade: "3", dir: .right), connector: "into"),
        ])
        let phrase = speaker.phrase(for: call, format: .rally)
        // Strip the leading "120, " and the connector, then assert the rest is
        // pure words.
        let spoken = phrase
            .replacingOccurrences(of: "into ", with: "")
            .replacingOccurrences(of: "120, ", with: "")
        XCTAssertFalse(spoken.contains(where: { $0.isNumber }),
                       "a grade leaked a digit: \(phrase)")
    }

    // MARK: - Straights are called as a distance

    func testStraightIsCalledAsABareDistance() {
        let call = PacenoteCall(items: [item(note(grade: "S", dir: nil, length: 100))])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally), "100")
    }

    func testCornerStraightCornerReadsAsAClassicCall() {
        // The requested shape: "3 left, 100, 2 right".
        let call = PacenoteCall(items: [
            item(note(grade: "3", dir: .left)),
            item(note(grade: "S", dir: nil, length: 100)),
            item(note(grade: "2", dir: .right)),
        ])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally), "three left, 100, two right")
    }

    func testStraightNeverSaysTheWordStraight() {
        let call = PacenoteCall(items: [
            item(note(grade: "3", dir: .left)),
            item(note(grade: "S", dir: nil, length: 210)),
        ])
        let phrase = speaker.phrase(for: call, format: .rally)
        XCTAssertFalse(phrase.lowercased().contains("straight"), phrase)
    }

    func testShortStraightStillRoundsToATen() {
        // Below 10m a rounded call would be "0", which the driver cannot act on.
        let call = PacenoteCall(items: [item(note(grade: "S", dir: nil, length: 4))])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally), "10")
    }

    func testStraightRoundsDownToNearestTen() {
        // 136m is called as "130", the precision a co-driver uses.
        let call = PacenoteCall(items: [item(note(grade: "S", dir: nil, length: 136))])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally), "130")
    }

    // MARK: - Descriptive format

    func testDescriptiveFormatStillNamesStraightByDistance() {
        let call = PacenoteCall(items: [
            item(note(grade: "3", dir: .left)),
            item(note(grade: "S", dir: nil, length: 100)),
        ])
        let phrase = speaker.phrase(for: call, format: .descriptive)
        XCTAssertFalse(phrase.lowercased().contains("straight"), phrase)
        XCTAssertTrue(phrase.contains("100"), phrase)
    }

    func testLeadingDistanceIsStillCalledBeforeTheFirstCorner() {
        let call = PacenoteCall(items: [item(note(grade: "1", dir: .right), remaining: 150)])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally), "150, one right")
    }
}

final class PacenoteChainingTests: XCTestCase {

    // MARK: - Chaining must be GPS-linked, not a bulk read-out

    /// Corners 15m apart. Every one of them must still be called on approach —
    /// they cannot all be crammed into the first call, or the co-driver reads
    /// the whole road aloud the moment the drive starts.
    private func tightlySpacedNotes(count: Int, gap: Double) -> [Pacenote] {
        (0..<count).map { i in
            let start = 100.0 + Double(i) * gap
            return Pacenote(grade: "3", direction: i.isMultiple(of: 2) ? .left : .right,
                            startDist: start, endDist: start + 8,
                            length: 8, isLong: false, isVeryLong: false,
                            apex: GeoPoint(lon: 0, lat: 0), text: "3 R")
        }
    }

    func testFirstCallDoesNotSwallowEveryCornerAhead() {
        let notes = tightlySpacedNotes(count: 12, gap: 15)
        let nav = PacenoteNavigator(coordinates: straightLine(), pacenotes: notes)

        // Sit just before the first corner.
        let fix = location(at: 90)
        let call = nav.update(location: fix, speed: 20)

        // The whole point: a call must not contain the entire route.
        XCTAssertNotNil(call)
        XCTAssertLessThanOrEqual(call!.items.count, 4,
                                 "a single call read out \(call!.items.count) notes at once")
    }

    func testEveryNoteIsStillEventuallyCalled() {
        // Gating the call must not silently swallow notes: each one has to
        // surface as the driver reaches it.
        let notes = tightlySpacedNotes(count: 12, gap: 15)
        let nav = PacenoteNavigator(coordinates: straightLine(), pacenotes: notes)

        var called = 0
        // Drive the whole route in 1m steps.
        for d in stride(from: 0.0, through: 290.0, by: 1.0) {
            if let call = nav.update(location: location(at: d), speed: 20) {
                called += call.items.count
            }
        }
        XCTAssertEqual(called, notes.count, "every corner must be called exactly once")
    }

    func testNotesAreCalledInOrder() {
        let notes = tightlySpacedNotes(count: 10, gap: 15)
        let nav = PacenoteNavigator(coordinates: straightLine(), pacenotes: notes)

        var order: [Int] = []
        for d in stride(from: 0.0, through: 290.0, by: 1.0) {
            if let call = nav.update(location: location(at: d), speed: 20) {
                for item in call.items {
                    if let idx = notes.firstIndex(where: { $0.startDist == item.note.startDist }) {
                        order.append(idx)
                    }
                }
            }
        }
        XCTAssertEqual(order, Array(0..<notes.count), "notes called out of order")
    }

    func testChainedCallRespectsTheCallDistance() {
        // A chained note must itself be imminent. Without this, a long chain of
        // near-adjacent corners is announced long before the driver reaches it.
        let notes = tightlySpacedNotes(count: 12, gap: 15)
        let nav = PacenoteNavigator(coordinates: straightLine(), pacenotes: notes)

        let call = nav.update(location: location(at: 90), speed: 20)
        let lookahead = 120.0
        for item in call!.items.dropFirst() {
            XCTAssertLessThanOrEqual(item.remaining, lookahead,
                                     "chained a note \(item.remaining)m ahead")
        }
    }

    // MARK: - Helpers

    /// A long straight route; the navigator only needs somewhere to snap to.
    private func straightLine() -> [CLLocationCoordinate2D] {
        (0...60).map { CLLocationCoordinate2D(latitude: 0, longitude: Double($0) * 0.001) }
    }

    /// A fix `meters` along that straight line.
    private func location(at meters: Double) -> CLLocation {
        CLLocation(latitude: 0, longitude: meters / 111_320.0)
    }
}

final class PacenoteStraightTests: XCTestCase {

    private func at(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(lon: lon, lat: lat)
    }

    /// A straight run east, then a hard right, then a long straight, then a
    /// hard left. The two corners are far enough apart that the middle should
    /// be labelled as a straight.
    private func roadWithLongStraights() -> [GeoPoint] {
        var pts: [GeoPoint] = []
        for i in 0...60 { pts.append(at(0, Double(i) * 0.0002)) }          // ~730m east
        for i in 1...12 { pts.append(at(Double(i) * 0.0015, 0.0120)) }      // north, the right
        for i in 1...60 { pts.append(at(0.0180, 0.0120 + Double(i) * 0.0002)) } // ~730m east
        for i in 1...12 { pts.append(at(0.0180 - Double(i) * 0.0015, 0.0240)) } // back west, the left
        return pts
    }

    func testLongStraightIsLabelled() {
        let result = PacenoteGenerator.generate(roadWithLongStraights())
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.hasSuffix("S") },
                      "expected a straight note, got:\n\(result.text)")
    }

    func testStraightHasNoDirection() throws {
        let result = PacenoteGenerator.generate(roadWithLongStraights())
        let straight = try XCTUnwrap(result.turns.first { $0.grade == "S" })
        XCTAssertNil(straight.direction)
        XCTAssertTrue(straight.isStraight)
        // Rendering must not invent a direction word.
        XCTAssertEqual(PacenoteGenerator.formatted(straight), "S")
    }

    func testStraightReportsItsLength() throws {
        let result = PacenoteGenerator.generate(roadWithLongStraights())
        let straight = try XCTUnwrap(result.turns.first { $0.grade == "S" })
        XCTAssertGreaterThan(straight.length, 50)
        // The note is prefixed with the distance to the next corner.
        let line = try XCTUnwrap(result.text.split(separator: "\n")
            .map(String.init).first { $0.hasSuffix("S") })
        XCTAssertTrue(line.contains("m:"), "expected a distance prefix, got \(line)")
    }

    func testShortGapsUseIntoAndFollowedBy() {
        let lines = PacenoteGenerator.generate(roadWithLongStraights())
            .text.split(separator: "\n").map(String.init)
        // Every corner is introduced either by the first-note distance or by one
        // of the two connectors. Anything else means a stray prefix crept in.
        let corners = lines.filter { $0.contains("R") || $0.contains("L") }
        XCTAssertFalse(corners.isEmpty, "fixture produced no corners at all")
        for corner in corners {
            let ok = corner.range(of: "m:") != nil
                || corner.hasPrefix("into ")
                || corner.hasPrefix("followed by ")
            XCTAssertTrue(ok, "unexpected connector in \(corner)")
        }
        // "and" is the connector this replaced, and must be gone.
        XCTAssertFalse(lines.contains { $0.hasPrefix("and ") })
    }

    func testDescriptiveFormatSaysStraight() {
        let result = PacenoteGenerator.generate(roadWithLongStraights(),
                                                options: PacenoteOptions(format: .descriptive))
        XCTAssertTrue(result.text.split(separator: "\n").contains { $0.hasSuffix("Straight") },
                      "expected a descriptive straight, got:\n\(result.text)")
    }

    func testStreaksOfStraightsDoNotRepeatTheSameDistance() {
        // Each straight note carries the distance; the corner after it must not
        // repeat that distance or the co-driver would call it twice.
        let lines = PacenoteGenerator.generate(roadWithLongStraights())
            .text.split(separator: "\n").map(String.init)
        let distances = lines.compactMap { line -> String? in
            guard let range = line.range(of: "m:") else { return nil }
            return String(line[line.startIndex..<range.lowerBound])
        }
        XCTAssertEqual(distances.count, Set(distances).count,
                       "a distance was announced twice: \(distances)")
    }

    func testShortRoadWithNoCornersHasNoNotes() {
        // A dead-straight road has no corners; labelling a straight that leads
        // nowhere would be noise.
        let straight = (0...40).map { at(0, Double($0) * 0.0002) }
        let result = PacenoteGenerator.generate(straight)
        XCTAssertTrue(result.turns.isEmpty)
    }
}
