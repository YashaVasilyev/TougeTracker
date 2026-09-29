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

    /// Loads one tile.
    ///
    /// The bundled tiles are gzipped and rounded to 1m — see
    /// `scripts/compile-road-tiles.py`, which cuts the road data from 166MB to
    /// 43MB with no visible change. The plain `.json` is still accepted so a
    /// build made straight from the source tiles, or a test fixture, works
    /// unchanged.
    private func loadTile(key: String) async throws -> [TougeRoad] {
        // The name and extension are split because `withExtension: "json.gz"`
        // does not match a file whose name ends ".json.gz" — it looks for a
        // literal extension of that whole string, finds nothing, and the map
        // silently comes up empty.
        if let url = Bundle.main.url(forResource: key + ".json", withExtension: "z"),
           let decompressed = Self.inflate(try Data(contentsOf: url)) {
            return try decoder.decode([TougeRoad].self, from: decompressed)
        }
        guard let url = Bundle.main.url(forResource: key, withExtension: "json") else {
            return []
        }
        return try decoder.decode([TougeRoad].self, from: Data(contentsOf: url))
    }

    /// Inflates a deflate-compressed tile, or returns nil if it is not one.
    ///
    /// Tiles are read lazily as the map pans, so this sits on the path to every
    /// tile. A corrupt or truncated file returns nil and the caller falls back,
    /// rather than throwing and blanking the map.
    private static func inflate(_ data: Data) -> Data? {
        // No magic-byte check: the format is bare deflate, so there is no
        // header to recognise, and guessing one already cost a build. Try to
        // inflate and let the caller fall back to the plain tile if it fails.
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
