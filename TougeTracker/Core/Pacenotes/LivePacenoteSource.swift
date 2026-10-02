import Foundation
import CoreLocation

/// Pacenotes for a drive that has no route planned.
///
/// A free drive used to be "pacenotes off" because there was nothing to pace the
/// notes against: without a route there is no geometry ahead of the car to
/// derive them from. The bundled tiles are the only ahead-of-you geometry the
/// app has offline — MapKit exposes none — so the road is discovered a kilometre
/// at a time instead of being known in advance. Snap the fix to the nearest
/// known road, take the stretch from just behind the car to a kilometre ahead,
/// orient it by the heading the car is actually travelling, and generate notes
/// for it. When that window is nearly spent, the next one is built where the car
/// now is.
///
/// Everything downstream is deliberately unchanged: the same
/// `PacenoteGenerator.generate`, the same `PacenoteNavigator` timing and
/// chaining, the same written text and the same voice. Only the origin of the
/// geometry differs, which is the whole of what "live" means here.
///
/// Where the geometry comes from, in order. The bundled tiles carry ranked touge
/// roads and are on the phone, free and instant. The router is asked only when
/// the tiles have nothing — which is every base-map road nobody has ever scored,
/// the majority of the roads a free drive is actually on. Where neither has
/// anything, the source stays idle, tries again as the car moves, and says
/// nothing rather than guessing.
@MainActor
public final class LivePacenoteSource {

    /// The roads near a coordinate. Injectable so the planner can be driven from
    /// fixtures without the bundle, and so the tile cache stays behind the
    /// production loader.
    public typealias RoadLoader = @Sendable (_ coordinate: CLLocationCoordinate2D) async -> [TougeRoad]

    /// The driving line ahead of the car, fetched from the router for the roads
    /// the tiles do not carry. Empty means "no line" — no coverage, no signal,
    /// or the router refused.
    ///
    /// It returns `TougeRoad`s rather than loose geometry on purpose: a routed
    /// line is then handed to exactly the same window code a tile road is, so
    /// there is no second, slightly different way of turning a road into notes.
    public typealias LineLoader = @Sendable (_ coordinate: CLLocationCoordinate2D,
                                             _ courseDegrees: Double,
                                             _ lookaheadMeters: Double) async -> [TougeRoad]

    /// The slice of road the notes are generated from.
    public struct Window: Sendable {
        public var coordinates: [CLLocationCoordinate2D]
        public var pacenotes: [Pacenote]
        public var roadID: Int64
        public var roadName: String?
    }

    // MARK: - Tuning

    /// How far behind the car a window starts.
    ///
    /// Snapping has to keep working when a fix lands a few metres off the road,
    /// and the navigator treats anything more than 45m from the polyline as
    /// off-route. A window beginning exactly at the fix would put ordinary GPS
    /// noise outside its own line.
    nonisolated public static let backfillMeters: Double = 60

    /// How far off any known road a fix may be and still start a window. Matches
    /// the navigator's own off-route tolerance: a car further off than this is
    /// not on a road the tiles know, and pretending otherwise would have the
    /// co-driver calling corners for a road the driver is not on.
    nonisolated public static let toleranceMeters: Double = 45

    /// The shortest stretch worth generating from. Below this the window cannot
    /// contain a corner, and there is nothing to say about it anyway.
    nonisolated public static let minimumWindowMeters: Double = 100

    /// How far ahead a window reaches, as a function of the call-distance
    /// setting: past the furthest a note is ever called, with room to spare so
    /// the rebuild lands before a corner needs calling rather than during it.
    nonisolated public static func lookaheadMeters(callScale: Double) -> Double {
        max(900, 400 * callScale * 2.5)
    }

    /// How close two apexes have to be to count as the same corner.
    ///
    /// Matching is by proximity rather than identity because a rebuild
    /// re-derives a corner from a window that starts somewhere else: the
    /// pacenote resampling grid is measured from the start of the window, so
    /// the same physical corner comes back with an apex a few metres from where
    /// it was. Two corners closer than this are one movement as far as the
    /// generator is concerned — it merges those itself — so this cannot silence
    /// two real corners.
    nonisolated public static let apexMatchMeters: Double = 15

    /// A build that found nothing waits this far, or this long, before trying
    /// again. Without it, a car on a road the tiles do not carry would schedule
    /// a rebuild on every one of the 20 ticks a second, forever.
    nonisolated public static let retryMeters: Double = 50
    nonisolated public static let retrySeconds: TimeInterval = 5

    /// How far the car must travel, and how long it must take, before the router
    /// is asked again for the line ahead.
    ///
    /// The router is a public demo server that asks for light use, and this runs
    /// inside a 20Hz recorder on a phone that may have no signal at all. A
    /// routed window covers the whole horizon, so it does not need asking for
    /// often — and the tile path is always tried first, so on a road the tiles
    /// carry this costs nothing at all.
    nonisolated public static let networkRetryMeters: Double = 200
    nonisolated public static let networkRetrySeconds: TimeInterval = 20

    /// The longer wait after the router failed, which usually means there is no
    /// connection rather than that the road is unroutable. Backing off hard
    /// keeps a drive through a dead zone from spending its battery on timeouts.
    nonisolated public static let networkBackoffSeconds: TimeInterval = 60

    /// How far past the window the router is asked to route.
    ///
    /// A little beyond, so the line does not stop exactly where the window does
    /// and leave a truncated polyline at the far end. The window still cuts at
    /// its own horizon — this only buys a clean ending to route to.
    nonisolated public static let networkRouteMarginMeters: Double = 150

    // MARK: - State

    private let loader: RoadLoader
    /// The fallback for roads the tiles do not carry. Nil means tiles-only, which
    /// is what the tests use unless they are specifically exercising this.
    private let lineLoader: LineLoader?
    private let backfillMeters: Double
    private let toleranceMeters: Double
    private var lookaheadMeters: Double
    private var callDistanceScale: Double

    private var navigator: PacenoteNavigator?
    /// Apexes of the corners already called this drive. Survives every rebuild —
    /// it is what stops a rebuild from re-announcing the corner the driver was
    /// told about thirty seconds ago.
    private var calledApexes: [GeoPoint] = []
    /// Whether a build is scheduled or running. Taken synchronously where it is
    /// scheduled: `update` runs 20 times a second, and a task started from two
    /// of those ticks would build the same window twice.
    private var buildScheduled = false
    private var lastAttemptAt: Date?
    private var lastAttemptPoint: GeoPoint?
    /// When the router was last asked, and from where. Rate-limiting a public
    /// demo server from inside a drive recorder.
    private var lastNetworkAt: Date?
    private var lastNetworkPoint: GeoPoint?
    /// Set when the router came back empty, which is nearly always a dead zone
    /// rather than an unroutable road.
    private var networkFailed = false
    private var windowRoadName: String?

    /// Bumped whenever a new window is installed, so the HUD can tell a fresh
    /// line and a fresh set of corner markers from the ones it already has.
    public private(set) var windowRevision = 0

    /// Called when no window could be built and the bundle looks like it holds no
    /// road data at all — the one failure a driver needs to hear about, because
    /// otherwise the co-driver is silent and nothing says why.
    public var onRoadDataAbsent: (() -> Void)?

    /// Called once per drive when neither the tiles nor the router can describe
    /// the road ahead — no scored road nearby and no signal, which is a
    /// different problem from a build with no road data in it and deserves a
    /// different word. Said once: a co-driver that repeats itself every rebuild
    /// is worse than one that stays quiet.
    public var onRoadUnavailable: (() -> Void)?
    private var warnedUnavailable = false
// MARK: - Init

    /// The production source: reads the bundled tile for wherever the car is,
    /// and asks the router for the line ahead when the tiles have nothing.
    ///
    /// A tile is one 0.25° square, so a road crossing into the next one is cut
    /// short at the boundary and picked up by the next rebuild — the window is a
    /// few hundred metres behind the car by then, so the seam is never a gap in
    /// the calls.
    ///
    /// The router is the same `RoutePlanner` the segment mode already uses, and
    /// it is what makes an unplanned drive work on a road nobody has ever
    /// scored: route from where the car is to a point ahead of it along its
    /// heading, and the driving line that comes back is a road like any other.
    public convenience init(callDistanceScale: Double = 1.0) {
        self.init(loader: { coordinate in
            (try? await LocalRoadSource.shared.fetchRoads(lat: coordinate.latitude,
                                                          lon: coordinate.longitude)) ?? []
        }, lineLoader: { coordinate, course, lookahead in
            let ahead = GeoMath.destination(GeoPoint.from(coordinate),
                                            lookahead + Self.networkRouteMarginMeters,
                                            course)
            guard let road = try? await RoutePlanner.shared.road(from: coordinate,
                                                                   to: ahead.clLocation)
            else { return [] }
            return [road]
        }, callDistanceScale: callDistanceScale)
    }

    public init(loader: @escaping RoadLoader,
                lineLoader: LineLoader? = nil,
                callDistanceScale: Double = 1.0,
                backfillMeters: Double = LivePacenoteSource.backfillMeters,
                lookaheadMeters: Double? = nil,
                toleranceMeters: Double = LivePacenoteSource.toleranceMeters) {
        self.loader = loader
        self.lineLoader = lineLoader
        self.callDistanceScale = callDistanceScale
        self.backfillMeters = backfillMeters
        self.toleranceMeters = toleranceMeters
        self.lookaheadMeters = lookaheadMeters
            ?? LivePacenoteSource.lookaheadMeters(callScale: callDistanceScale)
    }

    public func setCallDistanceScale(_ scale: Double) {
        guard scale != callDistanceScale else { return }
        callDistanceScale = scale
        lookaheadMeters = Self.lookaheadMeters(callScale: scale)
    }

    // MARK: - Driving

    /// Feeds a fix and returns the call to speak, if there is one.
    ///
    /// Synchronous, because it runs on the 20Hz fusion tick: the window rebuild
    /// it may schedule is async and never blocks the tick. The first fix of a
    /// drive therefore returns nothing — there is no window yet — and calls start
    /// a few ticks later, which is the same few ticks a planned route takes to
    /// lock its direction.
    @discardableResult
    public func update(location: CLLocation, speed: Double) -> PacenoteCall? {
        var call: PacenoteCall?
        if let navigator {
            call = navigator.update(location: location, speed: speed)
            if let call {
                for item in call.items { remember(item.note.apex) }
            }
        }
        if shouldRebuild(at: location) {
            buildScheduled = true
            Task { [weak self] in
                await self?.buildWindow(at: location)
            }
        }
        return call
    }

    /// Builds a window from `location` if one is due; returns whether one was
    /// installed.
    ///
    /// Public because it is the seam the tests drive: a test needs the window
    /// built before it can expect a call, and awaiting this is how.
    @discardableResult
    public func rebuild(at location: CLLocation) async -> Bool {
        guard !buildScheduled else { return false }
        buildScheduled = true
        return await buildWindow(at: location)
    }

    /// The build itself, with the caller already holding `buildScheduled`.
    ///
    /// Split out because of who takes that flag. `update` has to take it
    /// *synchronously*, because it runs 20 times a second and two ticks would
    /// otherwise start two identical builds — but a scheduled task that then
    /// called `rebuild` would find the flag set by the very tick that scheduled
    /// it, refuse to run, and leave the flag latched: no window, ever again. So
    /// the scheduled task comes here instead, where the flag is assumed rather
    /// than tested — and released here, whoever set it.
    private func buildWindow(at location: CLLocation) async -> Bool {
        defer { buildScheduled = false }
        lastAttemptAt = Date()
        lastAttemptPoint = GeoPoint.from(location.coordinate)
        let roads = await loader(location.coordinate)

        // The tiles first, always. They are on the phone, free, and instant, and
        // on a scored road this is the whole of the work — no request, no
        // waiting, no signal needed.
        if let window = Self.window(at: location.coordinate,
                                    course: location.course,
                                    roads: roads,
                                    backfillMeters: backfillMeters,
                                    lookaheadMeters: lookaheadMeters,
                                    toleranceMeters: toleranceMeters,
                                    alreadyCalled: calledApexes) {
            return install(window)
        }

        if roads.isEmpty, LocalRoadSource.roadDataLooksAbsent { onRoadDataAbsent?() }
        return await buildWindowFromRouter(at: location)
    }

    /// The fallback: ask the router for the driving line ahead, and window it
    /// exactly as a tile road would be windowed.
    ///
    /// This is what makes an unplanned drive work anywhere OSM has data, not
    /// just on the roads someone scored and compiled into a tile. It costs a
    /// network round trip per window, so it is gated hard — and it is only ever
    /// reached once the tiles have already come up empty, so a drive on a tiled
    /// road never touches it.
    private func buildWindowFromRouter(at location: CLLocation) async -> Bool {
        guard let lineLoader, shouldAskRouter(at: location) else { return false }

        lastNetworkAt = Date()
        lastNetworkPoint = GeoPoint.from(location.coordinate)
        let lines = await lineLoader(location.coordinate, location.course, lookaheadMeters)
        networkFailed = lines.isEmpty
        if networkFailed, !warnedUnavailable {
            warnedUnavailable = true
            onRoadUnavailable?()
        }

        // Same call, same trimming, same orientation test as the tile path: a
        // routed line is just a road that happened to arrive over the network.
        guard let window = Self.window(at: location.coordinate,
                                       course: location.course,
                                       roads: lines,
                                       backfillMeters: backfillMeters,
                                       lookaheadMeters: lookaheadMeters,
                                       toleranceMeters: toleranceMeters,
                                       alreadyCalled: calledApexes)
        else { return false }
        return install(window)
    }

    /// Whether the router may be asked again yet.
    ///
    /// Needs a heading — the line is routed to a point ahead *along it*, and a
    /// fix with no course has no "ahead". Then the distance-and-time floor, which
    /// is longer after a failure because an empty answer is nearly always a dead
    /// zone rather than an unroutable road.
    private func shouldAskRouter(at location: CLLocation) -> Bool {
        guard location.course >= 0, location.course.isFinite else { return false }
        guard let last = lastNetworkAt, let point = lastNetworkPoint else { return true }
        let floor = networkFailed ? Self.networkBackoffSeconds : Self.networkRetrySeconds
        guard Date().timeIntervalSince(last) >= floor else { return false }
        return GeoMath.distanceMeters(point, GeoPoint.from(location.coordinate))
            >= Self.networkRetryMeters
    }

    private func install(_ window: Window) -> Bool {
        navigator = PacenoteNavigator(coordinates: window.coordinates,
                                      pacenotes: window.pacenotes,
                                      callDistanceScale: callDistanceScale)
        windowRoadName = window.roadName
        windowRevision += 1
        return true
    }

    // MARK: - Reading the window

    /// The next corners, for the HUD's "coming up" line.
    ///
    /// Taken from the window rather than from `PacenoteNavigator.upcoming`
    /// because that one walks the cursor, and a freshly built window starts its
    /// cursor at the backfill — behind the car — so the HUD would show corners
    /// the driver has already passed.
    public func upcoming(count: Int) -> [Pacenote] {
        guard let navigator else { return [] }
        return navigator.pacenotes
            .filter { $0.startDist > navigator.progressDistance }
            .filter { !Self.isAlreadyCalled($0.apex, in: calledApexes) }
            .prefix(count)
            .map { $0 }
    }

    /// The road ahead, for the HUD's line. Empty until the first window lands.
    public var routeCoordinates: [CLLocationCoordinate2D] { navigator?.coordinates ?? [] }

    public var annotations: [TurnMarker] {
        (navigator?.pacenotes ?? []).map {
            TurnMarker(coordinate: $0.apex.clLocation, title: $0.text, subtitle: "")
        }
    }

    public var offRoute: Bool { navigator?.offRoute ?? false }
    public var isActive: Bool { navigator != nil }
    /// The road the current window came from, for naming the drive.
    public var roadName: String? { windowRoadName }

    /// The stretch of road ahead of `coordinate`, and the notes for it.
    ///
    /// Pure, and the whole of the feature's geometry: everything else in this
    /// type is scheduling around it. `course` orients the window — the tiles
    /// store each road in whichever direction it was collected, which has
    /// nothing to do with the car, and pacenotes are direction-sensitive.
    public static func window(at coordinate: CLLocationCoordinate2D,
                              course: Double,
                              roads: [TougeRoad],
                              backfillMeters: Double = backfillMeters,
                              lookaheadMeters: Double,
                              toleranceMeters: Double = toleranceMeters,
                              alreadyCalled: [GeoPoint] = []) -> Window? {
        guard let snap = RoadSegmentBuilder.snap(coordinate, in: roads,
                                                 toleranceMeters: toleranceMeters)
        else { return nil }

        let coords = snap.road.geoPoints
        let cumulative = GeoMath.cumulativeDistances(coords)
        let total = cumulative.last ?? 0
        let lo = max(0, snap.distanceAlongRoad - backfillMeters)
        let hi = min(total, snap.distanceAlongRoad + lookaheadMeters)
        guard hi - lo >= minimumWindowMeters else { return nil }

        // A course of -1 — or anything non-finite — means the fix carries no
        // heading, which is what a stationary car reports. The road's own order
        // is used then, and the navigator's own direction detection reverses the
        // whole window, notes and all, once there is a real course to detect
        // with. Guessing here would be worse than waiting: a window facing the
        // wrong way calls every left that is really a right.
        var forward = true
        if course >= 0, course.isFinite {
            let downstream = GeoMath.bearingAtDistance(coords, cumulative: cumulative,
                                                      distance: min(total, snap.distanceAlongRoad + 30))
            forward = abs(GeoMath.wrap180(course - downstream)) <= 90
        }

        guard let points = RoadSegmentBuilder.stretch(of: snap.road, from: lo, to: hi,
                                                       forward: forward),
              points.count >= 2
        else { return nil }

        // The planned pipeline, unchanged, on the window instead of the route.
        // Corners already called are dropped: a rebuild regenerates everything
        // inside its overlap with the window it replaces, and re-announcing a
        // corner the driver was just told about is the single most obvious way
        // this could embarrass itself.
        var notes = PacenoteGenerator.generate(points).turns
        notes.removeAll { isAlreadyCalled($0.apex, in: alreadyCalled) }

        return Window(coordinates: points.map(\.clLocation), pacenotes: notes,
                      roadID: snap.road.id, roadName: snap.road.name)
    }

    public static func isAlreadyCalled(_ apex: GeoPoint, in called: [GeoPoint]) -> Bool {
        called.contains { GeoMath.distanceMeters(apex, $0) < apexMatchMeters }
    }

    // MARK: - Rebuild policy

    private func shouldRebuild(at location: CLLocation) -> Bool {
        guard !buildScheduled else { return false }
        guard let navigator else { return retryElapsed(at: location) }

        // The window is nearly spent: rebuild while there is still road ahead,
        // not once the last corner of it has gone by.
        let remaining = navigator.totalLength - navigator.progressDistance
        if !navigator.offRoute {
            return remaining <= max(200, navigator.maximumCallDistance * 0.75)
        }
        // Off the road the window came from. Rate-limited like a failed build,
        // because it usually means the car is somewhere the tiles do not
        // describe, and retrying at the tick rate would burn the battery for
        // nothing.
        return retryElapsed(at: location)
    }

    private func retryElapsed(at location: CLLocation) -> Bool {
        guard let lastAt = lastAttemptAt, let lastPoint = lastAttemptPoint else { return true }
        if Date().timeIntervalSince(lastAt) >= Self.retrySeconds { return true }
        return GeoMath.distanceMeters(lastPoint, GeoPoint.from(location.coordinate))
            >= Self.retryMeters
    }

    private func remember(_ apex: GeoPoint) {
        // One entry per corner, not one per call for the whole drive: an entry a
        // newer corner has replaced can no longer match anything still in front
        // of the car.
        calledApexes.removeAll { GeoMath.distanceMeters(apex, $0) < Self.apexMatchMeters }
        calledApexes.append(apex)
    }

    // MARK: - Reset

    public func reset() {
        navigator = nil
        calledApexes = []
        buildScheduled = false
        lastAttemptAt = nil
        lastAttemptPoint = nil
        lastNetworkAt = nil
        lastNetworkPoint = nil
        networkFailed = false
        windowRoadName = nil
        windowRevision = 0
    }
}