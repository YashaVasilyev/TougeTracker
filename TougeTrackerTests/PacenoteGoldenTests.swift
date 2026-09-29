import XCTest
@testable import TougeTracker
import CoreLocation

/// Replays real roads as drives. These are behavioural checks on the whole
/// chain — geometry → pacenotes → navigator timing → spoken words — which the
/// per-unit tests cannot cover together.
final class DriveSimulatorTests: XCTestCase {

    private func loadFixtures() -> [PacenoteGoldenTests.Fixture] {
        let url = Bundle(for: PacenoteGoldenTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json")!
        return (try? JSONDecoder().decode([PacenoteGoldenTests.Fixture].self,
                                          from: Data(contentsOf: url))) ?? []
    }

    private func road(_ name: String) -> [GeoPoint] {
        let f = loadFixtures().first { $0.name == name }
        return (f?.coordinates ?? []).map { GeoPoint(lon: $0[0], lat: $0[1]) }
    }

    func testShortRoadProducesNoCalls() {
        let coords = road("syn_too_short")
        XCTAssertTrue(DriveSimulator().simulate(coordinates: coords).isEmpty)
    }

    func testStraightRoadHasNothingToCall() {
        // A road with no corners must not produce phantom calls.
        let coords = road("syn_straight")
        XCTAssertTrue(DriveSimulator().simulate(coordinates: coords).isEmpty)
    }

    func testStraightIsFoldedIntoTheTurnCallBeforeIt() {
        // A straight is a distance, not a movement, so it belongs to the call
        // for the corner it follows: "six left long, 100".
        //
        // The regression this guards: a call already full of three corners
        // pushed the straight out of the chain, and it was then announced a
        // metre later on its own — a bare number with no corner attached, which
        // is exactly what a co-driver never says.
        let coords = road("db0_105072685_Descente_2")
        let calls = DriveSimulator().simulate(coordinates: coords,
                                              options: .init(speedMps: 45 / 3.6))
        XCTAssertFalse(calls.isEmpty)

        // No call may be nothing but a distance: that is the stranded straight.
        for call in calls {
            let items = call.phrase.split(separator: ", ").map(String.init)
            XCTAssertFalse(items.count == 1 && Int(items[0]) != nil,
                           "straight announced on its own: \(call.phrase)")
        }

        // And the straight really is spoken with the turn that precedes it.
        // The number itself is not asserted: it is the call distance, which
        // moves whenever the ladder is retuned, and pinning it made this test
        // fail for a change it was not written to catch.
        let spoken = calls.map(\.phrase)
        XCTAssertTrue(spoken.contains { phrase in
            let items = phrase.split(separator: ", ")
            return items.count > 1 && Int(items[items.count - 1]) != nil
        }, "the straight after the first run was never attached: \(spoken)")
    }

    func testCallsAdvanceAlongTheRoute() {
        // Calls must be in driving order and never go backwards, or the co-driver
        // would repeat a corner the driver has already passed.
        let coords = road("db1_74432352_School_House_Road")
        let calls = DriveSimulator().simulate(coordinates: coords)
        XCTAssertFalse(calls.isEmpty)
        for (i, call) in calls.enumerated() where i > 0 {
            XCTAssertGreaterThanOrEqual(call.distanceAlong, calls[i - 1].distanceAlong)
            XCTAssertGreaterThanOrEqual(call.seconds, calls[i - 1].seconds)
        }
    }

    func testEveryCornerIsCalledExactlyOnce() {
        // The regression this guards: the note cursor used to park on the first
        // announced note, so every corner after it was silently skipped.
        let coords = road("db1_74432352_School_House_Road")
        let notes = PacenoteGenerator.generate(coords).turns
        guard !notes.isEmpty else { return }

        let calls = DriveSimulator().simulate(coordinates: coords)
        XCTAssertFalse(calls.isEmpty, "a road with corners produced no calls")

        // Calls must reach the last corner. A note is called *before* it is
        // reached — that is the point of a call distance — so the final call
        // sits ahead of the final corner, not past it.
        let total = GeoMath.lengthMeters(coords)
        if let last = calls.last {
            let lastNoteStart = notes.last?.startDist ?? 0
            XCTAssertLessThan(last.distanceAlong, total)
            XCTAssertGreaterThanOrEqual(last.distanceAlong + 400, lastNoteStart,
                                        "calls stopped well before the final corner")
        }
    }

    func testNoCallSpeaksAGradeAsDigits() {
        // "3 L" would be read aloud as "three el". A bare number in a call is a
        // straight's length; anything else numeric would be a grade.
        for name in ["db0_105072685_Descente_2", "db1_74432352_School_House_Road",
                     "syn_hairpin", "syn_zigzag_sharp"] {
            let calls = DriveSimulator().simulate(coordinates: road(name))
            XCTAssertFalse(calls.isEmpty, "\(name) produced no calls")
            for call in calls {
                let items = call.phrase.split(separator: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { Int($0) == nil }   // straight lengths are numbers
                    .joined(separator: " ")
                XCTAssertFalse(items.contains(where: { $0.isNumber }),
                               "\(name): \(call.phrase)")
            }
        }
    }

    func testNoCallStartsWithALeadingDistance() {
        // "190, five right" was said before nearly every corner at speed.
        for name in ["db1_74432352_School_House_Road", "syn_zigzag_sharp"] {
            for call in DriveSimulator().simulate(coordinates: road(name)) {
                let first = call.phrase.split(separator: ", ").first ?? ""
                XCTAssertFalse(first.contains(where: { $0.isNumber }),
                               "\(name): call begins with a distance — \(call.phrase)")
            }
        }
    }

    func testAStraightIsNeverCalledOnItsOwn() {
        // A bare "120" with no context tells the driver nothing. A straight must
        // be announced as part of the call for the turn it follows.
        for name in ["db0_105072685_Descente_2", "db1_74432352_School_House_Road",
                     "syn_hairpin", "syn_zigzag_sharp", "synesses"] {
            let calls = DriveSimulator().simulate(coordinates: road(name))
            for call in calls {
                let parts = call.phrase.split(separator: ", ").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                XCTAssertFalse(parts.count == 1 && Int(parts[0]) != nil,
                               "\(name): a straight was called on its own — \(call.phrase)")
            }
        }
    }

    func testAStraightIsAlwaysTheLastThingInACall() {
        // "five right long, 120" announces the corner and the run that follows.
        // The corner at the far end of that run must not be pulled into the same
        // call — it gets its own, at its own proper distance.
        var sawStraight = false
        for name in ["db0_105072685_Descente_2", "db1_74432352_School_House_Road",
                     "syn_hairpin", "syn_zigzag_sharp"] {
            for call in DriveSimulator().simulate(coordinates: road(name)) {
                let parts = call.phrase.split(separator: ", ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count > 1 else { continue }
                // Index 0 is the leading distance when it is numeric and
                // something else follows it — the call-distance prefix, not a
                // straight.
                let first = Int(parts[0]) != nil ? 1 : 0
                guard let straightAt = parts[first...].firstIndex(where: { Int($0) != nil })
                else { continue }
                sawStraight = true
                XCTAssertEqual(straightAt, parts.count - 1,
                               "\(name): a straight is not last in \(call.phrase)")
            }
        }
        XCTAssertTrue(sawStraight, "fixture roads produced no straights to check")
    }

    func testCloseCallsAreJoinedByAConnector() {
        // Two corners a short distance apart are sometimes announced as separate
        // calls, because the chain only reaches notes that were already imminent.
        // The second call must then open with "into" or "followed by".
        //
        // The transcript alone cannot prove this for any given pair: a note is
        // called before it is reached, so two call sites can sit metres apart
        // while the notes themselves are a long way apart — in which case no
        // connector is correct. So check the two things a transcript can show:
        // the mechanism fires somewhere, and it never fires after a straight.
        var withConnector = 0
        for name in ["db1_74432352_School_House_Road", "syn_zigzag_sharp",
                     "db0_105072685_Descente_2"] {
            let calls = DriveSimulator().simulate(coordinates: road(name))
            XCTAssertFalse(calls.isEmpty, "\(name) produced no calls")
            for (i, call) in calls.enumerated() {
                let opens = call.phrase.hasPrefix("into ")
                        || call.phrase.hasPrefix("followed by ")
                if opens { withConnector += 1 }
                guard i > 0, opens else { continue }
                // A straight already stated the distance, so nothing follows it.
                let previous = calls[i - 1].phrase
                    .split(separator: ", ").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                XCTAssertNil(Int(previous),
                             "\(name): connector after a straight — \(call.phrase)")
            }
        }
        XCTAssertGreaterThan(withConnector, 0,
                             "no call ever opened with a connector")
    }

    func testTranscriptIsReadable() throws {
        let transcript = DriveSimulator().transcript(coordinates: road("db1_74432352_School_House_Road"))
        XCTAssertTrue(transcript.contains("calls"))
        XCTAssertTrue(transcript.contains("00:"), transcript)
    }

    func testSimulationIsDeterministic() {
        let coords = road("syn_zigzag_sharp")
        let a = DriveSimulator().simulate(coordinates: coords)
        let b = DriveSimulator().simulate(coordinates: coords)
        XCTAssertEqual(a.map(\.phrase), b.map(\.phrase))
    }

    func testFasterSpeedDoesNotLoseCorners() {
        // Call distance scales with speed, so a faster pass sees more per call —
        // but it must not skip notes.
        let coords = road("db1_74432352_School_House_Road")
        let slow = DriveSimulator().simulate(coordinates: coords,
                                             options: .init(speedMps: 8))
        let fast = DriveSimulator().simulate(coordinates: coords,
                                             options: .init(speedMps: 30))
        XCTAssertFalse(slow.isEmpty)
        XCTAssertFalse(fast.isEmpty)
        // Faster means the whole route takes less simulated time.
        XCTAssertLessThan(fast.last?.seconds ?? .greatestFiniteMagnitude,
                          slow.last?.seconds ?? 0)
    }
}

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

    /// Pins the pacenote output against this app's own recorded goldens.
    ///
    /// These expectations used to be generated by Tougefinder's JavaScript, so
    /// this compared two implementations. That was the point while this was a
    /// port, and the wrong test afterwards: the two drifted through deliberate
    /// changes on both sides — straights called as a distance, six severity
    /// bands rather than four, connectors spanning separate calls — so the test
    /// reported differences that were never defects.
    ///
    /// What it guards now is that a drive does not change by accident. See
    /// `scripts/dumpgoldens` to regenerate.
    func testGeneratorMatchesGoldens() throws {
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

    func testNoLeadingDistanceIsSpoken() {
        // The navigator already decides when a note is worth calling, and at
        // speed the distance barely changes between corners. Repeating it made
        // the co-driver say "190" before almost every call.
        let call = PacenoteCall(items: [item(note(grade: "1", dir: .right), remaining: 150)])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally), "one right")
    }

    /// The navigator omits the connector after a straight, so the call still has
    /// to read cleanly without one.
    func testCallAfterAStraightNeedsNoConnector() {
        let call = PacenoteCall(items: [
            item(note(grade: "3", dir: .left)),
            item(note(grade: "S", dir: nil, length: 100), connector: nil),
            item(note(grade: "2", dir: .right), connector: nil),
        ])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally),
                       "three left, 100, two right")
    }

    func testIntoStillAppliesBetweenCornersWithNoStraightBetween() {
        // Under 20m the corners are one movement, and that still reads "into".
        let call = PacenoteCall(items: [
            item(note(grade: "3", dir: .left)),
            item(note(grade: "1", dir: .right), connector: "into"),
        ])
        XCTAssertEqual(speaker.phrase(for: call, format: .rally),
                       "three left, into one right")
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

    /// Real road geometry, so gap-based tests do not depend on hand-built
    /// coordinates surviving the smoothing and resampling passes.
    private func loadFixtures() -> [PacenoteGoldenTests.Fixture] {
        let url = Bundle(for: PacenoteGoldenTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json")!
        return (try? JSONDecoder().decode([PacenoteGoldenTests.Fixture].self,
                                          from: Data(contentsOf: url))) ?? []
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

    /// True for a line that is nothing but a distance, e.g. "210m".
    private func isBareDistance(_ line: String) -> Bool {
        guard line.hasSuffix("m") else { return false }
        let digits = line.dropLast()
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    /// A corner with the given start and length, text rendered as the app shows it.
    private func corner(grade: String, dir: PacenoteDirection,
                        start: Double, length: Double) -> Pacenote {
        let isLong = length >= 40 && length < 80
        let isVeryLong = length >= 80
        let apex = GeoPoint(lon: 0, lat: 0)
        let text = PacenoteGenerator.describe(grade: grade, dir: dir, format: .rally,
                                              isLong: isLong, isVeryLong: isVeryLong,
                                              isHairpin: false)
        return Pacenote(grade: grade, direction: dir, startDist: start,
                        endDist: start + length, length: length,
                        isLong: isLong, isVeryLong: isVeryLong, apex: apex, text: text)
    }

    /// The three bands, checked directly on the connector rule rather than
    /// through hand-built road geometry — the 10m resampling and smoothing make
    /// a target gap unreliable to hit by construction.
    func testConnectorBandsAreMeasuredApexToApex() {
        // 40m corners: apex sits 20m past the start.
        let a = corner(grade: "3", dir: .left, start: 0, length: 40)     // apex 20

        let tight = corner(grade: "3", dir: .right, start: 15, length: 40)   // gap 15
        XCTAssertEqual(PacenoteGenerator.connector(from: a, to: tight), "into")

        let medium = corner(grade: "3", dir: .right, start: 50, length: 40)   // gap 35
        XCTAssertEqual(PacenoteGenerator.connector(from: a, to: medium), "followed by")

        let far = corner(grade: "3", dir: .right, start: 120, length: 40)    // gap 100
        XCTAssertNil(PacenoteGenerator.connector(from: a, to: far),
                     "past 50m the straight carries the distance instead")
    }

    func testOnlyRunsOverFiftyMetresBecomeDistanceNotes() {
        // Over 50m the gap is called out as a distance; the corner after it is bare.
        let result = PacenoteGenerator.generate(roadWithLongStraights())
        let lines = result.text.split(separator: "\n").map(String.init)
        for line in lines where isBareDistance(line) {
            let meters = Int(line.dropLast()) ?? -1
            XCTAssertGreaterThanOrEqual(meters, 50,
                                        "a run under 50m should not get a distance note: \(line)")
        }
    }

    func testShortGapsUseInto() {
        let lines = PacenoteGenerator.generate(roadWithLongStraights())
            .text.split(separator: "\n").map(String.init)
        let corners = lines.filter { $0.contains("R") || $0.contains("L") }
        XCTAssertFalse(corners.isEmpty, "fixture produced no corners at all")
        for corner in corners {
            // A corner is introduced by a distance, by "into" when it is part of
            // the same movement, or not at all when a straight already separated
            // it from the last one.
            let ok = corner.range(of: "m:") != nil
                || corner.hasPrefix("into ")
                || !corner.hasPrefix("m") && !corner.contains(":")
            XCTAssertTrue(ok, "unexpected prefix on \(corner)")
        }
        // "and" was replaced by "followed by" back when this format was set up.
        XCTAssertFalse(lines.contains { $0.hasPrefix("and ") })
        // Both connectors can appear on a varied road; each band is covered by
        // its own test below.
        for corner in corners {
            XCTAssertFalse(corner.hasPrefix("into into "), "double connector: \(corner)")
        }
    }

    /// The corner right after a distance note must be bare.
    func testNoConnectorFollowsADistanceNote() {
        let lines = PacenoteGenerator.generate(roadWithLongStraights())
            .text.split(separator: "\n").map(String.init)
        // After a distance note the corner is bare: the number already said it.
        for (i, line) in lines.enumerated() where isBareDistance(line) {
            guard i + 1 < lines.count else { continue }
            let next = lines[i + 1]
            XCTAssertFalse(next.hasPrefix("into "), "connector after a distance: \(next)")
            XCTAssertFalse(next.hasPrefix("followed by "), "connector after a distance: \(next)")
        }
    }

    func testDescriptiveFormatSaysStraight() {
        let result = PacenoteGenerator.generate(roadWithLongStraights(),
                                                options: PacenoteOptions(format: .descriptive))
        let lines = result.text.split(separator: "\n").map(String.init)
        // Same as rally format: a straight is only ever a distance.
        XCTAssertTrue(lines.contains { isBareDistance($0) },
                      "expected a descriptive straight as a distance, got:\n\(result.text)")
        XCTAssertFalse(result.text.contains("Straight "),
                       "descriptive straight should not name itself")
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
