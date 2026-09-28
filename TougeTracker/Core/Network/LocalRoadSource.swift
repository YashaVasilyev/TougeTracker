import Foundation
import CoreLocation

/// Local road data source — loads pre-computed touge road tiles from the app bundle.
/// This replaces the remote Tougefinder API client.
public final class LocalRoadSource: @unchecked Sendable {
    public static let shared = LocalRoadSource()
    private init() {}

    private let decoder = JSONDecoder()

    private func tileKey(lat: Double, lon: Double) -> String {
        let tileSize: Double = 0.25
        let latKey = Int(floor(lat / tileSize))
        let lonKey = Int(floor(lon / tileSize))
        return "t_\(latKey)_\(lonKey)"
    }

    public func fetchRoads(bbox: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)) async throws -> [TougeRoad] {
        let minTileLat = Int(floor(bbox.minLat / 0.25))
        let maxTileLat = Int(floor(bbox.maxLat / 0.25))
        let minTileLon = Int(floor(bbox.minLon / 0.25))
        let maxTileLon = Int(floor(bbox.maxLon / 0.25))

        var results: [TougeRoad] = []
        for tileLat in minTileLat...maxTileLat {
            for tileLon in minTileLon...maxTileLon {
                let lat = Double(tileLat) * 0.25
                let lon = Double(tileLon) * 0.25
                let roads = try await loadTile(key: tileKey(lat: lat, lon: lon))
                results.append(contentsOf: roads)
            }
        }
        return results
    }

    public func fetchRoads(lat: Double, lon: Double) async throws -> [TougeRoad] {
        return try await loadTile(key: tileKey(lat: lat, lon: lon))
    }

    private func loadTile(key: String) async throws -> [TougeRoad] {
        guard let url = Bundle.main.url(forResource: key, withExtension: "json") else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([TougeRoad].self, from: data)
    }
}
