// Replays a road as a drive and prints the co-driver's calls, so a route's
// pacenote timing and wording can be checked without going to a car.
//
//   swiftc -O TougeTracker/Core/Geo/GeoMath.swift \
//     TougeTracker/Core/Pacenotes/PacenoteGenerator.swift \
//     TougeTracker/Core/Pacenotes/PacenoteNavigator.swift \
//     TougeTracker/Core/Pacenotes/DriveSimulator.swift \
//     scripts/simulatedrive/main.swift -o /tmp/simdrive
//   /tmp/simdrive TougeTrackerTests/Fixtures/pacenote_fixtures.json [speedKph]

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
    FileHandle.standardError.write("usage: simdrive <fixtures.json> [speedKph]\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
let speedKph = args.count >= 3 ? (Double(args[2]) ?? 80) : 80

let sim = DriveSimulator()
let options = DriveSimulator.Options(speedMps: speedKph / 3.6)

for fixture in fixtures {
    let coords = fixture.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
    guard coords.count > 1 else { continue }
    print(sim.transcript(coordinates: coords, options: options))
    print(String(repeating: "-", count: 70))
}
