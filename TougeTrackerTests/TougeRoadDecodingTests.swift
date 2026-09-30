import XCTest
import SwiftData
import CoreLocation
@testable import TougeTracker

/// Covers the tolerant `TougeRoad` decoding added for bundled tiles whose
/// `id` is sometimes an Overpass way name rather than a number.
final class TougeRoadDecodingTests: XCTestCase {

    private func road(idJSON: String) -> String {
        """
        {"id": \(idJSON), "name": "Test", "type": "touge",
         "coordinates": [[-71.1, 42.35], [-71.09, 42.36]],
         "lengthMiles": 1.5, "curvatureScore": 70, "flowScore": 60,
         "totalScore": 65, "centerLat": 42.355, "centerLon": -71.095}
        """
    }

    private func decode(_ json: String) throws -> TougeRoad {
        try JSONDecoder().decode(TougeRoad.self, from: Data(json.utf8))
    }

    // MARK: - Numeric and string ids both decode

    func testDecodesNumericID() throws {
        let road = try decode(road(idJSON: "123456"))
        XCTAssertEqual(road.id, 123456)
    }

    func testDecodesStringID() throws {
        let road = try decode(road(idJSON: "\"way-nh-16-pinkham-north\""))
        XCTAssertNotEqual(road.id, 0)
    }

    func testDecodesEveryRoadInRealBostonTile() async throws {
        // Regression guard: one undecodable road used to abort the whole tile.
        let roads = try await LocalRoadSource.shared.fetchRoads(lat: 42.35, lon: -71.1)
        XCTAssertFalse(roads.isEmpty)
        XCTAssertTrue(roads.allSatisfy { $0.id != 0 }, "no road should fall back to id 0")
    }

    func testOtherFieldsDecodeAlongsideStringID() throws {
        let road = try decode(road(idJSON: "\"way-nh-16-pinkham-north\""))
        XCTAssertEqual(road.totalScore, 65)
        XCTAssertEqual(road.curvatureScore, 70)
        XCTAssertEqual(road.lengthMeters, 1.5 * 1609.344, accuracy: 0.001)
        XCTAssertEqual(road.geoPoints.count, 2)
    }

    // MARK: - Id stability (saved routes key off this)

    func testStableIDIsDeterministic() {
        let a = TougeRoad.stableId(from: "way-nh-16-pinkham-north")
        let b = TougeRoad.stableId(from: "way-nh-16-pinkham-north")
        XCTAssertEqual(a, b, "hashing must be deterministic across calls")
    }

    func testStableIDIsAlwaysPositive() {
        for text in ["way-nh-16-pinkham-north", "", "a", "way-ma-2-mashpee", "zzzzzzzz"] {
            XCTAssertGreaterThan(TougeRoad.stableId(from: text), 0, "id for '\(text)' must be positive")
        }
    }

    func testDistinctStringsProduceDistinctIDs() {
        XCTAssertNotEqual(
            TougeRoad.stableId(from: "way-nh-16-pinkham-north"),
            TougeRoad.stableId(from: "way-ma-2-mashpee")
        )
    }

    // MARK: - Codable round-trip (tile cache re-reads encoded roads)

    func testEncodedRoadRoundTripsThroughCache() throws {
        let original = try decode(road(idJSON: "\"way-nh-16-pinkham-north\""))
        let data = try JSONEncoder().encode([original])
        let restored = try JSONDecoder().decode([TougeRoad].self, from: data)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, original.id, "cache round-trip must preserve id")
        XCTAssertEqual(restored[0].geoPoints.count, original.geoPoints.count)
    }

    // MARK: - Saved route persistence

    @MainActor
    private func makeStore(inMemory: Bool) throws -> (RouteStore, ModelContainer) {
        let container = try ModelContainer(
            for: SavedRoute.self, Drive.self, RouteTile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
        return (RouteStore(container: container), container)
    }

    /// Notes that cannot be decoded must be distinguishable from a route that
    /// genuinely has no notes — both used to read as an empty array.
    @MainActor
    func testUnreadablePacenotesAreFlagged() throws {
        let (store, _) = try makeStore(inMemory: true)
        let road = try decode(road(idJSON: "12345"))
        let route = store.saveRoute(road)
        // The fixture road is two points, so it legitimately has no corners.
        // What matters is that a readable (if empty) blob is not flagged.
        XCTAssertFalse(route.pacenotesUnreadable, "freshly saved notes must be readable")

        // Corrupt the stored blob the way a schema change or bad write would.
        route.pacenotesData = Data([0x00, 0x01, 0x02])
        XCTAssertTrue(route.pacenotesUnreadable, "garbage in the note blob must be flagged")
        XCTAssertFalse(route.pacenotesData.isEmpty, "the blob is present, just unreadable")
        XCTAssertTrue(route.pacenotes.isEmpty, "and still yield no notes rather than crashing")
    }

    /// A successful read clears the recorded error, so a store that recovers
    /// does not keep showing a stale failure.
    @MainActor
    func testSuccessfulReadClearsLastError() throws {
        let (store, _) = try makeStore(inMemory: true)
        XCTAssertNil(store.lastError, "a clean read must not report an error")
        _ = store.drives()
        XCTAssertNil(store.lastError)
        _ = store.routes()
        XCTAssertNil(store.lastError)
    }

    /// A route saved from a string-id road must still be found after the store
    /// is reopened, since `SavedRoute.id` is a unique persisted key.
    @MainActor
    func testSavingStringIDRouteReloadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("touge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let storeURL = url.appendingPathComponent("test.store")
        let road = try decode(road(idJSON: "\"way-nh-16-pinkham-north\""))
        let expectedID = road.id

        let container = try ModelContainer(
            for: SavedRoute.self, Drive.self, RouteTile.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let store = RouteStore(container: container)
        store.saveRoute(road)
        XCTAssertTrue(store.isSaved(id: expectedID))

        // Fresh store over the same backing file — simulates a relaunch.
        let reopened = RouteStore(container: try ModelContainer(
            for: SavedRoute.self, Drive.self, RouteTile.self,
            configurations: ModelConfiguration(url: storeURL)
        ))
        let routes = reopened.routes()
        XCTAssertEqual(routes.count, 1, "route should survive a store reopen")
        XCTAssertEqual(routes.first?.id, expectedID)
        XCTAssertTrue(reopened.isSaved(id: expectedID), "isSaved must still match after reopen")
        XCTAssertEqual(routes.first?.coordinates.count, 2)
    }

    @MainActor
    func testIsSavedIsFalseForUnknownID() throws {
        let (store, _) = try makeStore(inMemory: true)
        XCTAssertFalse(store.isSaved(id: 999_999))
    }

    // MARK: - Re-saving the same road must upsert, not violate @unique

    @MainActor
    func testSavingSameRoadTwiceUpsertsInsteadOfDuplicating() throws {
        let (store, _) = try makeStore(inMemory: true)
        let road = try decode(road(idJSON: "987654"))

        let first = store.saveRoute(road)
        // Change the data and save again — the existing row should be updated.
        let renamedJSON = self.road(idJSON: "987654")
            .replacingOccurrences(of: "\"Test\"", with: "\"Renamed\"")
        let renamed = try decode(renamedJSON)
        let second = store.saveRoute(renamed)

        XCTAssertTrue(first === second, "same id must update in place, not insert a second object")
        XCTAssertEqual(store.routes().count, 1, "unique id must not produce a duplicate")
        XCTAssertEqual(store.routes().first?.name, "Renamed", "existing row should pick up the new data")
    }

    @MainActor
    func testSaveRouteReturnsRouteFetchableByID() throws {
        let (store, _) = try makeStore(inMemory: true)
        let road = try decode(road(idJSON: "55555"))
        let saved = store.saveRoute(road)
        XCTAssertEqual(store.route(id: 55555)?.id, saved.id)
        XCTAssertNil(store.route(id: 1), "unrelated id must not resolve")
    }

    // MARK: - Two custom routes must coexist

    /// The regression that motivated this: saving a custom route, then making
    /// and saving a *second* one, left only the second in the store. Save has to
    /// mean the route is kept, not that it is the current selection.
    @MainActor
    func testSavingTwoDifferentCustomRoutesKeepsBoth() throws {
        let (store, _) = try makeStore(inMemory: true)

        let first = try decode(road(idJSON: "111"))
        let second = try decode(road(idJSON: "222"))
        XCTAssertNotEqual(first.id, second.id)

        store.saveRoute(first)
        store.saveRoute(second)

        let routes = store.routes()
        XCTAssertEqual(routes.count, 2, "each save must persist its own route")
        let ids = Set(routes.map(\.id))
        XCTAssertTrue(ids.contains(first.id), "the first route was dropped")
        XCTAssertTrue(ids.contains(second.id), "the second route is missing")
    }

    /// Two different custom routes are the common case once the user can route
    /// any pair of taps, and both carry geometry-derived ids.
    @MainActor
    func testTwoCustomSegmentsFromDifferentGeometryBothPersist() throws {
        let (store, _) = try makeStore(inMemory: true)

        let a = RoadSegmentBuilder.makeRoad(points: (0...5).map {
            GeoPoint(lon: Double($0) * 0.001, lat: 0)
        }, name: "First")
        let b = RoadSegmentBuilder.makeRoad(points: (0...5).map {
            GeoPoint(lon: Double($0) * 0.001, lat: 0.01)
        }, name: "Second")
        XCTAssertNotEqual(a.id, b.id, "distinct geometry must yield distinct ids")

        store.saveRoute(a)
        store.saveRoute(b)

        XCTAssertEqual(store.routes().count, 2)
        XCTAssertTrue(store.isSaved(id: a.id), "the first custom segment vanished")
        XCTAssertTrue(store.isSaved(id: b.id))
    }

    /// Tapping a saved route on the map opens the road preview card, which needs
    /// a `TougeRoad` rebuilt from the stored row. If that loses geometry the
    /// card opens on an empty road, and the hit-test that found it can never
    /// work again.
    @MainActor
    func testSavedRouteRebuildsIntoASelectableRoad() throws {
        let (store, _) = try makeStore(inMemory: true)
        let original = RoadSegmentBuilder.makeRoad(points: (0...10).map {
            GeoPoint(lon: Double($0) * 0.0004, lat: 0.0003)
        }, name: "Tap Me")

        store.saveRoute(original)
        let saved = try XCTUnwrap(store.route(id: original.id))
        let rebuilt = saved.asRoad

        XCTAssertEqual(rebuilt.id, original.id, "id must survive so save state is known")
        XCTAssertEqual(rebuilt.displayName, "Tap Me")
        XCTAssertEqual(rebuilt.geoPoints.count, original.geoPoints.count)
        // The hit-test that selects a saved route snaps onto this geometry, so
        // it has to be a real, tappable polyline.
        let snapped = RoadSegmentBuilder.snap(
            CLLocationCoordinate2D(latitude: 0.0003, longitude: 0.002),
            in: [rebuilt], toleranceMeters: 200)
        XCTAssertNotNil(snapped, "a rebuilt route must be selectable on the map")
    }

    /// A custom route and a tile road must not collide: both would claim the
    /// same slot and one would silently overwrite the other.
    @MainActor
    func testCustomRouteAndTileRoadCoexist() throws {
        let (store, _) = try makeStore(inMemory: true)
        let tile = try decode(road(idJSON: "424242"))
        let custom = RoadSegmentBuilder.makeRoad(points: [
            GeoPoint(lon: 0, lat: 0), GeoPoint(lon: 0.001, lat: 0)
        ], name: "Custom")

        XCTAssertNotEqual(tile.id, custom.id)
        store.saveRoute(tile)
        store.saveRoute(custom)
        XCTAssertEqual(store.routes().count, 2)
        XCTAssertTrue(store.isSaved(id: tile.id))
        XCTAssertTrue(store.isSaved(id: custom.id))
    }

    /// The map draws saved routes from their stored geometry, so that geometry
    /// has to survive the pack/unpack round trip intact. A regression here would
    /// leave saved rows that render as nothing at all.
    @MainActor
    func testSavedRouteKeepsItsGeometryForRedrawing() throws {
        let (store, _) = try makeStore(inMemory: true)
        let road = RoadSegmentBuilder.makeRoad(points: (0...8).map {
            GeoPoint(lon: Double($0) * 0.0005, lat: 0.00025)
        }, name: "Drawn Route")

        store.saveRoute(road)
        let saved = try XCTUnwrap(store.route(id: road.id))
        XCTAssertEqual(saved.coordinates.count, road.geoPoints.count)
        XCTAssertEqual(saved.coordinates.first?.lon ?? .nan, road.geoPoints.first?.lon ?? .nan,
                       accuracy: 1e-9)
        XCTAssertEqual(saved.coordinates.first?.lat ?? .nan, road.geoPoints.first?.lat ?? .nan,
                       accuracy: 1e-9)
        // The centre used to place the label must still be on the geometry.
        XCTAssertGreaterThanOrEqual(saved.coordinates.count, 2)
    }

    // MARK: - Codecs survive a byte-exact, possibly misaligned round trip

    func testTelemetryCodecRoundTrips() {
        let samples = [
            TelemetrySample(t: 0, lat: 42.35, lon: -71.1, speed: 12.5, course: 270,
                            altitude: 30, forwardG: 0.4, lateralG: -0.9, yawRate: 0.12),
            TelemetrySample(t: 1.5, lat: 42.351, lon: -71.099, speed: 13, course: 271,
                            altitude: 31, forwardG: -0.7, lateralG: 0.8, yawRate: -0.2)
        ]
        let restored = TelemetryCodec.unpack(TelemetryCodec.pack(samples))
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored, samples)
    }

    func testCoordinateCodecRoundTrips() {
        let points = [GeoPoint(lon: -71.1, lat: 42.35), GeoPoint(lon: -71.09, lat: 42.36)]
        XCTAssertEqual(CoordinateCodec.unpack(CoordinateCodec.pack(points)), points)
    }

    /// A blob that is not an exact multiple of the stride must decode the whole
    /// prefix rather than reading past the end.
    func testCodecUnpackIgnoresTrailingPartialRecord() {
        let samples = (0 ..< 4).map {
            TelemetrySample(t: Double($0), lat: 42.35, lon: -71.1, speed: Float($0),
                            course: 0, altitude: 0, forwardG: 0, lateralG: 0, yawRate: 0)
        }
        var packed = TelemetryCodec.pack(samples)
        packed.append(contentsOf: [0x01, 0x02, 0x03])   // 3 stray bytes
        XCTAssertEqual(TelemetryCodec.unpack(packed).count, 4)
    }

    func testEmptyCodecInputDecodesToEmpty() {
        XCTAssertTrue(TelemetryCodec.unpack(Data()).isEmpty)
        XCTAssertTrue(CoordinateCodec.unpack(Data()).isEmpty)
    }
}
