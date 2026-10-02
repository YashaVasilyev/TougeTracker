import Foundation
import CoreLocation

/// Turns a pair of map taps into a measured road segment.
///
/// The bundled tile data only contains ranked touge roads, and MapKit exposes no
/// geometry for arbitrary base-map roads. So a segment is defined by the user:
/// two taps, each snapped onto the nearest known road polyline, and the stretch
/// of geometry between them. Because the result is a plain `TougeRoad` carrying
/// its own measured `lengthMiles`, the existing pacenote / save / drive pipeline
/// consumes it with no special-casing.
public enum RoadSegmentBuilder {

    /// A point on a road polyline: which segment it landed on, how far along
    /// that segment, and the projected point itself.
    public struct Snapped: Equatable, Sendable {
        public var road: TougeRoad
        public var segmentIndex: Int
        public var alongMeters: Double
        public var distanceAlongRoad: Double
        public var point: GeoPoint
        public var perpendicularDistance: CLLocationDistance
    }

    public enum Failure: Error, Equatable {
        /// No road geometry anywhere near the tap.
        case noRoadNearby
        /// The two taps snapped onto different roads — we can only carve a
        /// segment out of a single continuous polyline.
        case differentRoads
        /// Snapped fine, but the resulting stretch is degenerate.
        case tooShort
    }

    // MARK: - Snapping

    /// Snaps `point` onto the closest road within `toleranceMeters`.
    ///
    /// The tolerance is absolute rather than zoom-derived here: the caller
    /// already owns the "how far is too far" policy via the camera span (see
    /// `nearestRoad` in the Plan view), and taking it as a parameter keeps this
    /// function pure and directly testable.
    public static func snap(_ point: CLLocationCoordinate2D, in roads: [TougeRoad],
                            toleranceMeters: CLLocationDistance) -> Snapped? {
        let target = GeoPoint.from(point)
        var best: Snapped?

        for road in roads {
            let coords = road.geoPoints
            guard coords.count >= 2 else { continue }
            let cumulative = GeoMath.cumulativeDistances(coords)

            for i in 0..<(coords.count - 1) {
                let (proj, along) = GeoMath.projectOnSegment(target, coords[i], coords[i + 1])
                let d = GeoMath.distanceMeters(target, proj)
                guard d <= toleranceMeters else { continue }
                if best == nil || d < best!.perpendicularDistance {
                    best = Snapped(road: road, segmentIndex: i, alongMeters: along,
                                   distanceAlongRoad: cumulative[i] + along,
                                   point: proj, perpendicularDistance: d)
                }
            }
        }
        return best
    }

    // MARK: - Extraction

    /// Extracts the sub-polyline of `start.road` running from `start` to `end`.
    ///
    /// Orientation follows the tap order, so tapping the far end first reverses
    /// the segment — which is what the driver wants, since pacenotes are
    /// direction-sensitive.
    public static func extract(from start: Snapped, to end: Snapped) throws -> [GeoPoint] {
        guard start.road.id == end.road.id else { throw Failure.differentRoads }

        // Orientation follows the tap order, so tapping the far end first
        // reverses the segment — which is what the driver wants, since
        // pacenotes are direction-sensitive.
        let forward = end.distanceAlongRoad >= start.distanceAlongRoad
        guard let points = stretch(of: start.road, from: start.distanceAlongRoad,
                                   to: end.distanceAlongRoad, forward: forward)
        else { throw Failure.tooShort }
        return points
    }

    /// The stretch of `road`'s geometry between two distances along it.
    ///
    /// The distance-based form of `extract(from:to:)`, for the callers that have
    /// a place rather than a tap: `extract` needs two projected endpoints to
    /// work from, and the live pacenote source only has a distance — how far
    /// along this road the car is, and how far it wants to see.
    ///
    /// Endpoints are interpolated onto the road (`GeoMath.along`) rather than
    /// projected onto a segment, so `lo` is clamped to the start of the road and
    /// `hi` to its end: a window that runs off either end is a shorter window,
    /// never one with a fabricated point hanging off the map.
    public static func stretch(of road: TougeRoad, from startMeters: Double,
                               to endMeters: Double, forward: Bool) -> [GeoPoint]? {
        let coords = road.geoPoints
        guard coords.count >= 2 else { return nil }

        let total = GeoMath.lengthMeters(coords)
        let lo = max(0, min(startMeters, endMeters))
        let hi = min(total, max(startMeters, endMeters))
        guard hi > lo else { return nil }
        let cumulative = GeoMath.cumulativeDistances(coords)

        // Built in road order and reversed afterwards, for the same reason
        // `extract` does it: reversing a list built in the other order would
        // also put the interior vertices in the wrong sequence, yielding a
        // non-monotonic polyline.
        //
        // Interior vertices are chosen by distance-along-road, strictly between
        // the two ends. Selecting them by segment *index* instead emits a vertex
        // twice whenever an end lands exactly on one.
        var points: [GeoPoint] = [GeoMath.along(coords, distance: lo)]
        for i in 1..<(coords.count - 1) where cumulative[i] > lo && cumulative[i] < hi {
            points.append(coords[i])
        }
        points.append(GeoMath.along(coords, distance: hi))

        if !forward { points.reverse() }

        // A zero-length segment would corrupt the pacenote resampling, and both
        // ends can land exactly on a vertex.
        dedupeNear(&points, fromEnd: true)
        dedupeNear(&points, fromEnd: false)

        return points.count >= 2 ? points : nil
    }

    private static func dedupeNear(_ points: inout [GeoPoint], fromEnd: Bool) {
        while points.count >= 2 {
            let pair = fromEnd ? (points[points.count - 2], points[points.count - 1])
                               : (points[0], points[1])
            guard GeoMath.distanceMeters(pair.0, pair.1) < 0.5 else { return }
            if fromEnd { points.removeLast() } else { points.removeFirst() }
        }
    }

    // MARK: - Building a road

    /// Snap both taps, extract the geometry, and wrap it as a `TougeRoad` with a
    /// measured length. `name` is what the user sees in the preview card and the
    /// saved-routes list.
    public static func makeRoad(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D,
                                in roads: [TougeRoad], toleranceMeters: CLLocationDistance,
                                name: String = "Custom Segment") throws -> TougeRoad {
        guard let a = snap(start, in: roads, toleranceMeters: toleranceMeters),
              let b = snap(end, in: roads, toleranceMeters: toleranceMeters) else {
            throw Failure.noRoadNearby
        }
        return makeRoad(points: try extract(from: a, to: b), name: name)
    }

    /// Wraps an arbitrary polyline as a `TougeRoad`, measuring its length with
    /// the same haversine used everywhere else in the app.
    public static func makeRoad(points: [GeoPoint], name: String = "Custom Segment") -> TougeRoad {
        let meters = GeoMath.lengthMeters(points)
        let lats = points.map(\.lat), lons = points.map(\.lon)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2

        // Stable id derived from the geometry, so re-selecting the same stretch
        // upserts the saved route instead of duplicating it. Coordinates are
        // rounded to ~1m so float noise cannot yield a different id per launch.
        let key = points.map { "\(Int(($0.lat * 100_000).rounded())),\(Int(($0.lon * 100_000).rounded()))" }
                        .joined(separator: ";")
        // OR in a high bit to keep user segments clear of the FNV ids that tile
        // roads already occupy, and force the value positive for SwiftData.
        let id = TougeRoad.stableId(from: "segment:\(key)") | 0x4000_0000_0000_0000

        return TougeRoad(
            id: id, name: name, type: "segment",
            coordinates: points.map { [$0.lon, $0.lat] },
            lengthMiles: meters / 1609.344,
            curvatureScore: nil, flowScore: nil, totalScore: nil,
            centerLat: centerLat, centerLon: centerLon
        )
    }
}
