import Foundation
import CoreLocation

/// A single road segment with precomputed touge scores.
/// Data is loaded from bundled tile files (generated from roadcurvature.com
/// KML data by `scripts/fetch-curvature-tiles.mjs`).
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

        // The current tiles are generated from roadcurvature.com, whose road
        // IDs are FNV-1a hashes emitted as integers, so the numeric path is the
        // normal one. The string branch is kept because decoding a string as
        // Int64 throws and would abort the *entire* tile — and with it every
        // other road in the visible region — so accept both forms regardless.
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

    /// Memberwise initializer for building roads from geometry rather than from
    /// a tile file. The decoder is the *only* other way in, and it is
    /// unavailable to any synthesized shape like a user-drawn segment.
    public init(id: Int64, name: String?, type: String?, coordinates: [[Double]],
                lengthMiles: Double?, curvatureScore: Int?, flowScore: Int?,
                totalScore: Int?, centerLat: Double?, centerLon: Double?) {
        self.id = id
        self.name = name
        self.type = type
        self.coordinates = coordinates
        self.lengthMiles = lengthMiles
        self.curvatureScore = curvatureScore
        self.flowScore = flowScore
        self.totalScore = totalScore
        self.centerLat = centerLat
        self.centerLon = centerLon
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

    /// The same road, driven the other way.
    ///
    /// The id is kept: this is the same stretch of tarmac, not a different
    /// route, and keeping it means a saved road that is reversed updates in
    /// place rather than appearing twice in the list. Direction lives in the
    /// geometry, and everything downstream of it — pacenotes, scores, the
    /// call sequence — is regenerated from the reversed line.
    ///
    /// The center is unchanged by reversal (it is a bounding-box midpoint), so
    /// it is carried across rather than recomputed.
    public func reversed() -> TougeRoad {
        guard coordinates.count > 1 else { return self }
        return TougeRoad(
            id: id, name: name, type: type,
            coordinates: coordinates.reversed(),
            lengthMiles: lengthMiles,
            curvatureScore: curvatureScore, flowScore: flowScore,
            totalScore: totalScore,
            centerLat: centerLat, centerLon: centerLon
        )
    }

    /// Which way this road runs, for showing on the preview and detail panels.
    public var direction: RouteDirection { RouteDirection(coordinates: coordinates) }
}
