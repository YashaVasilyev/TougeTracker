import XCTest
@testable import TougeTracker
import CoreLocation

/// The sign and signal lookup, against a stubbed Overpass rather than the real
/// service.
///
/// The network is not the interesting part and cannot be relied on in a test
/// anyway; what matters is that a sign on the road ahead is found, one a
/// kilometre off it is not, and that the query Overpass is asked is one it can
/// read. That last one is not a small thing — this app encoded its Overpass query
/// wrongly for its whole life and got an HTML error page back every time, which
/// parses to nothing and so reads as "no signs here".
final class RoadSignSourceTests: XCTestCase {

    /// A straight west-to-east road along the equator, as in the segment tests.
    private func road() -> [GeoPoint] {
        (0...20).map { GeoPoint(lon: Double($0) * 0.001, lat: 0) }
    }

    private func source(responding json: String) -> RoadSignSource {
        SignStub.body = Data(json.utf8)
        SignStub.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignStub.self]
        return RoadSignSource(overpass: RoutePlanner(
            endpoint: URL(string: "https://router.test/route/v1/driving/")!,
            overpassEndpoint: URL(string: "https://overpass.test/api/interpreter")!,
            session: URLSession(configuration: configuration)))
    }

    private func node(_ lon: Double, _ lat: Double, _ highway: String) -> String {
        """
        {"type":"node","id":1,"lat":\(lat),"lon":\(lon),
        "tags":{"highway":"\(highway)"}}
        """
    }

    func testASignOnTheRoadIsFound() async throws {
        // 20m north of the road, well inside the 40m filter.
        let json = "{\"elements\":[\(node(0.005, 0.00018, "stop"))]}"
        let signs = await source(responding: json).signs(along: road())
        XCTAssertEqual(signs.count, 1)
        XCTAssertEqual(signs.first?.feature, .stopSign)
    }

    func testTheSignIsPlacedAlongTheRoadNotAtTheCar() async throws {
        let json = "{\"elements\":[\(node(0.012, 0.0, "traffic_signals"))]}"
        let signs = await source(responding: json).signs(along: road())
        let sign = try XCTUnwrap(signs.first)
        // Vertex 12 of a road with 0.001° (111.19m) between vertices.
        XCTAssertEqual(sign.distance, 12 * 111.19, accuracy: 30)
    }

    func testASignOnTheCrossStreetIsNotCalled() async throws {
        // The box query answers with every sign in the rectangle, including one
        // a kilometre away on a road that merely crosses it. Saying that would
        // be worse than saying nothing.
        let json = "{\"elements\":[\(node(0.005, 0.009, "stop"))]}"
        let signs = await source(responding: json).signs(along: road())
        XCTAssertTrue(signs.isEmpty, "a sign a kilometre off the road was called")
    }

    func testSignalsAndGiveWaysAreWarningsToo() async throws {
        let json = "{\"elements\":[\(node(0.002, 0.0, "traffic_signals")),"
            + "\(node(0.008, 0.0, "give_way"))]}"
        let signs = await source(responding: json).signs(along: road())
        XCTAssertEqual(signs.map(\.feature), [.trafficLights, .giveWay])
    }

    func testAnUnknownTagIsIgnored() async throws {
        let json = "{\"elements\":[\(node(0.002, 0.0, "turning_circle"))]}"
        let signs = await source(responding: json).signs(along: road())
        XCTAssertTrue(signs.isEmpty)
    }

    func testTwoNodesOnOneStopAreCalledOnce() async throws {
        // A stop line and its sign are two nodes a metre apart, and a driver told
        // about the same stop twice stops trusting the warnings.
        let json = "{\"elements\":[\(node(0.005, 0.0, "stop")),"
            + "\(node(0.00501, 0.0, "stop"))]}"
        let signs = await source(responding: json).signs(along: road())
        XCTAssertEqual(signs.count, 1)
    }

    func testTheQuerySurvivesTheFormEncoding() async throws {
        // The regression: the body is percent-encoded, and the characters that
        // encoding escapes are the query language itself. Overpass does not
        // reject that — it answers with an HTML page, which parses to nothing, so
        // every lookup silently returned "nothing here".
        let signSource = source(responding: #"{"elements":[]}"#)
        _ = await signSource.signs(along: road())
        let sent = try XCTUnwrap(SignStub.lastRequest)
        let body = SignStub.bodyText(of: sent)
        for token in ["[out:json]", "node[\"highway\"",
                      "^(stop|traffic_signals|give_way)$", "bbox:", "out tags"] {
            XCTAssertTrue(body.contains(token),
                          "the query lost \(token) on the way: \(body)")
        }
        XCTAssertFalse(body.contains("%5B"), "the query was percent-encoded: \(body)")
    }

    func testAnHTMLErrorPageIsNotSigns() async throws {
        // What the broken encoding produced, exactly: an HTML page, not JSON.
        let signSource = source(responding: "<html><body>Error</body></html>")
        let signs = await signSource.signs(along: road())
        XCTAssertTrue(signs.isEmpty)
    }
}

private final class SignStub: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?

    /// The request body, which arrives as a stream rather than data once
    /// URLSession has got hold of it.
    static func bodyText(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
