// Standalone golden-test runner for the PacenoteGenerator port (macOS, no Xcode needed).
// Build & run from the repo root:
//   swiftc -O TougeTracker/Core/Geo/GeoMath.swift TougeTracker/Core/Pacenotes/PacenoteGenerator.swift \
//     scripts/goldencheck/main.swift -o /tmp/goldencheck && /tmp/goldencheck TougeTrackerTests/Fixtures/pacenote_fixtures.json

import Foundation

struct GoldenFixture: Decodable {
    struct ExpectedTurn: Decodable {
        let text: String
        let coordinate: [Double]
    }
    let name: String
    let reverse: Bool?
    let format: String?
    let coordinates: [[Double]]
    let expectedText: String
    let expectedTurns: [ExpectedTurn]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: goldencheck <fixtures.json>\n".data(using: .utf8)!)
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let fixtures = try JSONDecoder().decode([GoldenFixture].self, from: data)
var failures = 0
for f in fixtures {
    let coords = f.coordinates.map { GeoPoint(lon: $0[0], lat: $0[1]) }
    let result = PacenoteGenerator.generate(
        coords,
        options: PacenoteOptions(reverse: f.reverse ?? false,
                                 format: PacenoteFormat(rawValue: f.format ?? "rally")!)
    )
    var ok = result.text == f.expectedText
    var detail = ""
    if !ok {
        let a = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        let b = f.expectedText.split(separator: "\n", omittingEmptySubsequences: false)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<none>"
            let y = i < b.count ? b[i] : "<none>"
            if x != y {
                detail = "line \(i): swift=\(x) js=\(y)"
                break
            }
        }
    }
    if result.turns.count != f.expectedTurns.count {
        ok = false
        detail = "turn count swift=\(result.turns.count) js=\(f.expectedTurns.count)"
    }
    if ok {
        for (i, (got, exp)) in zip(result.turns, f.expectedTurns).enumerated() {
            if got.text != exp.text {
                ok = false
                detail = "turn \(i) text swift=\(got.text) js=\(exp.text)"
                break
            }
            if abs(got.apex.lon - exp.coordinate[0]) > 1e-7 || abs(got.apex.lat - exp.coordinate[1]) > 1e-7 {
                ok = false
                detail = "turn \(i) apex swift=(\(got.apex.lon),\(got.apex.lat)) js=(\(exp.coordinate[0]),\(exp.coordinate[1]))"
                break
            }
        }
    }
    print(ok ? "PASS \(f.name) (\(f.expectedTurns.count) turns)" : "FAIL \(f.name) — \(detail)")
    if !ok { failures += 1 }
}
print(failures == 0 ? "ALL \(fixtures.count) FIXTURES PASS" : "\(failures)/\(fixtures.count) FIXTURES FAILED")
exit(failures == 0 ? 0 : 1)
