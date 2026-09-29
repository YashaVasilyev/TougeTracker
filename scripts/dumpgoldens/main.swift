// Regenerates the *expected* pacenote output in the golden fixture file from
// this app's own generator.
//
// The goldens used to come from Tougefinder's JavaScript implementation, which
// this was originally a port of. That comparison was worth keeping while the
// port was in progress, and a liability afterwards: the two drifted apart
// through deliberate changes on both sides — straights called as a distance,
// six severity bands instead of four, connectors that span separate calls — and
// the test then failed on differences that were never defects.
//
// The goldens now describe what this app does, and catch it changing by
// accident. They are not a claim that the output matches another implementation.
//
// Usage:
//   swiftc -O TougeTracker/Core/Geo/GeoMath.swift \
//     TougeTracker/Core/Pacenotes/PacenoteGenerator.swift \
//     scripts/dump-pacenote-goldens.swift -o /tmp/dumpgoldens
//   /tmp/dumpgoldens TougeTrackerTests/Fixtures/pacenote_fixtures.json
//
// Run `scripts/simulate-drive-audio.sh` after regenerating to hear the result.

import Foundation

struct Fixture: Codable {
    struct Turn: Codable {
        let text: String
        let coordinate: [Double]
    }
    let name: String
    var reverse: Bool?
    var format: String?
    var totalLength: Double?
    let coordinates: [[Double]]
    var expectedText: String
    var expectedTurns: [Turn]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: dumpgoldens <fixtures.json>\n".data(using: .utf8)!)
    exit(2)
}
let path = args[1]
let decoder = JSONDecoder()
var fixtures = try decoder.decode([Fixture].self,
                                 from: Data(contentsOf: URL(fileURLWithPath: path)))
var updated = 0

for i in fixtures.indices {
    let f = fixtures[i]
    let coords = f.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
    let options = PacenoteOptions(reverse: f.reverse ?? false,
                                  format: PacenoteFormat(rawValue: f.format ?? "rally") ?? .rally)
    let result = PacenoteGenerator.generate(coords, options: options)
    if result.text != fixtures[i].expectedText { updated += 1 }
    fixtures[i].totalLength = result.turns.reduce(0) { $0 + $1.length }
    fixtures[i].expectedText = result.text
    fixtures[i].expectedTurns = result.turns.map { Fixture.Turn(text: $0.text, coordinate: [$0.apex.lon, $0.apex.lat]) }
}

try JSONEncoder().encode(fixtures).write(to: URL(fileURLWithPath: path))
print("regenerated \(fixtures.count) goldens (\(updated) changed)")
