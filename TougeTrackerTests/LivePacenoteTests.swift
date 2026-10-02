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

    /// Drives a road from its start at a fixed fix interval, the way the app
    /// does, and collects every call made.
    ///
    /// It does *not* force rebuilds. An earlier version of this helper rebuilt
    /// every third sample "to be like the tick once a window runs low", and it
    /// was nothing like it: the app rebuilds when its own window is nearly spent,
    /// which on these roads is two or three times in a whole drive. Forcing it
    /// rebuilt 22 times on a 346m road and dropped notes the real cadence keeps,
    /// so the tests were measuring a machine the app does not have.
    ///
    /// Fixes are spaced by distance, not per road vertex, for the same reason:
    /// the app gets 10 fixes a second wherever it is, and a fixture's vertices
    /// are as dense or as sparse as the road they came from. Stepping by vertex
    /// made this harness disagree with `simulate-live-drive.sh` on the same road
    /// — thirteen calls against nineteen — while both were faithfully running
    /// the code they were given.
    private func drive(_ source: LivePacenoteSource, coords: [GeoPoint],
                       speed: Double = 80 / 3.6, stopAtMeters: Double? = nil) async -> [PacenoteCall] {
        let total = GeoMath.lengthMeters(coords)
        let step = max(speed * 0.1, 0.5)
        let limit = min(stopAtMeters ?? total, total)
        var calls: [PacenoteCall] = []
        var travelled = 0.0

        while travelled <= limit {
            let here = GeoMath.along(coords, distance: travelled)
            let next = GeoMath.along(coords, distance: min(travelled + step, total))
            let loc = location(here, course: GeoMath.bearing(here, next), speed: speed)
            if let call = source.update(location: loc, speed: speed) { calls.append(call) }
            // `update` schedules its window rebuild as a task, so the drive has
            // to return to the run loop for one to happen — which is what the
            // 20Hz timer does between ticks, and what this loop must do to be
            // the same drive.
            await Task.yield()
            travelled += step
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
        let stop = GeoMath.lengthMeters(coords) / 3
        _ = await drive(source, coords: coords, stopAtMeters: stop)
        let car = GeoMath.along(coords, distance: stop)

        let window = source.routeCoordinates.map(GeoPoint.from)
        XCTAssertFalse(window.isEmpty)
        // What matters about the line the HUD draws is not where it begins -- a
        // window built at the start of a drive begins at the start of the road --
        // but that it still covers the car and reaches well ahead of it.
        let cumulative = GeoMath.cumulativeDistances(window)
        let snap = GeoMath.snapToPolyline(window, cumulative: cumulative, point: car)
        XCTAssertLessThan(snap.perpendicularDistance, 60,
                          "the drawn line no longer covers the car")
        XCTAssertGreaterThan(GeoMath.distanceMeters(car, window.last!), 400,
                             "the drawn line stops short of what the driver can see")
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
        _ = await drive(source, coords: coords, stopAtMeters: GeoMath.lengthMeters(coords) / 3)
        XCTAssertGreaterThanOrEqual(source.windowRevision, 1)
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

    func testAWestboundCourseIsNotMistakenForNoHeading() async {
        // CoreLocation reports 0-360 and -1 for "no heading". A bearing computed
        // from geometry is -180...180, so a road running west arrives as a valid
        // -90. Read as "no heading" it silenced the router, and a free drive on
        // any westbound road produced no pacenotes at all — which is how the
        // replay found it, on the fixture roads that head west out of the origin.
        XCTAssertEqual(LivePacenoteSource.normalizedCourse(-90), 270, accuracy: 0.001)
        XCTAssertEqual(LivePacenoteSource.normalizedCourse(-1), -1,
                       "-1 is CoreLocation's sentinel and must survive as unknown")
        XCTAssertEqual(LivePacenoteSource.normalizedCourse(0), 0)
        XCTAssertEqual(LivePacenoteSource.normalizedCourse(359.5), 359.5, accuracy: 0.001)

        // And end to end: a westbound drive with no tiles must still be called.
        //
        // The line comes back in driving order, as a router returns it, so the
        // fixture road reversed. Handing over the road as stored would leave the
        // car driving off the end of the line it was given, which is a different
        // failure and says nothing about the course.
        let coords = fixtureCoordinates("db1_74432352_School_House_Road")
        let westbound = Array(coords.reversed())
        let westward = RoadSegmentBuilder.makeRoad(points: westbound, name: "Westward")
        let source = routedSource(line: [westward], calls: Counter())
        let calls = await drive(source, coords: westbound)
        XCTAssertFalse(calls.isEmpty, "a westbound free drive was called nothing")
    }

    // MARK: - What the free-drive replay found

    func testTheWindowIsNotRebuiltEveryFewMetres() async {
        // The replay rebuilt the window every four metres of a 346m road: 87
        // windows where there should be two. A window is a kilometre of road, so
        // on a road shorter than that the "nearly spent" test is true from the
        // first fix, and without a floor the whole drive is spent rebuilding.
        let coords = fixtureCoordinates("db0_105072685_Descente_2")
        let source = source(for: [fixtureRoad("db0_105072685_Descente_2")])
        _ = await drive(source, coords: coords)

        XCTAssertLessThanOrEqual(source.windowRevision, 4,
                                 "\(source.windowRevision) windows on a \(Int(GeoMath.lengthMeters(coords)))m road")
    }

    func testAStraightIsNeverCalledOnItsOwnInAFreeDrive() async {
        // A rolling window drops corners it has already called, and a naive dedup
        // orphaned the straight that followed them — "220", said to nobody, forty
        // metres after the corner it belonged to was announced. The planned-drive
        // tests forbid that; the live path has to as well.
        for name in ["db0_105072685_Descente_2", "db1_74432352_School_House_Road",
                     "syn_hairpin", "syn_zigzag_sharp", "synesses"] {
            let source = source(for: [fixtureRoad(name)])
            for call in await drive(source, coords: fixtureCoordinates(name)) {
                let phrase = CoDriverPhrases.phrase(for: call, format: .rally)
                let items = phrase.split(separator: ", ")
                XCTAssertFalse(items.count == 1 && Int(items[0]) != nil,
                               "\(name): a straight was called alone — \(phrase)")
            }
        }
    }

    func testAFreeDriveCallsWhatTheSameRoadWouldCallWhenPlanned() async {
        // The strongest statement available without a car: on a road short
        // enough to be covered by one window, the rolling source must call
        // exactly what handing the same road to the navigator up front would.
        //
        // The long roads are deliberately not here. A kilometre of window gives
        // the generator less context than 15km of road does, and on Clifford
        // Lake — two gentle flats in nearly ten miles — it finds one of the two.
        // Losing a "Flat" is the safe direction to be wrong in; a corner the
        // driver hears late is not.
        for name in ["syn_hairpin", "syn_zigzag_sharp", "synesses", "syn_esses",
                     "syn_squiggle_gentle", "syn_circle_r25", "syn_circle_r100",
                     "db0_105072685_Descente_2", "db1_74432352_School_House_Road"] {
            let coords = fixtureCoordinates(name)
            let planned = DriveSimulator().simulate(coordinates: coords,
                                                     options: .init(speedMps: 80 / 3.6))
            let source = source(for: [fixtureRoad(name)])
            let live = await drive(source, coords: coords)
            // One either way, not none. A rolling window can split a planned
            // call into two -- a straight arriving in the window after the
            // corner it belongs to was called -- and can lose one whose corner
            // fell behind a rebuild. It cannot invent a corner: that is pinned
            // by testEveryCalledCornerIsOneTheGeneratorWouldCall.
            XCTAssertLessThanOrEqual(abs(live.count - planned.count), 1,
                                     "\(name): free drive called \(live.count), planned called \(planned.count)")
        }
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