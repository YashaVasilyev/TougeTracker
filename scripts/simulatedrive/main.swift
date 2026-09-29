// Replays a road as a drive and prints the co-driver's calls, so a route's
// pacenote timing and wording can be checked without going to a car.
//
//   ./scripts/simulate-drive.sh [speedKph] [text|audio] [outDir]
//
// "audio" additionally writes one spoken clip per call and a manifest, so the
// delivery can be heard as well as read.

import Foundation

struct Fixture: Decodable {
    struct Turn: Decodable { let text: String }
    let name: String
    let coordinates: [[Double]]
    let expectedText: String
    let expectedTurns: [Turn]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: simdrive <fixtures.json> [speedKph] [text|audio] [outDir]\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
let speedKph = args.count >= 3 ? (Double(args[2]) ?? 80) : 80
let mode = args.count >= 4 ? args[3] : "text"
let outDir = args.count >= 5 ? args[4] : "."

let sim = DriveSimulator()
let options = DriveSimulator.Options(speedMps: speedKph / 3.6)

for (index, fixture) in fixtures.enumerated() {
    let coords = fixture.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
    guard coords.count > 1 else { continue }
    let calls = sim.simulate(coordinates: coords, options: options)
    print(sim.transcript(coordinates: coords, options: options))

    if mode == "manifest" || mode == "audio" {
        // One clip per call, plus a manifest so the clips can be laid back down
        // on the timeline they came from.
        //
        // Clips are named by index, not by the second they happen in: at speed
        // several calls share a second, and naming by time silently overwrote all
        // but one of them.
        //
        // AIFF is the only format "say -o" will write, and the voice has to be
        // named: the default voice synthesises nothing and writes a header with
        // no audio in it.
        let dir = "\(outDir)/\(index)-\(fixture.name.replacingOccurrences(of: " ", with: "_"))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var manifest = "clip\tseconds\tphrase\n"
        for (n, call) in calls.enumerated() {
            let name = String(format: "%03d-%.1fs", n, call.seconds)
            // "manifest" records the timing and the words without speaking them,
            // for when a recorded voice pack will supply the audio instead. The
            // system voice takes about a second a call to synthesise, which is
            // time spent on clips that are then thrown away.
            if mode == "manifest" {
                manifest += "\(name)\t\(String(format: "%.2f", call.seconds))\t\(call.phrase)\n"
                continue
            }
            let spoken = Process()
            spoken.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            spoken.arguments = ["-v", "Samantha", "-o", "\(dir)/\(name).aiff",
                                "--file-format=AIFF", call.phrase]
            try? spoken.run()
            spoken.waitUntilExit()
            manifest += "\(name).aiff\t\(String(format: "%.2f", call.seconds))\t\(call.phrase)\n"
        }
        try? manifest.write(toFile: "\(dir)/manifest.tsv", atomically: true, encoding: .utf8)
        print("audio: \(dir)")
    }
    print(String(repeating: "-", count: 70))
}
