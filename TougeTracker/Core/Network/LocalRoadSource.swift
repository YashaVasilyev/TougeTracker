import Foundation
import CoreLocation

/// Local road data source — loads pre-computed touge road tiles from the app bundle.
/// This replaces the remote Tougefinder API client.
public final class LocalRoadSource: @unchecked Sendable {
    public static let shared = LocalRoadSource()
    public init() {}

    private let decoder = JSONDecoder()

    /// Decoded tiles, most recently used last.
    ///
    /// A tile costs a read from the bundle, an inflate and a JSON decode, and the
    /// map asks for every tile in view on every camera settle. Without this,
    /// panning back over ground already seen paid all three again — the debounce
    /// upstream throttles the rate but does not make the work free.
    ///
    /// A tile is a few hundred kilobytes decoded, so a hundred of them is the
    /// whole point of the limit: enough to cover any pan a user makes, little
    /// enough to stay inside a phone's memory on a long session.
    private let cacheLimit = 96
    private var cache: [String: [TougeRoad]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLock = NSLock()

    private func cached(_ key: String) -> [TougeRoad]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let roads = cache[key] else { return nil }
        // Touch, so the limit evicts what has been unused longest rather than
        // what was loaded first.
        if let at = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: at) }
        cacheOrder.append(key)
        return roads
    }

    private func store(_ key: String, _ roads: [TougeRoad]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = roads
        while cacheOrder.count > cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    /// Empties the cache. Exposed for tests, and for a low-memory warning.
    public func clearCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeAll()
        cacheOrder.removeAll()
    }

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
        if let hit = cached(key) { return hit }
        let roads = try await decodeTile(key: key)
        store(key, roads)
        return roads
    }

    private func decodeTile(key: String) async throws -> [TougeRoad] {
        // The name and extension are split because `withExtension: "json.gz"`
        // does not match a file whose name ends ".json.gz" — it looks for a
        // literal extension of that whole string, finds nothing, and the map
        // silently comes up empty.
        let roads: [TougeRoad]
        if let url = Bundle.main.url(forResource: key + ".json", withExtension: "z"),
           let decompressed = Self.inflate(try Data(contentsOf: url)) {
            roads = try decoder.decode([TougeRoad].self, from: decompressed)
        } else if let url = Bundle.main.url(forResource: key, withExtension: "json") {
            // The uncompressed source tiles. Not reachable in a shipping build:
            // Resources/tiles is excluded from the bundle, so a build made
            // without the compiled ones has no tiles at all and now fails
            // rather than reaching here. This branch is for the test fixtures
            // and for anyone bundling the raw tiles deliberately.
            roads = try decoder.decode([TougeRoad].self, from: Data(contentsOf: url))
        } else {
            // A tile with no roads is normal — the grid covers ocean and
            // countries nobody drives in. Counting these is the only thing that
            // distinguishes "nothing here" from "this build has no road data at
            // all", which otherwise look identical: an empty map, silently.
            Self.countRequest(missing: true)
            return []
        }
        Self.countRequest(missing: false)
        return roads
    }

    /// Inflates a deflate-compressed tile, or returns nil if it is not one.
    ///
    /// Tiles are read lazily as the map pans, so this sits on the path to every
    /// tile. A corrupt or truncated file returns nil and the caller falls back,
    /// rather than throwing and blanking the map.
    private static let countLock = NSLock()
    private static var missingTiles = 0
    private static var requestedTiles = 0

    /// How many tiles have been asked for and not found in the bundle.
    public static var missingTileCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return missingTiles
    }

    /// True when the bundle appears to have no road data in it.
    ///
    /// Deliberately not triggered by a single miss: the grid covers ocean and
    /// countries nobody drives in, so misses are normal. It needs a real sample
    /// behind it, and every single one being a miss.
    public static var roadDataLooksAbsent: Bool {
        countLock.lock(); defer { countLock.unlock() }
        return requestedTiles >= 200 && missingTiles == requestedTiles
    }

    private static func countRequest(missing: Bool) {
        countLock.lock(); defer { countLock.unlock() }
        requestedTiles += 1
        if missing { missingTiles += 1 }
    }

    private static func inflate(_ data: Data) -> Data? {
        // No magic-byte check: the format is bare deflate, so there is no
        // header to recognise, and guessing one already cost a build. Try to
        // inflate and let the caller fall back to the plain tile if it fails.
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
