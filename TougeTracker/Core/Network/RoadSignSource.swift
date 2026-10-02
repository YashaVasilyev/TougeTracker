import Foundation
import CoreLocation

/// Asks OpenStreetMap for the signs and signals along a stretch of road.
///
/// The tiles carry geometry and nothing else — no tags, no signs, and no way to
/// find out what is at a coordinate. Overpass is where that lives, and it needs
/// no identifier: a box and a tag filter is enough, which is why this works on
/// any road, scored or not.
///
/// One query per window, and the window is a kilometre long, so the answer is a
/// handful of nodes. That is the whole cost model: this is a road-recorder
/// budget, not a mapping tool, so it is asked once per rebuild and never per fix.
public final class RoadSignSource: @unchecked Sendable {

    public static let shared = RoadSignSource()

    /// A road with no geometry, for when the router could not be asked.
    ///
    /// Returning this rather than an optional keeps the caller's shape simple:
    /// a window that has no geometry is rejected downstream by the same minimum
    /// length check as any other.
    public static let emptyRoad = TougeRoad(
        id: 0, name: nil, type: nil, coordinates: [], lengthMiles: nil,
        curvatureScore: nil, flowScore: nil, totalScore: nil,
        centerLat: nil, centerLon: nil)

    private let overpass: RoutePlanner

    public init(overpass: RoutePlanner = .shared) {
        self.overpass = overpass
    }


    /// A sign or signal, and where it sits along the road.
    public struct Sign: Sendable {
        public var point: GeoPoint
        public var feature: RoadFeature

        public var coordinate: CLLocationCoordinate2D { point.clLocation }
    }

    /// Signs within `maxDistanceMeters` of `polyline`, with their position along
    /// it in metres.
    ///
    /// The box query returns every sign in the rectangle, including ones on
    /// cross-streets a kilometre away, so the distance filter is not a nicety —
    /// without it a stop sign on the next street over would be called as if it
    /// were on this road.
    public func signs(along polyline: [GeoPoint],
                      withinMeters maxDistance: Double = 40) async -> [FeatureNote] {
        guard polyline.count >= 2 else { return [] }
        let (minLat, minLon, maxLat, maxLon) = bounds(of: polyline)
        // A little margin, so a sign just outside the box is still filtered by
        // distance rather than missed by it.
        let query = """
        [out:json][timeout:15];
        node["highway"~"^(stop|traffic_signals|give_way)$"]
        (bbox:\(minLat - 0.0005),\(minLon - 0.0005),\(maxLat + 0.0005),\(maxLon + 0.0005));
        // `out tags` prints the tags and *nothing else* — no coordinates — so
        // every node came back unplaceable and the distance filter had nothing
        // to measure. `out;` is tags plus the body, which is where lat/lon live.
        out;
        """
        guard let data = try? await overpass.overpass(query),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]]
        else { return [] }

        let cumulative = GeoMath.cumulativeDistances(polyline)
        var found: [FeatureNote] = []
        for element in elements {
            // Read through `[String: Any]` and NSNumber rather than casting the
            // whole dictionary to `[String: String]` and the coordinates to
            // `Double`. Overpass returns numbers as NSNumber and a node with any
            // numeric-looking tag makes the strict cast fail, which threw away
            // every element in the response and looked exactly like "no signs
            // here" — the answer the road was already giving.
            guard let tags = element["tags"] as? [String: Any],
                  let highway = tags["highway"] as? String,
                  let feature = RoadFeature(osmTag: highway),
                  let lat = (element["lat"] as? NSNumber)?.doubleValue,
                  let lon = (element["lon"] as? NSNumber)?.doubleValue
            else { continue }
            let point = GeoPoint(lon: lon, lat: lat)
            let snap = GeoMath.snapToPolyline(polyline, cumulative: cumulative, point: point)
            guard snap.perpendicularDistance <= maxDistance else { continue }
            found.append(FeatureNote(distance: snap.routeDistance, feature: feature))
        }
        // Two nodes can share a position — a stop line and the sign — and saying
        // the same thing twice is worse than saying it once.
        return found.sorted { $0.distance < $1.distance }
            .deduplicated { abs($0.distance - $1.distance) < 5 }
    }

    private func bounds(of polyline: [GeoPoint]) -> (Double, Double, Double, Double) {
        let lats = polyline.map(\.lat), lons = polyline.map(\.lon)
        return (lats.min()!, lons.min()!, lats.max()!, lons.max()!)
    }

}

private extension Array where Element == FeatureNote {
    /// Drops a feature that repeats one already collected at the same spot.
    func deduplicated(_ isSame: (FeatureNote, FeatureNote) -> Bool) -> [FeatureNote] {
        var out: [FeatureNote] = []
        for item in self where !out.contains(where: { isSame($0, item) }) { out.append(item) }
        return out
    }
}