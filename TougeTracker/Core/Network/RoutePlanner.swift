import Foundation
import CoreLocation

/// Turns an arbitrary pair of map taps into a drivable road, by asking a
/// router built on OpenStreetMap data how to drive between them.
///
/// The bundled tiles only cover scored touge roads, and MapKit exposes no
/// geometry for the base map, so `RoadSegmentBuilder` can only carve segments
/// out of roads we already hold. This covers everything else: the user taps a
/// start and an end anywhere — a back road, a forest service road, anything the
/// app has never seen — and gets back the full driving line between them with
/// its real length, which then feeds the unchanged pacenote / save / drive
/// pipeline.
public final class RoutePlanner: @unchecked Sendable {

    public static let shared = RoutePlanner()

    /// Public OSRM demo server. Its usage policy asks for light, occasional
    /// use with an identifying User-Agent, which is exactly what a tap-driven
    /// lookup is.
    ///
    /// The trailing slash is load-bearing: the coordinate path is resolved
    /// relative to this base, and against a slash-less base the last component
    /// gets replaced — which drops the `driving` profile and yields a malformed
    /// URL the server rejects.
    private let endpoint: URL
    /// Overpass, used only to read the name of the road at the first tap. It is
    /// a separate service from the router, so it is configured independently.
    private let overpassEndpoint: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(endpoint: URL = URL(string: "https://router.project-osrm.org/route/v1/driving/")!,
                overpassEndpoint: URL = URL(string: "https://overpass-api.de/api/interpreter")!,
                session: URLSession = .shared) {
        self.endpoint = endpoint
        self.overpassEndpoint = overpassEndpoint
        self.session = session
    }

    public enum Failure: Error, Equatable {
        /// No drivable connection exists between the two taps.
        case noRoute
        /// The two taps are effectively the same spot.
        case tooShort
        /// The network request or the JSON parse failed.
        case requestFailed(String)
    }

    /// Under this, the router has nothing worth showing and the pacenote
    /// resampling would be degenerate. ~20m is well under one car length, so a
    /// genuine double-tap on one spot is the only realistic way to hit it.
    private let minimumLengthMeters: Double = 20

    /// Cache keyed by the snapped endpoints, so re-running the same two taps
    /// does not re-hit the router.
    private var cache: [String: TougeRoad] = [:]
    /// Junctions for a cached line. Held beside the road rather than inside it
    /// so `TougeRoad` stays the plain geometry every other caller expects.
    private var cachedFeatures: [String: [FeatureNote]] = [:]
    /// The junctions from the request currently being decoded.
    ///
    /// `route(through:)` is the one place that parses the response, and this is
    /// how they reach `line(through:)`. The router is called one drive at a time
    /// from the live source, and the value is consumed immediately after the
    /// await — but it is deliberately not folded into a return type that
    /// `route(from:to:)` would then have to unpack and throw away.
    private var lastFeatures: [FeatureNote] = []
    private let cacheLock = NSLock()

    // MARK: - Public API

    /// Routes a driving line from `start` to `end` and returns it as a
    /// `TougeRoad` carrying the real measured length.
    ///
    /// `name` is the caller's best knowledge of the road at `start` (see
    /// `roadName(near:)`). It is passed in rather than resolved here so the
    /// name lookup happens once at the first tap, in parallel with the user
    /// choosing their end point, instead of adding a second round-trip after
    /// the route itself.
    public func road(from start: CLLocationCoordinate2D,
                     to end: CLLocationCoordinate2D,
                     name: String? = nil) async throws -> TougeRoad {
        try await road(through: [start, end], name: name)
    }

    /// Routes a driving line through an ordered list of points and returns it as
    /// a `TougeRoad` carrying the real measured length.
    ///
    /// The list is the whole itinerary in driving order. Two points is the
    /// ordinary start/end case; three or more threads the route through
    /// waypoints, because the router treats every point after the first as a
    /// via — that is what makes a multi-stop route one continuous driving line
    /// rather than a chain of separate legs the user has to stitch together.
    public func road(through points: [CLLocationCoordinate2D],
                     name: String? = nil) async throws -> TougeRoad {
        // The contract is "at least two points". A one-point route has no
        // direction, and letting it through would return a degenerate line.
        guard points.count >= 2 else { throw Failure.tooShort }

        let key = cacheKey(points)
        if let hit = cached(key) { return hit }

        let line = try await line(through: points, name: name)
        store(key, road: line.road)
        return line.road
    }

    /// A routed driving line and the junctions on it.
    ///
    /// The geometry is the road; the features are what the co-driver cannot see
    /// in it — a road ending, a lane joining — and they come from the same
    /// response. There is no second request: the router lists every junction on
    /// the line whether or not anyone asks it to.
    public struct RoutedLine: Sendable {
        public var road: TougeRoad
        /// Junctions in metres from the start of `road`.
        public var features: [FeatureNote]
    }

    /// The two-point spelling of `line(through:)`, so a caller that only has a
    /// start and an end reads as what it is.
    public func line(from start: CLLocationCoordinate2D,
                     to end: CLLocationCoordinate2D,
                     name: String? = nil) async throws -> RoutedLine {
        try await line(through: [start, end], name: name)
    }

    /// Routes a driving line through an ordered list of points and returns it
    /// with the junctions along it.
    public func line(through points: [CLLocationCoordinate2D],
                     name: String? = nil) async throws -> RoutedLine {
        // The contract is "at least two points". A one-point route has no
        // direction, and letting it through would return a degenerate line.
        guard points.count >= 2 else { throw Failure.tooShort }

        let key = cacheKey(points)
        if let hit = cached(key) {
            return RoutedLine(road: hit, features: cachedFeatures[key] ?? [])
        }

        let routed = try await route(through: points)
        guard GeoMath.lengthMeters(routed) >= minimumLengthMeters else {
            throw Failure.tooShort
        }

        // A real road name beats the length-based fallback; whitespace-only
        // counts as absent.
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmed?.isEmpty == false) ? trimmed! : defaultName(for: routed)

        let road = makeRoad(points: routed, name: finalName)
        let features = lastFeatures
        cachedFeatures[key] = features
        store(key, road: road)
        return RoutedLine(road: road, features: features)
    }


    // MARK: - Road naming

    /// Best-effort name of the road at `coordinate`, for naming a route.
    ///
    /// Returns nil when the road is unnamed or the lookup fails — naming is a
    /// nicety, so it must never fail the route the user actually asked for.
    public func roadName(near coordinate: CLLocationCoordinate2D) async -> String? {
        await nameTask(coordinate)?.value
    }

    /// The in-flight name lookup, if any. The view starts this at the first tap
    /// and awaits it once the end point is chosen, so the name request overlaps
    /// the user's second tap rather than delaying it.
    private var nameTasks: [String: Task<String?, Never>] = [:]
    private var nameTaskOrder: [String] = []

    /// Cached road-name lookups, one per distinct tapped coordinate.
    ///
    /// A session can tap a lot of coordinates and the cache was never trimmed,
    /// so it grew for as long as the app was open. The planner is reused for
    /// the whole session and coordinates are not revisited, so evicting the
    /// oldest costs nothing and bounds the memory.
    private static let nameCacheLimit = 50
    private let nameLock = NSLock()

    private func nameTask(_ coordinate: CLLocationCoordinate2D) -> Task<String?, Never>? {
        let key = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        nameLock.lock(); defer { nameLock.unlock() }
        if let existing = nameTasks[key] { return existing }
        let task = Task<String?, Never> { [weak self] in
            await self?.lookupRoadName(near: coordinate)
        }
        nameTasks[key] = task
        nameTaskOrder.append(key)
        if nameTaskOrder.count > Self.nameCacheLimit {
            for stale in nameTaskOrder.prefix(nameTaskOrder.count - Self.nameCacheLimit) {
                nameTasks[stale]?.cancel()
                nameTasks[stale] = nil
            }
            nameTaskOrder.removeFirst(nameTaskOrder.count - Self.nameCacheLimit)
        }
        return task
    }

    /// Asks Overpass for the name of the nearest named way to the tap.
    ///
    /// A tight radius is deliberate: the name should describe the road the user
    /// put their finger on, not whatever passes within a few hundred metres.
    private func lookupRoadName(near coordinate: CLLocationCoordinate2D) async -> String? {
        // Overpass answers 406 to a generic agent, so identify ourselves.
        let query = """
        [out:json][timeout:15];
        way["highway"]["name"](around:25,\
        \(coordinate.latitude),\(coordinate.longitude));
        out tags 1;
        """
        guard let data = try? await send(postRequest(url: overpassEndpoint, body: query)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]],
              let tags = elements.first?["tags"] as? [String: String],
              let name = tags["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    // MARK: - Routing

    /// GeoJSON `LineString`: `[[lon, lat], …]`. A tuple of points would be
    /// lighter, but routing is a network call and JSON is what we get back.
    private struct LineString: Decodable {
        let coordinates: [[Double]]
    }

    private struct Route: Decodable {
        let code: String
        let routes: [Leg]?

        struct Leg: Decodable {
            let geometry: LineString
            /// Metres, straight from the router. We still measure ourselves
            /// (see `makeRoad`) so the displayed length always comes from the
            /// app's own haversine, not from a server's rounding.
            let distance: Double?
            /// One per road the line uses, so every junction on the route is a
            /// boundary between two of them. Absent unless `steps=true`.
            let steps: [Step]?
        }

        struct Step: Decodable {
            let distance: Double?
            let maneuver: Maneuver?
        }

        struct Maneuver: Decodable {
            let type: String?
        }
    }

    /// The driving line between exactly two points.
    ///
    /// Kept as a two-point spelling of `route(through:)` so callers that only
    /// have a start and an end read as what they are.
    func route(from start: CLLocationCoordinate2D,
               to end: CLLocationCoordinate2D) async throws -> [GeoPoint] {
        try await route(through: [start, end])
    }

    /// The driving line through an ordered list of points.
    func route(through points: [CLLocationCoordinate2D]) async throws -> [GeoPoint] {
        // OSRM wants lon,lat — the reverse of the lat/lon taps we hold. Every
        // point after the first is a via, so N points give one continuous line
        // through them in order.
        var components = URLComponents()
        components.path = points
            .map { String(format: "%f,%f", $0.longitude, $0.latitude) }
            .joined(separator: ";")
        // `overview=full` returns the complete geometry; the default
        // simplification would visibly straighten the corners and shorten
        // the measured length.
        components.queryItems = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            // The router sends a full list of every junction on the line only
            // when asked. It was returning an empty array before, unread, on
            // every request — the data for the intersection warnings was already
            // coming back and being thrown away.
            URLQueryItem(name: "steps", value: "true")
        ]
        // The endpoint must end in a slash. Resolving a relative path against
        // a slash-less base replaces the base's last component, which silently
        // produced `.../route/v1/<coords>` and dropped the `driving` profile —
        // the server rejected that with HTTP 400 "URL string malformed".
        guard let url = components.url(relativeTo: endpoint) else {
            throw Failure.requestFailed("Could not build the routing URL")
        }
        // Belt and braces: a malformed path is a bug, not a transport problem,
        // so fail loudly in development rather than as a generic network error.
        assert(url.absoluteString.contains("/route/v1/driving/"),
               "routing URL lost its profile segment: \(url)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("TougeTracker/1.0 (iOS touge pacenote app)",
                         forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.requestFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.requestFailed("HTTP \(http.statusCode)")
        }

        let decoded: Route
        do {
            decoded = try decoder.decode(Route.self, from: data)
        } catch {
            throw Failure.requestFailed("Could not read the routing response")
        }

        // OSRM answers 200 with a `code` of "NoRoute" when the two points are
        // simply not connected by a drivable road, so `code` must be checked
        // before the payload is trusted.
        guard decoded.code == "Ok" else { throw Failure.noRoute }
        // A single-position line is not a routing failure — it is a degenerate
        // result, so it is passed through and rejected by the length check in
        // `road(from:to:)` with a clearer `tooShort`.
        guard let coordinates = decoded.routes?.first?.geometry.coordinates,
              !coordinates.isEmpty else { throw Failure.noRoute }

        let line = coordinates.compactMap { pair -> GeoPoint? in
            // Each position is [lon, lat]; a malformed pair is dropped rather
            // than crashing the tap.
            guard pair.count >= 2 else { return nil }
            return GeoPoint(lon: pair[0], lat: pair[1])
        }
        lastFeatures = Self.features(from: decoded.routes?.first?.steps)
        return line
    }

    /// Junctions along the line, in metres from its start.
    ///
    /// A step's `distance` is the length of the road *before* it, so the running
    /// total is where the road changes — which is where the junction is. Walking
    /// a list of steps rather than asking the server for positions is what makes
    /// this work: OSRM gives geometry and steps separately, and the two are
    /// related by nothing but their order.
    private static func features(from steps: [Route.Step]?) -> [FeatureNote] {
        var travelled = 0.0
        var out: [FeatureNote] = []
        for (index, step) in (steps ?? []).enumerated() {
            if index > 0, let type = step.maneuver?.type,
               let feature = RoadFeature(routerManeuver: type) {
                out.append(FeatureNote(distance: travelled, feature: feature))
            }
            travelled += step.distance ?? 0
        }
        return out
    }

    /// Runs an Overpass query and returns its raw JSON.
    ///
    /// Public because the live pacenote source asks the same service a different
    /// question — the signs on this road rather than the name of it — and two
    /// copies of "post to Overpass" means one of them is wrong in a way nothing
    /// notices.
    public func overpass(_ query: String) async throws -> Data {
        try await send(postRequest(url: overpassEndpoint, body: query))
    }

    /// Builds a POST for the Overpass form-encoded `data` convention.
    private func postRequest(url: URL, body: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        // Overpass rejects a generic/absent agent with HTTP 406.
        request.setValue("TougeTracker/1.0 (iOS touge pacenote app)",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("data=\(Self.formEncoded(body))".utf8)
        return request
    }

    /// Percent-encodes only what a form body actually reserves.
    ///
    /// This was `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`,
    /// which is the wrong tool: it escapes `[ ] ~ ( ) | ^ $` and the spaces — all
    /// of which are the query language itself. Overpass does not reject that, it
    /// answers with an HTML error page, and an HTML error page parses to nothing,
    /// so every query this app ever sent came back empty and said so by saying
    /// nothing at all. The road-name lookup has been quietly returning nil for the
    /// same reason since it was written.
    private static func formEncoded(_ body: String) -> String {
        var out = ""
        for byte in body.utf8 {
            let scalar = UnicodeScalar(byte)
            switch scalar {
            case "&", "+", "%", "=":
                out += String(format: "%%%02X", byte)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.requestFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Helpers

    /// Names the result by its length. The routed line is a user-chosen stretch
    /// with no name we can know, and the length is the only handle that keeps
    /// several of them apart in the saved-routes list.
    private func defaultName(for points: [GeoPoint]) -> String {
        "Route \(Int((GeoMath.lengthMeters(points) / 1609.344 * 10).rounded()) / 10) mi"
    }

    private func cacheKey(_ points: [CLLocationCoordinate2D]) -> String {
        // ~1m resolution: fine enough to hit on a re-tap of the same points,
        // coarse enough that float noise cannot cause a miss. The order matters,
        // because a route driven A→B→C is not the same line as C→B→A.
        points
            .map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
            .joined(separator: "->")
    }

    private func cached(_ key: String) -> TougeRoad? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }

    private func store(_ key: String, road: TougeRoad) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[key] = road
    }

    /// Wraps the routed line as a `TougeRoad`.
    ///
    /// The id is derived from the geometry, so re-running the same two taps
    /// upserts one saved route instead of creating duplicates. The high bit
    /// keeps it clear of both the tile FNV ids and
    /// `RoadSegmentBuilder`'s user-segment bit.
    private func makeRoad(points: [GeoPoint], name: String) -> TougeRoad {
        let meters = GeoMath.lengthMeters(points)
        let lats = points.map(\.lat)
        let lons = points.map(\.lon)
        let key = points.map { "\(Int(($0.lat * 100_000).rounded())),\(Int(($0.lon * 100_000).rounded()))" }
                        .joined(separator: ";")
        // `stableId` is already forced positive by TougeRoad, so setting the
        // high bit afterwards cannot overflow.
        let id = TougeRoad.stableId(from: "route:\(key)") | 0x6000_0000_0000_0000

        return TougeRoad(
            id: id, name: name, type: "route",
            coordinates: points.map { [$0.lon, $0.lat] },
            lengthMiles: meters / 1609.344,
            curvatureScore: nil, flowScore: nil, totalScore: nil,
            centerLat: (lats.min()! + lats.max()!) / 2,
            centerLon: (lons.min()! + lons.max()!) / 2
        )
    }
}

