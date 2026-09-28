import XCTest
@testable import TougeTracker

final class LocalRoadSourceTests: XCTestCase {

    func testCanLoadBostonTile() async throws {
        // Boston is at lat 42.36, lon -71.06
        // Tile key: t_168_-284 (floor(42.36/0.25)=169... let's check both)
        let roads = try await LocalRoadSource.shared.fetchRoads(lat: 42.35, lon: -71.1)
        // Boston area tiles should have roads
        XCTAssertFalse(roads.isEmpty, "Boston tile should have roads")
    }

    func testCanLoadBoundingBox() async throws {
        // Test fetching roads in a bounding box around Boston
        let roads = try await LocalRoadSource.shared.fetchRoads(
            bbox: (minLat: 42.0, minLon: -71.5, maxLat: 43.0, maxLon: -70.5)
        )
        XCTAssertFalse(roads.isEmpty, "Bounding box around Boston should have roads")
    }
}
