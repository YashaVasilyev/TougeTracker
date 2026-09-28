import Foundation
import CoreLocation

/// A single road segment with precomputed touge scores.
/// Data is loaded from bundled tile files (generated from touges_db.json).
public struct TougeRoad: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String?
    public let type: String?
    public let coordinates: [[Double]]
    public let lengthMiles: Double?
    public let curvatureScore: Int?
    public let flowScore: Int?
    public let totalScore: Int?
    public let centerLat: Double?
    public let centerLon: Double?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, coordinates
        case lengthMiles, curvatureScore, flowScore
        case totalScore, centerLat, centerLon
    }


    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // The bundled tiles were generated from a database where `id` is an
        // Overpass `way` id. Most are numeric, but a small number of named
        // roads carry string ids like "way-nh-16-pinkham-north". Decoding
        // those as Int64 throws and aborts the *entire* tile — and with it
        // every other road in the visible region — so accept both forms and
        // fold strings into a stable Int64.
        if let numeric = try? c.decode(Int64.self, forKey: .id) {
            self.id = numeric
        } else if let text = try? c.decode(String.self, forKey: .id) {
            self.id = TougeRoad.stableId(from: text)
        } else {
            self.id = 0
        }

        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.type = try c.decodeIfPresent(String.self, forKey: .type)
        self.coordinates = try c.decode([[Double]].self, forKey: .coordinates)
        self.lengthMiles = try c.decodeIfPresent(Double.self, forKey: .lengthMiles)
        self.curvatureScore = try c.decodeIfPresent(Int.self, forKey: .curvatureScore)
        self.flowScore = try c.decodeIfPresent(Int.self, forKey: .flowScore)
        self.totalScore = try c.decodeIfPresent(Int.self, forKey: .totalScore)
        self.centerLat = try c.decodeIfPresent(Double.self, forKey: .centerLat)
        self.centerLon = try c.decodeIfPresent(Double.self, forKey: .centerLon)
    }

    /// FNV-1a over the UTF-8 bytes, forced into a positive Int64 so the value
    /// is stable across launches (saved routes persist this id in SwiftData).
    static func stableId(from text: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(hash % UInt64(Int64.max))
    }

    public var geoPoints: [GeoPoint] { coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) } }
    public var lengthMeters: Double { (lengthMiles ?? 0) * 1609.344 }
    public var displayName: String { (name?.isEmpty == false) ? name! : "Unnamed Road" }
}
