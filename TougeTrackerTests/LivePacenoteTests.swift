import XCTest
@testable import TougeTracker
import CoreLocation

/// Live pacenotes for a drive with no route: the same generator, navigator and
/// call text as a planned drive, fed a road window discovered from the tiles
/// instead of a route the user picked.
///
/// Driven on the real fixture roads, because the claim being tested is that the
/// live path produces the pipeline's own notes and not a simplified cousin of
/// them.
@MainActor
final class LivePacenoteTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixture: Decodable {
        let name: String
        let coordinates: [[Double]]
    }

    private func fixtureCoordinates(_ name: String) -> [GeoPoint] {
        let url = Bundle(for: LivePacenoteTests.self)
            .url(forResource: "pacenote_fixtures", withExtension: "json")!
        let all = (try? JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))) ?? []
        let found = all.first { $0.name == name }
        return (found?.coordinates ?? []).map { GeoPoint(lon: $0[0], lat: $0[1]) }
    }

    /// The fixture road as a tile would carry it.
    private func fixtureRoad(_ name: String) -> TougeRoad {
        let coords = fixtureCoordinates(name)
        return TougeRoad(id: 1, name: name, type: "road",
                         coordinates: coords.map { [$0.lon, $0.lat] },
                         lengthMiles: GeoMath.lengthMeters(coords) / 1609.344,
                         curvatureScore: nil, flowScore: nil, totalScore: nil,
                         centerLat: 0, centerLon: 0)
    }

    /// A source whose road lookup always answers with the same roads.
    private func source(for roads: [TougeRoad],
                        callDistanceScale: Double = 1.0) -> LivePacenoteSource {
        LivePacenoteSource(loader: { _ in roads }, callDistanceScale: callDistanceScale)
    }

    private func location(_ p: GeoPoint, course: Double, speed: Double = 20) -> CLLocation {
        CLLocation(coordinate: p.clLocation, altitude: 0, horizontalAccuracy: 5,
                   verticalAccuracy: 5, course: course, speed: speed, timestamp: Date())
    }

    /// Drives a road from its start, feeding every fix and forcing a rebuild
    /// every few samples the way the tick does once a window runs low. Collects
    /// every call made.
    private func drive(_ source: LivePacenoteSource, coords: [GeoPoint],
                       speed: Double = 20, stopAfter: Int? = nil) async -> [PacenoteCall] {
        var calls: [PacenoteCall] = []
        let route = coords.enumerated().prefix(stopAfter ?? coords.count)
        for (i, p) in route {
            let course = i + 1 < coords.count
                ? GeoMath.bearing(p, coords[i + 1]) : GeoMath.bearing(coords[i - 1], p)
            let loc = location(p, course: course, speed: speed)
            if let call = source.update(location: loc, speed: speed) { calls.append(call) }
            if i % 3 == 0 { _ = await source.rebuild(at: loc) }
            // `rebuild` returns without suspending when a build is already in
            // flight, and `update`'s own rebuild runs as a task. Yielding here is
            // what lets those land, standing in for the run loop that does it
            // between ticks in the app.
            await Task.yield()
        }
        return calls
    }

    // MARK: - The window

    func testWindowNotesAreTheGeneratorsOwnNotesForThatStretch() throws {
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let road = fixtureRoad("db1_74432352_School_House_Road")
        let start = coords[0]

        let window = LivePacenoteSource.window(
            at: start.clLocation,
            course: GeoMath.bearing(start, coords[min(3, coords.count - 1)]),
            roads: [road], lookaheadMeters: 400)

        XCTAssertNotNil(window)
        // The whole point of the feature: the notes are what the generator
        // produces for this geometry, verbatim.
        let expected = PacenoteGenerator.generate(coords).turns.map(\.text)
        XCTAssertEqual(window!.pacenotes.map(\.text),
                       Array(expected.prefix(window!.pacenotes.count)))
    }

    func testWindowIsRejectedWhereNoKnownRoadIs() {
        // A car on a road the tiles do not carry: mid-ocean, nowhere near the
        // fixture. It must build nothing rather than call corners for a road
        // nobody is on.
        XCTAssertNil(LivePacenoteSource.window(
            at: CLLocationCoordinate2D(latitude: 0.0, longitude: -30.0),
            course: 90, roads: [fixtureRoad("db1_74432352_School_House_Road")],
            lookaheadMeters: 1000))
    }

    func testWindowIsOrientedByTheHeadingTheCarIsTravelling() throws {
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let road = fixtureRoad("db1_74432352_School_House_Road")
        let start = coords[0]
        let heading = GeoMath.bearing(start, coords[4])

        let forward = LivePacenoteSource.window(
            at: start.clLocation, course: heading, roads: [road], lookaheadMeters: 300)
        let backward = LivePacenoteSource.window(
            at: start.clLocation, course: heading + 180, roads: [road], lookaheadMeters: 300)

        XCTAssertNotNil(forward)
        XCTAssertNotNil(backward)
        // A window that ignored the heading would face the same way twice.
        let a = forward!.coordinates.first!
        let b = backward!.coordinates.first!
        XCTAssertGreaterThan(GeoMath.distanceMeters(GeoPoint.from(a), GeoPoint.from(b)), 5)
    }

    // MARK: - Calling

    func testAFreeDriveGetsCalledOnARealRoad() async {
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let calls = await drive(source(for: [fixtureRoad("db1_74432352_School_House_Road")]),
                                coords: coords)
        XCTAssertFalse(calls.isEmpty,
                       "a free drive over a road with corners produced no calls")
    }

    func testEveryCalledCornerIsOneTheGeneratorWouldCall() async {
        // The live path must not invent notes: everything it says has to be in
        // the generator's own output for that road.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let source = source(for: [fixtureRoad("db1_74432352_School_House_Road")])
        let calls = await drive(source, coords: coords)
        let generated = PacenoteGenerator.generate(coords).turns

        for call in calls {
            for item in call.items where !item.note.isStraight {
                let near = generated.contains { GeoMath.distanceMeters($0.apex, item.note.apex) < 20 }
                XCTAssertTrue(near, "called a corner the generator never produced: \(item.note.text)")
            }
        }
    }

    func testRebuildingNeverAnnouncesTheSameCornerTwice() async {
        // A rebuild regenerates everything inside its overlap with the window it
        // replaces. Without the apex filter the co-driver says "three left" twice
        // for one corner, and a driver who hears that once stops trusting it.
        let coords = fixtureCoordinates("db2_863398308_Clifford_Lake_Road")
        let source = source(for: [fixtureRoad("db2_863398308_Clifford_Lake_Road")])
        let calls = await drive(source, coords: coords)
        XCTAssertGreaterThanOrEqual(source.windowRevision, 2,
                                    "the drive never rebuilt a window — nothing was tested")

        var apexes: [GeoPoint] = []
        for call in calls {
            for item in call.items {
                XCTAssertFalse(
                    apexes.contains { GeoMath.distanceMeters($0, item.note.apex) < 20 },
                    "announced twice: \(item.note.text)")
                apexes.append(item.note.apex)
            }
        }
    }

    func testTheWindowFollowsTheCar() async {
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let source = source(for: [fixtureRoad("db1_74432352_School_House_Road")])
        // Stop while there is still road ahead: at the end of a road there is no
        // window to build, and this is about where the line sits, not about the
        // end of the data.
        let stop = coords.count / 3
        _ = await drive(source, coords: coords, stopAfter: stop)
        let car = coords[stop - 1]

        let window = source.routeCoordinates.map(GeoPoint.from)
        XCTAssertFalse(window.isEmpty)
        // The line the HUD draws starts at the car and runs away from it.
        XCTAssertLessThan(GeoMath.distanceMeters(window.first!, car), 120)
        XCTAssertGreaterThan(GeoMath.lengthMeters(window), 400)
    }

    // MARK: - Roads the tiles do not carry

    /// Counts router calls, so an assertion can hold a reference to the same box
    /// the loader writes to.
    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    /// A source whose tiles are empty and whose router answers with `line`.
    private func routedSource(line: [TougeRoad], calls: Counter) -> LivePacenoteSource {
        LivePacenoteSource(loader: { _ in [] },
                           lineLoader: { _, _, _ in calls.bump(); return line })
    }

    func testARoutedLineIsWindowedAndCalled() async {
        // The road the car is on is in no tile — the case that used to be
        // silence. The routed line goes through the same window code.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let source = routedSource(line: [fixtureRoad("db1_74432352_School_House_Road")],
                                  calls: Counter())

        let calls = await drive(source, coords: coords)
        XCTAssertTrue(source.isActive, "a routed line produced no window")
        XCTAssertFalse(calls.isEmpty, "a free drive over a routed road produced no calls")
    }

    func testTheRouterIsNotAskedWhenTheTilesHaveTheRoad() async {
        // The tiles are on the phone and free. A drive on a scored road must not
        // spend a request per window on a public demo server.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let road = fixtureRoad("db1_74432352_School_House_Road")
        let calls = Counter()
        let source = LivePacenoteSource(loader: { _ in [road] },
                                        lineLoader: { _, _, _ in calls.bump(); return [road] })

        // Stop well short of the end: running out of tiled road is exactly when the
        // router *should* be asked, so this only measures the part of the drive
        // where the tiles still have road ahead.
        _ = await drive(source, coords: coords, stopAfter: coords.count / 3)
        XCTAssertGreaterThan(source.windowRevision, 1)
        XCTAssertEqual(calls.value, 0, "the router was asked on a road the tiles carry")
    }

    func testTheRouterIsAskedWhenTheTilesRunOut() async {
        // The other half of that rule: at the end of a scored road the tiles have
        // nothing ahead, and that is precisely when a request is worth making —
        // the road almost certainly continues.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let road = fixtureRoad("db1_74432352_School_House_Road")
        let calls = Counter()
        let source = LivePacenoteSource(loader: { _ in [road] },
                                        lineLoader: { _, _, _ in calls.bump(); return [road] })

        let last = coords[coords.count - 1]
        let course = GeoMath.bearing(coords[coords.count - 2], last)
        _ = await source.rebuild(at: location(last, course: course))
        XCTAssertEqual(calls.value, 1, "running out of tiled road did not reach the router")
    }

    func testTheRouterIsRateLimitedBetweenWindows() async {
        // Two rebuilds a few metres apart are one ask, not two: this runs inside
        // a 20Hz recorder.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let calls = Counter()
        let source = routedSource(line: [fixtureRoad("db1_74432352_School_House_Road")],
                                  calls: calls)

        _ = await source.rebuild(at: location(coords[0],
                                               course: GeoMath.bearing(coords[0], coords[1])))
        _ = await source.rebuild(at: location(coords[1],
                                               course: GeoMath.bearing(coords[1], coords[2])))
        XCTAssertEqual(calls.value, 1,
                       "the router was asked twice without the car covering any ground")
    }

    func testAnEmptyRoutedLineIsNotSpammed() async {
        // No signal in a canyon: the router keeps saying nothing and the source
        // must not keep knocking.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let calls = Counter()
        let source = routedSource(line: [], calls: calls)

        _ = await source.rebuild(at: location(coords[0],
                                               course: GeoMath.bearing(coords[0], coords[1])))
        XCTAssertFalse(source.isActive)
        XCTAssertEqual(calls.value, 1)

        for p in coords.dropFirst() {
            _ = await source.rebuild(at: location(p, course: 90))
        }
        XCTAssertEqual(calls.value, 1, "the router was retried while backing off")
    }

    func testNoHeadingMeansNoRouterCall() async {
        // A fix with no course has no "ahead" to route to, and asking anyway
        // would aim the line in an arbitrary direction.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let calls = Counter()
        let source = routedSource(line: [fixtureRoad("db1_74432352_School_House_Road")],
                                  calls: calls)
        let blind = CLLocation(coordinate: coords[0].clLocation, altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: -1, speed: 0, timestamp: Date())
        let built = await source.rebuild(at: blind)
        XCTAssertFalse(built)
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: - Not calling

    func testNothingIsCalledWhereNoKnownRoadIs() async {
        let source = source(for: [fixtureRoad("db1_74432352_School_House_Road")])
        let out = CLLocationCoordinate2D(latitude: 0.0, longitude: -30.0)
        let loc = CLLocation(coordinate: out, altitude: 0, horizontalAccuracy: 5,
                             verticalAccuracy: 5, course: 90, speed: 20, timestamp: Date())
        let built = await source.rebuild(at: loc)
        XCTAssertFalse(built)
        XCTAssertNil(source.update(location: loc, speed: 20))
        XCTAssertTrue(source.upcoming(count: 3).isEmpty)
        XCTAssertFalse(source.isActive)
    }

    func testAStraightRoadIsCalledNothing() async {
        // A road with no corners must not produce phantom calls — the same
        // property the planned-route tests hold for it.
        let source = source(for: [fixtureRoad("syn_straight")])
        let calls = await drive(source, coords: fixtureCoordinates("syn_straight"))
        XCTAssertTrue(calls.isEmpty)
    }
}