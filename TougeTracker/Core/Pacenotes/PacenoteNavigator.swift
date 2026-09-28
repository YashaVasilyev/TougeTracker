import Foundation
import CoreLocation

/// A rally co-driver call. `items` may chain several notes together (e.g.
/// "100 four right into five left") when they occur within 50 m of each other.
public struct PacenoteCall: Equatable {
    public struct Item: Equatable {
        public let note: Pacenote
        public let remaining: Double     // meters to the note start
        public let connector: String?    // nil for the first; "into" (gap<20m) or "and" (gap<50m)
        public init(note: Pacenote, remaining: Double, connector: String?) {
            self.note = note
            self.remaining = remaining
            self.connector = connector
        }
    }

    public let items: [Item]
    public init(items: [Item]) { self.items = items }

    public var note: Pacenote { items.first!.note }
    public var remaining: Double { items.first?.remaining ?? 0 }
}

/// Progress tracker for a live drive along a route.
///
/// Snaps each GPS fix to the route polyline, detects travel direction,
/// enforces monotonic progress, detects off-route excursions, and schedules
/// pacenote calls at a speed-scaled distance ahead — mirroring rally co-driver
/// timing.
public final class PacenoteNavigator {
    public private(set) var coordinates: [CLLocationCoordinate2D]
    public private(set) var cumulative: [Double]
    public private(set) var pacenotes: [Pacenote]
    public let totalLength: Double
    public private(set) var progressDistance: Double = 0
    public private(set) var offRoute = false
    public private(set) var directionReversed = false
    /// Multiplier on the speed-scaled call distance (1.0 = default).
    public var callDistanceScale: Double = 1.0

    /// Upper bound on how many notes one call may chain.
    ///
    /// A co-driver call is a breath, not a paragraph. Past a few corners the
    /// driver has stopped listening, and the tail would be spoken over the
    /// corner that actually matters. Anything not chained stays pending and is
    /// called on approach instead.
    private let maxItemsPerCall = 3

    private let originalCoordinates: [CLLocationCoordinate2D]
    private var directionLocked = false
    /// Index of the next pacenote that has not been called yet.
    public private(set) var nextNoteIndex: Int = 0
    private var announcedIndexes: Set<Int> = []
    private var offRouteSince: Date?

    public init(coordinates: [CLLocationCoordinate2D],
                pacenotes: [Pacenote]? = nil,
                callDistanceScale: Double = 1.0) {
        self.originalCoordinates = coordinates
        self.coordinates = coordinates
        let pts = coordinates.map { GeoPoint.from($0) }
        self.cumulative = GeoMath.cumulativeDistances(pts)
        self.totalLength = cumulative.last ?? 0
        self.pacenotes = pacenotes ?? PacenoteGenerator.generate(pts).turns
        self.callDistanceScale = callDistanceScale
    }

    /// Speed-scaled call distance: call farther ahead at highway speeds.
    private func callDistance(speed mps: Double) -> Double {
        max(120, min(400, mps * 8)) * callDistanceScale
    }

    /// Feed a location fix; returns the rally call to speak (if any).
    @discardableResult
    public func update(location: CLLocation, speed: Double) -> PacenoteCall? {
        guard coordinates.count > 1 else { return nil }

        let pts = coordinates.map { GeoPoint.from($0) }
        let snap = GeoMath.snapToPolyline(pts, cumulative: cumulative,
                                          point: GeoPoint.from(location.coordinate))

        // Direction detection: once we have a real course and are moving,
        // compare it to a downstream route bearing. If anti-parallel the user
        // started the road backwards → reverse geometry + mirror L/R.
        if !directionLocked {
            if location.course >= 0, speed > 3 {
                let at = min(coordinates.count - 1, max(1, snap.segmentIndex + 2))
                let downstream = GeoMath.bearing(.from(coordinates[snap.segmentIndex]),
                                                 .from(coordinates[at]))
                let diff = GeoMath.wrap180(location.course - downstream)
                if abs(diff) > 90 {
                    reverseRoute()
                    let pts2 = coordinates.map { GeoPoint.from($0) }
                    let resnap = GeoMath.snapToPolyline(pts2, cumulative: cumulative,
                                                        point: GeoPoint.from(location.coordinate))
                    applySnap(resnap)
                } else {
                    applySnap(snap)
                }
                directionLocked = true
            } else {
                // Stationary / unknown course: hold off locking until we can tell.
                applySnap(snap)
            }
        } else {
            applySnap(snap)
        }

        // Advance past notes we've already driven through.
        while nextNoteIndex < pacenotes.count,
              progressDistance > pacenotes[nextNoteIndex].endDist + 15 {
            nextNoteIndex += 1
        }
        // Also step over notes already called but not yet driven past. Without
        // this the cursor parks on the first announced note, the `already
        // announced` guard below rejects it forever, and every later corner is
        // silently skipped.
        while nextNoteIndex < pacenotes.count,
              announcedIndexes.contains(nextNoteIndex),
              progressDistance <= pacenotes[nextNoteIndex].endDist + 15 {
            nextNoteIndex += 1
        }

        guard !offRoute, nextNoteIndex < pacenotes.count else { return nil }
        let note = pacenotes[nextNoteIndex]
        let remaining = note.startDist - progressDistance
        // `> -5` tolerates a fix that lands a few metres into the corner, but a
        // note the driver has genuinely passed must not block the ones behind it.
        guard remaining <= callDistance(speed: speed), remaining > -5 else { return nil }

        // Build the call, chaining the next few imminent notes ("into" /
        // "followed by"). Chaining is bounded by how far ahead the *driver* is,
        // not just by the gap to the previous note: the gap test alone let a run
        // of closely-spaced corners chain all the way down the road, so a
        // single call read out the whole route at once.
        announcedIndexes.insert(nextNoteIndex)
        var items = [PacenoteCall.Item(note: note, remaining: max(remaining, 0), connector: nil)]
        var look = nextNoteIndex + 1
        var prevEnd = note.endDist
        // Tracks the previously chained note so a corner following a straight can
        // drop its connector.
        var prev = note
        let horizon = callDistance(speed: speed)

        while look < pacenotes.count, items.count < maxItemsPerCall {
            let next = pacenotes[look]
            let gap = next.startDist - prevEnd
            // A chained note must also be within the call horizon, or the
            // driver is told about a corner they are still far from.
            let nextRemaining = next.startDist - progressDistance
            let isImminent = nextRemaining <= horizon
            if gap >= 0, gap < 50, isImminent,
               !announcedIndexes.contains(look) {
                // A straight states its own distance, so the corner after it
                // needs no connector. Otherwise the corners are effectively one
                // movement and read as "into".
                let connector: String?
                if prev.isStraight {
                    connector = nil
                } else {
                    connector = gap < 20 ? "into" : "followed by"
                }
                items.append(PacenoteCall.Item(note: next,
                                                remaining: max(nextRemaining, 0),
                                                connector: connector))
                announcedIndexes.insert(look)
                prevEnd = next.endDist
                prev = next
                look += 1
            } else {
                break
            }
        }
        return PacenoteCall(items: items)
    }

    private func applySnap(_ snap: GeoMath.PolylineSnap) {
        if snap.perpendicularDistance > 45 {
            if offRouteSince == nil { offRouteSince = Date() }
            if Date().timeIntervalSince(offRouteSince!) > 2 { offRoute = true }
        } else {
            offRoute = false
            offRouteSince = nil
            progressDistance = max(progressDistance, snap.routeDistance)
        }
    }

    private func reverseRoute() {
        directionReversed = true
        directionLocked = true
        coordinates = originalCoordinates.reversed()
        let pts = coordinates.map { GeoPoint.from($0) }
        cumulative = GeoMath.cumulativeDistances(pts)
        pacenotes = PacenoteGenerator.generate(pts).turns
        nextNoteIndex = 0
        announcedIndexes = []
    }

    /// The next `count` pacenotes that are due (not yet passed, not yet called).
    public func upcoming(count: Int) -> [Pacenote] {
        var result: [Pacenote] = []
        var i = nextNoteIndex
        while i < pacenotes.count, result.count < count {
            if !announcedIndexes.contains(i) {
                result.append(pacenotes[i])
            }
            i += 1
        }
        return result
    }

    /// Progress along the route (0.0–1.0).
    public var progress: Double {
        guard totalLength > 0 else { return 0 }
        return min(1, max(0, progressDistance / totalLength))
    }

    public func reset() {
        progressDistance = 0
        nextNoteIndex = 0
        announcedIndexes = []
        offRoute = false
        offRouteSince = nil
        directionReversed = false
        directionLocked = false
        coordinates = originalCoordinates
        let pts = coordinates.map { GeoPoint.from($0) }
        cumulative = GeoMath.cumulativeDistances(pts)
        pacenotes = PacenoteGenerator.generate(pts).turns
    }
}
