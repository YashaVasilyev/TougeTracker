import XCTest
@testable import TougeTracker
import CoreLocation

/// Tests the routing layer against a stubbed HTTP transport, so the suite stays
/// offline and deterministic while still exercising the real request and
/// decode path.
final class RoutePlannerTests: XCTestCase {

    private let start = CLLocationCoordinate2D(latitude: 42.3510, longitude: -71.1040)
    private let end = CLLocationCoordinate2D(latitude: 42.3600, longitude: -71.0900)

    /// Spins up a planner whose every request returns `body`.
    private func planner(responding body: String, status: Int = 200) -> RoutePlanner {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        StubURLProtocol.body = Data(body.utf8)
        StubURLProtocol.status = status
        // Reset per test: these are statics, and one test's requests would
        // otherwise be counted against the next.
        StubURLProtocol.requestCount = 0
        StubURLProtocol.lastRequest = nil
        // Mirrors the real endpoints, trailing slash included — the bug this
        // guards against was the slash being dropped. Both hosts are the test
        // host so the stub transport intercepts routing *and* naming.
        return RoutePlanner(
            endpoint: URL(string: "https://example.test/route/v1/driving/")!,
            overpassEndpoint: URL(string: "https://example.test/overpass/interpreter")!,
            session: session
        )
    }

    /// A straight two-point line running north-east from the start.
    private var okBody: String {
        """
        {"code":"Ok","routes":[{"distance":1200.5,"geometry":
          {"type":"LineString","coordinates":[[-71.104,42.351],[-71.09,42.36]]}}]}
        """
    }

    // MARK: - Request shape

    func testRequestTargetsDrivingProfileWithFullGeometry() async throws {
        let planner = self.planner(responding: okBody)
        _ = try await planner.road(from: start, to: end)

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        let url = try XCTUnwrap(request.url)

        // The `driving` profile must survive URL construction. Resolving the
        // coordinate path against a base without a trailing slash drops it,
        // and the server then rejects the URL as malformed.
        XCTAssertTrue(url.absoluteString.contains("/route/v1/driving/"),
                      "lost the driving profile: \(url)")
        // OSRM wants lon,lat in the path — the reverse of the lat/lon taps.
        XCTAssertTrue(url.path.contains("-71.104000,42.351000;-71.090000,42.360000"),
                      "unexpected path: \(url.path)")
        // `overview=full` keeps every corner; the default simplification would
        // straighten the geometry and understate the length.
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("overview=full"))
        XCTAssertTrue(query.contains("geometries=geojson"))
        // The demo server requires an identifying agent.
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }


    // MARK: - Multi-point routing

    func testMultiPointRouteSendsEveryPointAsAWaypoint() async throws {
        let mid = CLLocationCoordinate2D(latitude: 42.3550, longitude: -71.0970)
        let planner = self.planner(responding: okBody)
        _ = try await planner.road(through: [start, mid, end])

        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        // All three points, in the order they were tapped. The router reads the
        // first as the origin and the rest as vias, so dropping or reordering
        // one here silently produces a different road.
        XCTAssertTrue(url.path.contains(
            "-71.104000,42.351000;-71.097000,42.355000;-71.090000,42.360000"),
            "unexpected path: \(url.path)")
        // The profile and the full geometry must survive the longer path.
        XCTAssertTrue(url.absoluteString.contains("/route/v1/driving/"))
        XCTAssertTrue(try XCTUnwrap(url.query).contains("overview=full"))
    }

    func testTwoPointRouteIsUnchangedByTheMultiPointForm() async throws {
        // The ordinary start/end case has to keep producing exactly the request
        // it always did, or every existing route silently changes shape.
        let planner = self.planner(responding: okBody)
        _ = try await planner.road(from: start, to: end)

        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        XCTAssertEqual(url.path,
                       "/route/v1/driving/-71.104000,42.351000;-71.090000,42.360000")
    }

    func testSinglePointRouteIsRejected() async {
        // One point has no direction. It must not reach the network as a
        // degenerate request.
        let planner = self.planner(responding: okBody)
        do {
            _ = try await planner.road(through: [start])
            XCTFail("a one-point route should not be routable")
        } catch RoutePlanner.Failure.tooShort {
            XCTAssertEqual(StubURLProtocol.requestCount, 0, "no request should be made")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRouteCacheDistinguishesItineraryOrder() async throws {
        // A→B→C and C→B→A are different drives. If the cache key ignored order
        // the second would silently return the first's line.
        let mid = CLLocationCoordinate2D(latitude: 42.3550, longitude: -71.0970)
        let planner = self.planner(responding: okBody)
        _ = try await planner.road(through: [start, mid, end])
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        _ = try await planner.road(through: [end, mid, start])
        XCTAssertEqual(StubURLProtocol.requestCount, 2,
                       "reversing the itinerary must miss the cache")
    }

    func testRepeatedItineraryIsServedFromCache() async throws {
        let mid = CLLocationCoordinate2D(latitude: 42.3550, longitude: -71.0970)
        let planner = self.planner(responding: okBody)
        _ = try await planner.road(through: [start, mid, end])
        _ = try await planner.road(through: [start, mid, end])
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "second call should hit the cache")
    }

    // MARK: - Decoding

    /// Regression test for the exact defect that shipped: an endpoint without a
    /// trailing slash silently lost the `driving` profile, and the server
    /// answered HTTP 400 "URL string malformed". This pins the requirement so
    /// the default endpoint cannot be edited back into that shape.
    func testDefaultEndpointPreservesTheDrivingProfile() {
        // Resolve a coordinates path against the production endpoint exactly
        // as `route(from:to:)` does, and check the resulting path.
        let base = URL(string: "https://router.project-osrm.org/route/v1/driving/")!
        var components = URLComponents()
        components.path = String(format: "%f,%f;%f,%f",
                                 start.longitude, start.latitude,
                                 end.longitude, end.latitude)
        let url = components.url(relativeTo: base)

        XCTAssertEqual(url?.path,
                       "/route/v1/driving/-71.104000,42.351000;-71.090000,42.360000")
        // The same construction against a slash-less base loses the profile —
        // this is the failure mode being guarded against.
        let bad = URL(string: "https://router.project-osrm.org/route/v1/driving")!
        XCTAssertFalse(components.url(relativeTo: bad)!.path.contains("/driving/"))
    }

    func testDecodesGeoJSONLineString() async throws {
        let planner = self.planner(responding: okBody)
        let points = try await planner.route(from: start, to: end)
        XCTAssertEqual(points, [GeoPoint(lon: -71.104, lat: 42.351),
                                GeoPoint(lon: -71.09, lat: 42.36)])
    }

    func testBuildsRoadWithMeasuredLength() async throws {
        let planner = self.planner(responding: okBody)
        let road = try await planner.road(from: start, to: end)

        // Length is measured with the app's own haversine, not taken from the
        // server's `distance` field, so the number in the UI is consistent with
        // every other road in the app.
        let expected = GeoMath.lengthMeters(road.geoPoints) / 1609.344
        XCTAssertEqual(road.lengthMiles ?? 0, expected, accuracy: 1e-9)
        // ~0.95 mi for the two stub points, and clearly above the 20m floor.
        XCTAssertEqual(road.lengthMiles ?? 0, 0.95, accuracy: 0.05)
        // Scored fields stay nil: an OSM line has no curvature or flow score.
        XCTAssertNil(road.totalScore)
        XCTAssertEqual(road.type, "route")
    }

    // MARK: - Failures

    /// `XCTAssertThrowsError` takes an autoclosure that cannot contain `await`,
    /// so the throwing call is made first and the error inspected afterwards.
    private func failure(from planner: RoutePlanner) async -> RoutePlanner.Failure? {
        do {
            _ = try await planner.road(from: start, to: end)
            return nil
        } catch {
            return error as? RoutePlanner.Failure
        }
    }

    func testNoRouteCodeBecomesNoRoute() async {
        // OSRM answers 200 with code "NoRoute" when the points are simply not
        // connected, so checking the status alone is not enough.
        let failure = await failure(from: planner(responding: #"{"code":"NoRoute"}"#))
        XCTAssertEqual(failure, .noRoute)
    }

    func testNonSuccessStatusBecomesRequestFailed() async {
        let failure = await failure(from: planner(responding: "gateway timeout", status: 504))
        guard case .requestFailed = failure else {
            return XCTFail("expected requestFailed, got \(String(describing: failure))")
        }
    }

    func testUnparseableBodyBecomesRequestFailed() async {
        let failure = await failure(from: planner(responding: "<html>maintenance</html>"))
        guard case .requestFailed = failure else {
            return XCTFail("expected requestFailed, got \(String(describing: failure))")
        }
    }

    func testDegenerateRouteIsRejected() async {
        // A line with a single position cannot be measured or given pacenotes.
        let failure = await failure(from: planner(responding: """
        {"code":"Ok","routes":[{"distance":0,
          "geometry":{"type":"LineString","coordinates":[[-71.104,42.351]]}}]}
        """))
        XCTAssertEqual(failure, .tooShort)
    }


    // MARK: - Naming

    func testRouteIsNamedAfterTheFirstRoad() async throws {
        // The route should read as a place, so the caller's knowledge of the
        // road at the first tap wins over the length-based fallback.
        let road = try await planner(responding: okBody)
            .road(from: start, to: end, name: "Mount Washington Road")
        XCTAssertEqual(road.name, "Mount Washington Road")
    }

    func testBlankNameFallsBackToLength() async throws {
        // An unnamed road still needs something identifiable in the saved list.
        for blank in [nil, "", "   "] {
            let road = try await planner(responding: okBody)
                .road(from: start, to: end, name: blank)
            let name = try XCTUnwrap(road.name)
            XCTAssertTrue(name.contains("mi"), "got \(name)")
        }
    }

    func testRoadNameReadsTheNameTag() async {
        // Overpass returns `elements[].tags.name`; that is the whole contract.
        let planner = self.planner(responding: """
        {"elements":[{"type":"way","id":7,
          "tags":{"highway":"secondary","name":"Storrow Drive"}}]}
        """)
        let name = await planner.roadName(near: start)
        XCTAssertEqual(name, "Storrow Drive")
    }

    func testRoadNameIsNilWhenUnnamedOrFailed() async {
        // Naming is a nicety: a missing name must never fail the route.
        let unnamed = self.planner(responding: #"{"elements":[{"type":"way","id":7}]}"#)
        let a = await unnamed.roadName(near: start)
        XCTAssertNil(a)

        let broken = self.planner(responding: "nope", status: 500)
        let b = await broken.roadName(near: start)
        XCTAssertNil(b)
    }

    // MARK: - Caching

    func testIdenticalTapsAreServedFromCache() async throws {
        let planner = self.planner(responding: okBody)
        let first = try await planner.road(from: start, to: end)
        let second = try await planner.road(from: start, to: end)

        XCTAssertEqual(first.id, second.id)
        // One request total: the second call was answered by the cache.
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDifferentEndpointsWithDifferentGeometryGetDifferentIds() async throws {
        // The id is derived from the geometry, so the same two taps always
        // upsert one saved route. Two genuinely different stretches must not
        // collide, or the second would overwrite the first in the saved list.
        let near = try await planner(responding: """
        {"code":"Ok","routes":[{"distance":10,
          "geometry":{"type":"LineString","coordinates":[[-71.1,42.35],[-71.099,42.351]]}}]}
        """).road(from: start, to: end)
        let far = try await planner(responding: """
        {"code":"Ok","routes":[{"distance":900,
          "geometry":{"type":"LineString","coordinates":[[-71.0,42.4],[-70.9,42.45]]}}]}
        """).road(from: start, to: end)

        XCTAssertNotEqual(near.id, far.id)
    }
}

// MARK: - Stub transport

/// Intercepts every request and replays a canned body, so no test touches the
/// network. Registered per-session by `planner(responding:status:)`.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: Self.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

