import Foundation
import CoreLocation

/// Which way a route runs, so the panels can say so rather than leaving the
/// driver to infer it from a line with no arrow on it.
///
/// This is deliberately *bearing only*. A touge road is interesting because it
/// climbs or falls, and "downhill" is the thing a driver most wants to know —
/// but the app holds no elevation anywhere in its route data, so claiming a
/// gradient would be inventing it. Bearing is real: it is measured from the
/// geometry. If elevation is ever sourced, this is where a gradient belongs.
public struct RouteDirection: Equatable, Sendable {
    /// Compass point the route travels towards, e.g. "NE". Empty when the
    /// route has no usable direction.
    public let compass: String
    /// Bearing in degrees from the start of the route to its end.
    public let bearing: Double
    /// Where driving begins.
    public let start: GeoPoint?
    /// Where driving finishes.
    public let end: GeoPoint?

    public init(coordinates: [[Double]]) {
        let points = coordinates
            .filter { $0.count >= 2 }
            .map { GeoPoint(lon: $0[0], lat: $0[1]) }
        guard let first = points.first, let last = points.last, points.count > 1 else {
            self.init(compass: "", bearing: 0, start: nil, end: nil)
            return
        }
        let heading = GeoMath.bearing(first, last)
        self.init(compass: RouteDirection.compassPoint(for: heading),
                  bearing: heading,
                  start: first,
                  end: last)
    }

    private init(compass: String, bearing: Double, start: GeoPoint?, end: GeoPoint?) {
        self.compass = compass
        self.bearing = bearing
        self.start = start
        self.end = end
    }

    /// Nothing to show — too few points to have a direction.
    public var isKnown: Bool { start != nil && end != nil }

    /// "NE" and the reverse "SW", for showing the two ends of the route.
    public var reversedCompass: String {
        guard isKnown else { return "" }
        return RouteDirection.compassPoint(for: GeoMath.wrap180(bearing + 180))
    }

    /// SF Symbol rotated to point the way the route runs, for the arrow on the
    /// preview card. `arrow.up` points north at 0°, so the bearing is the
    /// rotation.
    public var arrowRotation: Double { bearing }

    /// The eight compass points. Boundaries are at the centre of each sector, so
    /// NE covers 22.5°–67.5°.
    static func compassPoint(for bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalised = GeoMath.wrap180(bearing)
        let raw = Int(((normalised + 22.5) / 45).rounded(.down))
        // `wrap180` returns -180...180, so a westerly bearing gives a negative
        // sector index. Swift's `%` keeps the dividend's sign — `-2 % 8` is `-2`,
        // not `6` — which indexed straight off the front of the array. Two
        // modulo steps fold it back into range.
        let index = ((raw % points.count) + points.count) % points.count
        return points[index]
    }
}
