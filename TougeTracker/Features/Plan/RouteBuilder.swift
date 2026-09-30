import Foundation
import CoreLocation

/// The point list behind multi-point routing, with no view in it.
///
/// This started as four `@State` properties and three methods on a 900-line
/// `View`, which meant the rules — a tap on top of the last point is a mis-tap,
/// the list reverses end to end, routing needs two points — were reachable only
/// by driving the interface. There are no UI tests in the project, so that
/// left the newest features unverified.
///
/// Pulled out so the rules can be tested directly, and so the view is left
/// holding only what the view owns.
@Observable
public final class RouteBuilder {

    /// Every point the user has tapped, in driving order.
    ///
    /// Two is an ordinary start and end; more are waypoints, and the router
    /// threads one continuous line through them.
    public private(set) var points: [CLLocationCoordinate2D] = []

    /// Why the last tap was refused, if it was.
    public private(set) var error: String?

    /// Two points close enough together are a double-tap, not an itinerary.
    ///
    /// The router answers a near-zero leg with no route, and the user's intent
    /// was plainly not "add another stop here".
    public static let minimumSeparation: CLLocationDistance = 25

    public init() {}

    public var canRoute: Bool { points.count >= 2 }
    public var isEmpty: Bool { points.isEmpty }

    /// Adds a point, refusing one that lands on the last.
    ///
    /// - Returns: whether the point was accepted.
    @discardableResult
    public func add(_ coordinate: CLLocationCoordinate2D) -> Bool {
        if let last = points.last,
           GeoMath.distanceMeters(GeoPoint.from(last), GeoPoint.from(coordinate))
               < Self.minimumSeparation {
            error = "That is the same point as the one before."
            return false
        }
        error = nil
        points.append(coordinate)
        return true
    }

    /// Removes the most recent point, for a mis-tap.
    public func undo() {
        guard !points.isEmpty else { return }
        points.removeLast()
        error = nil
    }

    /// Swaps start and finish, so a route can be driven the other way without
    /// re-tapping every point.
    public func reverse() {
        guard points.count >= 2 else { return }
        points.reverse()
        error = nil
    }

    public func clear() {
        points = []
        error = nil
    }

    /// The points to route, or nil if there are not enough.
    public var routable: [CLLocationCoordinate2D]? { canRoute ? points : nil }

    /// What a point means in the list, for the map pins.
    public func label(for index: Int) -> String {
        if index == 0 { return "Start" }
        if index == points.count - 1 { return "Finish" }
        return "Stop \(index)"
    }

    public func isFirst(_ index: Int) -> Bool { index == 0 }
    public func isLast(_ index: Int) -> Bool { index == points.count - 1 && points.count > 1 }
}
