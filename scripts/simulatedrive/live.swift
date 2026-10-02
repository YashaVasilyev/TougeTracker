// Replays a road as a *free* drive — no route, no notes loaded — and prints the
// co-driver's calls, so the live pacenote source can be checked without going to
// a car.
//
//   ./scripts/simulate-live-drive.sh [speedKph] [text|audio] [outDir] [roadName]
//
// The same replay `simulate-drive.sh` does, with one thing removed: the route.
// The navigator is never handed the road up front, and the notes are built from
// a rolling window of the road ahead, discovered exactly as they are on a phone.
// Bugs that only exist in that mode — a window rebuilt in the wrong place, a
// corner announced twice, silence once the road runs out — are invisible to the
// planned-route simulation, which is why this is a separate tool.

import Foundation
import CoreLocation

struct Fixture: Decodable {
    let name: String
    let coordinates: [[Double]]
}

/// Counts what the source did, from inside the closures it hands its loaders.
///
/// A reference box rather than plain stored properties: the loaders are
/// `@Sendable` and a struct captured mutably in one is an error, not a warning.
final class Counters: @unchecked Sendable {
    private(set) var tileLookups = 0
    private(set) var routerCalls = 0
    func countTile() { tileLookups += 1 }
    func countRouter() { routerCalls += 1 }
}

/// The simulated drive's clock, in a box the source's `now` closure can read.
///
/// `@Sendable` and MainActor-isolated do not mix, and the source asks for the
/// time from inside a sendable closure.
final class SimClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 0)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class Simulation {
    let speedMps: Double
    let fixInterval: TimeInterval
    let roadName: String?
    let counters = Counters()

    /// Advances with the car, so the source's rate limits see a drive rather
    /// than a single instant — with a frozen clock the rate limiter would refuse
    /// every request after the first and the replay would go silent from there.
    let clock = SimClock()
    private(set) var installedWindows = 0

    struct Call {
        let seconds: TimeInterval
        let distanceAlong: Double
        let phrase: String
    }

    init(speedMps: Double, fixInterval: TimeInterval, roadName: String?) {
        self.speedMps = speedMps
        self.fixInterval = fixInterval
        self.roadName = roadName
    }

    func run(coords: [GeoPoint]) async -> [Call] {
        let counters = self.counters
        let roadName = self.roadName
        let makeRoad: @Sendable () -> TougeRoad = { Self.road(coords, name: roadName) }

        let source = LivePacenoteSource(
            // No route is supplied, so the source has to find the road itself.
            // The "tiles" are the fixture road; the "router" is the same geometry
            // standing in for a line fetched from OSM.
            loader: { _ in
                counters.countTile()
                // NOTILES=1 models a road the bundled tiles do not carry, so the
                // router has to supply every window.
                return ProcessInfo.processInfo.environment["NOTILES"] != nil ? [] : [makeRoad()]
            },
            lineLoader: { _, _, _ in
                counters.countRouter()
                return [makeRoad()]
            },
            now: { self.clock.now })

        let total = GeoMath.lengthMeters(coords)
        let step = max(speedMps * fixInterval, 0.5)
        var calls: [Call] = []
        var travelled = 0.0
        var seen = 0
        var seconds: TimeInterval = 0

        // The car sits for a moment before it moves, and so does the app: the
        // first window is built by a task and lands a few ticks after recording
        // starts. Without those ticks the replay was a race -- the same road gave
        // three calls alone and none in a sweep, purely on whether the window
        // landed before the car reached the first corner. Real time passes here;
        // in a replay that takes milliseconds, it has to be asked for.
        let start = GeoMath.along(coords, distance: 0)
        let justAhead = GeoMath.along(coords, distance: 10)
        var warmup = 0
        while !source.isActive, warmup < 500 {
            warmup += 1
            let stationary = CLLocation(coordinate: start.clLocation, altitude: 0,
                                        horizontalAccuracy: 5, verticalAccuracy: 5,
                                        course: GeoMath.bearing(start, justAhead),
                                        speed: 0, timestamp: clock.now)
            // Any call made while parked is discarded: this is the GPS settling
            // before the drive, not the drive. Counted, it put an extra corner on
            // every short road that starts with one close to the line.
            _ = source.update(location: stationary, speed: 0)
            await Task.yield()
        }

        while travelled <= total {
            let here = GeoMath.along(coords, distance: travelled)
            let next = GeoMath.along(coords, distance: min(travelled + step, total))
            // A real fix carries a course. Without one the source cannot tell
            // which way along the road the car is going, and the notes it builds
            // come out mirrored.
            let location = CLLocation(coordinate: here.clLocation, altitude: 0,
                                      horizontalAccuracy: 5, verticalAccuracy: 5,
                                      course: GeoMath.bearing(here, next),
                                      speed: speedMps, timestamp: clock.now)
            if let call = source.update(location: location, speed: speedMps) {
                let phrase = CoDriverPhrases.phrase(for: call, format: .rally)
                calls.append(Call(seconds: seconds, distanceAlong: travelled, phrase: phrase))
                if ProcessInfo.processInfo.environment["TRACE"] != nil {
                    FileHandle.standardOutput.write(Data("    CALL \(Int(travelled))m: \(phrase)\n".utf8))
                }
            }
            if source.windowRevision > seen {
                seen = source.windowRevision
                installedWindows += 1
                if ProcessInfo.processInfo.environment["TRACE"] != nil {
                    let upcoming = source.upcoming(count: 3).map(\.text)
                    let all = source.annotations.map(\.title)
                    let line = GeoMath.lengthMeters(source.routeCoordinates.map(GeoPoint.from))
                    let text = "    [window \(seen) at \(Int(travelled))m len \(Int(line))m] "
                        + "all(\(all.count)): \(all)  next: \(upcoming)\n"
                    FileHandle.standardOutput.write(Data(text.utf8))
                }
            }
            travelled += step
            seconds += fixInterval
            clock.advance(fixInterval)
            // Stand-in for the run loop. `update` schedules its window rebuild as
            // a task, and a loop that never returns to the run loop never lets
            // one run — which is a true statement about a tight loop and a false
            // one about the app, whose 20Hz timer yields between ticks. Without
            // this the replay reports zero windows and looks like the feature is
            // broken when it is merely not being given a chance to run.
            await Task.yield()
        }
        return calls
    }

    nonisolated private static func road(_ coords: [GeoPoint], name: String?) -> TougeRoad {
        let lats = coords.map(\.lat), lons = coords.map(\.lon)
        return TougeRoad(
            id: 1, name: name ?? "Simulated road", type: "road",
            coordinates: coords.map { [$0.lon, $0.lat] },
            lengthMiles: GeoMath.lengthMeters(coords) / 1609.344,
            curvatureScore: nil, flowScore: nil, totalScore: nil,
            centerLat: (lats.min()! + lats.max()!) / 2,
            centerLon: (lons.min()! + lons.max()!) / 2)
    }
}
// MARK: - Entry point

@MainActor
func replay() async {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        FileHandle.standardError.write(
            "usage: simulatelive <fixtures.json> [speedKph] [text|audio] [outDir] [roadName]\n"
                .data(using: .utf8)!)
        exit(2)
    }
    let url = URL(fileURLWithPath: args[1])
    let data = (try? Data(contentsOf: url)) ?? Data()
    guard let fixtures = try? JSONDecoder().decode([Fixture].self, from: data) else {
        FileHandle.standardError.write("could not read fixtures at \(url.path)\n".data(using: .utf8)!)
        exit(2)
    }
    let speedKph = args.count >= 3 ? (Double(args[2]) ?? 80) : 80
    let mode = args.count >= 4 ? args[3] : "text"
    let outDir = args.count >= 5 ? args[4] : "."
    // A blank trailing argument is "no filter", not a road called "" — the
    // runner script passes one through when no name is given.
    let only = args.count >= 6 && !args[5].isEmpty ? args[5] : nil

    var index = 0
    for fixture in fixtures {
        defer { index += 1 }
        if let only, fixture.name != only { continue }
        let coords = fixture.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
        guard coords.count > 1 else { continue }

        let sim = Simulation(speedMps: speedKph / 3.6, fixInterval: 0.1,
                             roadName: fixture.name)
        let calls = await sim.run(coords: coords)
        let total = GeoMath.lengthMeters(coords)

        var lines = ["free drive of \(fixture.name) — \(Int(total))m at \(Int(speedKph)) km/h, "
                     + "no route, \(calls.count) calls"]
        lines.append("   windows \(sim.installedWindows)   tile lookups \(sim.counters.tileLookups)"
                     + "   router calls \(sim.counters.routerCalls)")
        for call in calls {
            let mm = String(format: "%02d:%02d", Int(call.seconds) / 60, Int(call.seconds) % 60)
            lines.append("  \(mm)  \(Int(call.distanceAlong))m  \(call.phrase)")
        }
        print(lines.joined(separator: "\n"))

        if mode == "manifest" || mode == "audio" {
            let dir = "\(outDir)/\(index)-\(fixture.name.replacingOccurrences(of: " ", with: "_"))"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var manifest = "clip\tseconds\tphrase\n"
            for (n, call) in calls.enumerated() {
                // Clips are named by index, not by the second they happen in: at
                // speed several calls share a second, and naming by time
                // overwrote all but one of them.
                let name = String(format: "%03d-%.1fs", n, call.seconds)
                manifest += "\(name)\t\(String(format: "%.2f", call.seconds))\t\(call.phrase)\n"
                if mode == "audio" {
                    let spoken = Process()
                    spoken.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    spoken.arguments = ["-v", "Samantha", "-o", "\(dir)/\(name).aiff",
                                        "--file-format=AIFF", call.phrase]
                    try? spoken.run()
                    spoken.waitUntilExit()
                }
            }
            try? manifest.write(toFile: "\(dir)/manifest.tsv", atomically: true, encoding: .utf8)
            print("audio: \(dir)")
        }
        print(String(repeating: "-", count: 70))
    }
}

// The replay is async because the source schedules its window rebuilds as
// tasks. A command-line binary has nothing to run them but the main run loop, so
// the work goes on a MainActor task and the loop is pumped underneath it; `exit`
// is what ends it, since `RunLoop.run` never returns.
Task { @MainActor in
    await replay()
    // `exit` does not flush a block-buffered stdout, so redirecting this to a
    // file wrote nothing at all. Found by the obvious thing: running the same
    // command into a file and getting zero bytes.
    fflush(stdout)
    exit(0)
}
RunLoop.main.run()
