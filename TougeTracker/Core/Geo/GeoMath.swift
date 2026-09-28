import Foundation
import CoreLocation

/// GeoJSON-order point (lon, lat) — matches Tougefinder's coordinate arrays.
public struct GeoPoint: Codable, Equatable, Hashable, Sendable {
    public var lon: Double
    public var lat: Double

    public init(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
    }

    public var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    public static func from(_ c: CLLocationCoordinate2D) -> GeoPoint {
        GeoPoint(lon: c.longitude, lat: c.latitude)
    }
}

/// Direct Swift port of the @turf/turf v6 primitives used by Tougefinder's
/// pacenote algorithm (earthRadius 6371008.8, haversine distance,
/// [-180, 180] bearings, geodesic `along` interpolation).
/// Fidelity is enforced by golden tests against the JS implementation.
public enum GeoMath {
    public static let earthRadius = 6371008.8

    public static func degreesToRadians(_ d: Double) -> Double { d * .pi / 180 }
    public static func radiansToDegrees(_ r: Double) -> Double { r * 180 / .pi }

    /// JS Math.round — rounds half toward +infinity, i.e. floor(x + 0.5).
    public static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    /// turf.distance — haversine, meters.
    public static func distanceMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = degreesToRadians(b.lat - a.lat)
        let dLon = degreesToRadians(b.lon - a.lon)
        let lat1 = degreesToRadians(a.lat)
        let lat2 = degreesToRadians(b.lat)
        let h = pow(sin(dLat / 2), 2) + pow(sin(dLon / 2), 2) * cos(lat1) * cos(lat2)
        return 2 * atan2(sqrt(h), sqrt(1 - h)) * earthRadius
    }

    /// turf.bearing — degrees in [-180, 180], clockwise from north.
    public static func bearing(_ start: GeoPoint, _ end: GeoPoint) -> Double {
        let lon1 = degreesToRadians(start.lon)
        let lon2 = degreesToRadians(end.lon)
        let lat1 = degreesToRadians(start.lat)
        let lat2 = degreesToRadians(end.lat)
        let a = sin(lon2 - lon1) * cos(lat2)
        let b = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lon2 - lon1)
        return radiansToDegrees(atan2(a, b))
    }

    /// turf.destination — geodesic point at distance (meters) along bearing.
    /// A negative distance travels in the opposite direction (used by `along`).
    public static func destination(_ origin: GeoPoint, _ distance: Double, _ bearingDegrees: Double) -> GeoPoint {
        let lon1 = degreesToRadians(origin.lon)
        let lat1 = degreesToRadians(origin.lat)
        let theta = degreesToRadians(bearingDegrees)
        let delta = distance / earthRadius
        let lat2 = asin(sin(lat1) * cos(delta) + cos(lat1) * sin(delta) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(delta) * cos(lat1),
                                cos(delta) - sin(lat1) * sin(lat2))
        return GeoPoint(lon: radiansToDegrees(lon2), lat: radiansToDegrees(lat2))
    }

    /// turf.length — summed haversine segment lengths, meters.
    public static func lengthMeters(_ coords: [GeoPoint]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 0..<(coords.count - 1) {
            total += distanceMeters(coords[i], coords[i + 1])
        }
        return total
    }

    /// turf.along — exact port, including the negative-overshoot geodesic
    /// interpolation between segment endpoints.
    public static func along(_ coords: [GeoPoint], distance: Double) -> GeoPoint {
        guard let last = coords.last else { return GeoPoint(lon: 0, lat: 0) }
        var travelled = 0.0
        for i in 0..<coords.count {
            if distance >= travelled && i == coords.count - 1 {
                break
            } else if travelled >= distance {
                let overshot = distance - travelled
                if overshot == 0 {
                    return coords[i]
                } else {
                    let direction = bearing(coords[i], coords[i - 1]) - 180
                    return destination(coords[i], overshot, direction)
                }
            } else {
                travelled += distanceMeters(coords[i], coords[i + 1])
            }
        }
        return last
    }

    /// Heron's circumradius through three points, meters.
    /// `.infinity` for collinear/degenerate triangles — matches pacenotes.js.
    public static func circumRadiusMeters(_ p1: GeoPoint, _ p2: GeoPoint, _ p3: GeoPoint) -> Double {
        let a = distanceMeters(p1, p2)
        let b = distanceMeters(p2, p3)
        let c = distanceMeters(p1, p3)
        let s = (a + b + c) / 2
        let areaSq = s * (s - a) * (s - b) * (s - c)
        if areaSq <= 0 { return .infinity }
        return (a * b * c) / (4 * sqrt(areaSq))
    }

    /// Chaikin corner-cutting smoothing (75/25), `iterations` passes.
    public static func chaikinSmooth(_ coords: [GeoPoint], iterations: Int = 2) -> [GeoPoint] {
        guard coords.count >= 3 else { return coords }
        var current = coords
        for _ in 0..<iterations {
            var next: [GeoPoint] = [current[0]]
            for i in 0..<(current.count - 1) {
                let p0 = current[i]
                let p1 = current[i + 1]
                next.append(GeoPoint(lon: p0.lon * 0.75 + p1.lon * 0.25,
                                     lat: p0.lat * 0.75 + p1.lat * 0.25))
                next.append(GeoPoint(lon: p0.lon * 0.25 + p1.lon * 0.75,
                                     lat: p0.lat * 0.25 + p1.lat * 0.75))
            }
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }

    /// Wraps an angle in degrees to [-180, 180) — same single-step wrap as pacenotes.js.
    public static func wrap180(_ deg: Double) -> Double {
        var d = deg
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    // MARK: - Polyline utilities (for the live navigator)

    /// Cumulative distance in meters at each vertex (first element 0).
    public static func cumulativeDistances(_ coords: [GeoPoint]) -> [Double] {
        guard !coords.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: coords.count)
        for i in 1..<coords.count {
            result[i] = result[i - 1] + distanceMeters(coords[i - 1], coords[i])
        }
        return result
    }

    /// Projects `p` onto segment a→b using an equirectangular local projection.
    /// Returns the projected point and the distance along the segment in meters.
    public static func projectOnSegment(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> (point: GeoPoint, alongMeters: Double) {
        let cosLat = cos(degreesToRadians(a.lat))
        let ax = a.lon * cosLat, ay = a.lat
        let bx = b.lon * cosLat, by = b.lat
        let px = p.lon * cosLat, py = p.lat
        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return (a, 0) }
        var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
        t = min(1, max(0, t))
        let projected = GeoPoint(lon: (ax + t * dx) / cosLat, lat: ay + t * dy)
        return (projected, t * distanceMeters(a, b))
    }

    public struct PolylineSnap: Equatable {
        public var point: GeoPoint
        public var routeDistance: Double
        public var segmentIndex: Int
        public var perpendicularDistance: Double
    }

    /// Snaps `p` to the nearest point on the polyline.
    public static func snapToPolyline(_ coords: [GeoPoint], cumulative: [Double], point p: GeoPoint) -> PolylineSnap {
        guard coords.count > 1, coords.count == cumulative.count else {
            return PolylineSnap(point: p, routeDistance: 0, segmentIndex: 0, perpendicularDistance: 0)
        }
        var best = PolylineSnap(point: coords[0], routeDistance: 0, segmentIndex: 0, perpendicularDistance: .infinity)
        for i in 0..<(coords.count - 1) {
            let (proj, along) = projectOnSegment(p, coords[i], coords[i + 1])
            let d = distanceMeters(p, proj)
            if d < best.perpendicularDistance {
                best = PolylineSnap(point: proj,
                                    routeDistance: cumulative[i] + along,
                                    segmentIndex: i,
                                    perpendicularDistance: d)
            }
        }
        return best
    }

    /// Bearing of the polyline at a given route distance (bearing of the containing segment).
    public static func bearingAtDistance(_ coords: [GeoPoint], cumulative: [Double], distance: Double) -> Double {
        guard coords.count > 1 else { return 0 }
        var i = 0
        while i < coords.count - 2 && cumulative[i + 1] < distance { i += 1 }
        return bearing(coords[i], coords[i + 1])
    }
}
