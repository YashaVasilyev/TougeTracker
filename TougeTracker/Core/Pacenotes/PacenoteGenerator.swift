import Foundation

public enum PacenoteFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case rally
    case descriptive
    public var id: String { rawValue }
}

public enum PacenoteDirection: String, Codable, Sendable {
    case left = "L"
    case right = "R"
}

public struct Pacenote: Codable, Equatable, Hashable, Sendable {
    /// "1", "3", "5", "6", "Square", or "HP" (grades 2/4 are never emitted by the algorithm).
    public var grade: String
    public var direction: PacenoteDirection
    public var startDist: Double
    public var endDist: Double
    public var length: Double
    public var isLong: Bool
    public var isVeryLong: Bool
    public var apex: GeoPoint
    /// Baked text in rally format, e.g. "4 R long" (matches the JS generator output).
    public var text: String

    public init(grade: String, direction: PacenoteDirection, startDist: Double, endDist: Double,
                length: Double, isLong: Bool, isVeryLong: Bool, apex: GeoPoint, text: String) {
        self.grade = grade
        self.direction = direction
        self.startDist = startDist
        self.endDist = endDist
        self.length = length
        self.isLong = isLong
        self.isVeryLong = isVeryLong
        self.apex = apex
        self.text = text
    }
}

public struct PacenoteResult: Equatable, Sendable {
    public var text: String
    public var turns: [Pacenote]

    public init(text: String, turns: [Pacenote]) {
        self.text = text
        self.turns = turns
    }
}

public struct PacenoteOptions: Sendable {
    public var reverse: Bool
    public var format: PacenoteFormat

    public init(reverse: Bool = false, format: PacenoteFormat = .rally) {
        self.reverse = reverse
        self.format = format
    }
}

/// Faithful Swift port of Tougefinder's `src/services/pacenotes.js` —
/// `generatePacenotes()`. Same pipeline, same constants, same output text.
/// Fidelity is enforced by golden tests against the JS implementation.
public enum PacenoteGenerator {

    static let severityOrder: [String: Int] = [
        "S": 0, "6": 1, "5": 2, "4": 3, "3": 4, "2": 5, "1": 6, "Square": 7, "HP": 8,
    ]

    public static let descriptiveMap: [String: String] = [
        "HP": "Hairpin", "Square": "Square",
        "1": "Sharp", "2": "Sharp", "3": "Tight", "4": "Tight",
        "5": "Moderate", "6": "Slight", "S": "Straight",
    ]

    static func severity(_ grade: String) -> Int {
        severityOrder[grade] ?? 0
    }

    public static func formatted(_ note: Pacenote, format: PacenoteFormat = .rally) -> String {
        let gradeStr = format == .descriptive ? (descriptiveMap[note.grade] ?? note.grade) : note.grade
        let dirStr: String
        switch (note.direction, format) {
        case (.right, .descriptive): dirStr = "Right"
        case (.left, .descriptive): dirStr = "Left"
        case (.right, .rally): dirStr = "R"
        case (.left, .rally): dirStr = "L"
        }
        var suffix = ""
        if note.grade != "HP" {
            if note.isVeryLong { suffix = " very long" } else if note.isLong { suffix = " long" }
        }
        return "\(gradeStr) \(dirStr)\(suffix)"
    }

    public static func generate(_ coordinates: [GeoPoint], options: PacenoteOptions = PacenoteOptions()) -> PacenoteResult {
        let format = options.format
        let coords: [GeoPoint] = options.reverse ? coordinates.reversed().map { $0 } : coordinates

        if coords.count < 3 {
            return PacenoteResult(text: "Road too short for pacenotes.", turns: [])
        }

        // --- Step 1: Pre-smoothing ---
        let smoothedCoords = GeoMath.chaikinSmooth(coords, iterations: 2)

        // --- Step 1.5: Resample to consistent 5m segments ---
        let totalLength = GeoMath.lengthMeters(smoothedCoords)
        let stepSize = 5.0
        var points: [GeoPoint] = []
        var d = 0.0
        while d <= totalLength {
            points.append(GeoMath.along(smoothedCoords, distance: d))
            d += stepSize
        }
        if totalLength.truncatingRemainder(dividingBy: stepSize) != 0 {
            points.append(GeoMath.along(smoothedCoords, distance: totalLength))
        }

        // --- Step 2: Initial point-by-point classification ---
        let lookDistance = 2 // 10m spacing
        struct Candidate {
            let grade: String
            let dir: PacenoteDirection?
            let distance: Double
        }
        var rawCandidates: [Candidate] = []
        if points.count > 2 * lookDistance {
            for i in lookDistance..<(points.count - lookDistance) {
                let pPrev = points[i - lookDistance]
                let pCurr = points[i]
                let pNext = points[i + lookDistance]

                let radius = GeoMath.circumRadiusMeters(pPrev, pCurr, pNext)

                let b1 = GeoMath.bearing(pPrev, pCurr)
                let b2 = GeoMath.bearing(pCurr, pNext)
                let diff = GeoMath.wrap180(b2 - b1)

                var grade = "S"
                if radius < 20 { grade = "1" }
                else if radius < 50 { grade = "3" }
                else if radius < 80 { grade = "5" }
                else if radius < 150 { grade = "6" }

                let dir: PacenoteDirection? = grade == "S" ? nil : (diff > 0 ? .right : .left)
                rawCandidates.append(Candidate(grade: grade, dir: dir, distance: Double(i) * stepSize))
            }
        }

        // --- Step 3: Identify turn sequences ---
        struct Turn {
            var startDist: Double
            var endDist: Double
            var dir: PacenoteDirection
            var grades: [String]
            var tightestGrade: String
            var length: Double = 0
            var isLong = false
            var isVeryLong = false
            var markForRemoval = false
        }
        var turns: [Turn] = []
        var currentTurn: Turn? = nil

        for pt in rawCandidates {
            if pt.grade != "S" {
                if currentTurn == nil {
                    currentTurn = Turn(startDist: pt.distance, endDist: pt.distance,
                                       dir: pt.dir ?? .right, grades: [pt.grade], tightestGrade: pt.grade)
                } else if currentTurn!.dir == pt.dir!, (pt.distance - currentTurn!.endDist) <= 20 {
                    currentTurn!.endDist = pt.distance
                    currentTurn!.grades.append(pt.grade)
                    if severity(pt.grade) > severity(currentTurn!.tightestGrade) {
                        currentTurn!.tightestGrade = pt.grade
                    }
                } else {
                    turns.append(currentTurn!)
                    currentTurn = Turn(startDist: pt.distance, endDist: pt.distance,
                                       dir: pt.dir ?? .right, grades: [pt.grade], tightestGrade: pt.grade)
                }
            } else {
                if let ct = currentTurn, (pt.distance - ct.endDist) > 20 {
                    turns.append(ct)
                    currentTurn = nil
                }
            }
        }
        if let ct = currentTurn { turns.append(ct) }

        // --- Step 4: Post-process turns (hairpins, squares, length) ---
        for idx in turns.indices {
            turns[idx].length = turns[idx].endDist - turns[idx].startDist
            turns[idx].isLong = turns[idx].length >= 40 && turns[idx].length < 80
            turns[idx].isVeryLong = turns[idx].length >= 80

            let startIndex = Int(GeoMath.jsRound(turns[idx].startDist / stepSize))
            let endIndex = Int(GeoMath.jsRound(turns[idx].endDist / stepSize))

            let entryP1 = points[max(0, startIndex - 3)] // 15m before
            let entryP2 = points[startIndex]
            let exitP1 = points[endIndex]
            let exitP2 = points[min(points.count - 1, endIndex + 3)] // 15m after

            let bearingIn = GeoMath.bearing(entryP1, entryP2)
            let bearingOut = GeoMath.bearing(exitP1, exitP2)
            let totalDiff = GeoMath.wrap180(bearingOut - bearingIn)

            // Bearing changes > 130° on a sharp/tight turn → hairpin
            if abs(totalDiff) > 130 && severity(turns[idx].tightestGrade) >= severity("3") {
                turns[idx].tightestGrade = "HP"
                turns[idx].grades = turns[idx].grades.map { _ in "HP" }
            }
            // Bearing ~90° on a grade-1 turn → square
            else if abs(totalDiff) >= 70 && abs(totalDiff) <= 115 && turns[idx].tightestGrade == "1" {
                turns[idx].tightestGrade = "Square"
                turns[idx].grades = turns[idx].grades.map { _ in "Square" }
            }
        }

        // --- Step 4.5: Drop alternating grade-6 squiggles (3+ in a row) ---
        var seqIndex = 0
        while seqIndex < turns.count {
            if turns[seqIndex].tightestGrade == "6" {
                var curr = seqIndex
                while curr + 1 < turns.count {
                    let t1 = turns[curr]
                    let t2 = turns[curr + 1]
                    if t2.tightestGrade == "6" && t2.dir != t1.dir && (t2.startDist - t1.endDist) < 50 {
                        curr += 1
                    } else {
                        break
                    }
                }
                let seqLength = curr - seqIndex + 1
                if seqLength >= 3 {
                    for j in seqIndex...curr { turns[j].markForRemoval = true }
                }
                seqIndex = curr + 1
            } else {
                seqIndex += 1
            }
        }

        turns = turns.filter { !$0.markForRemoval && ($0.length >= 10 || severity($0.tightestGrade) >= severity("3")) }

        // --- Step 5: Final formatting and connectors ---
        var finalNotes: [String] = []
        var finalTurns: [Pacenote] = []

        for (i, t) in turns.enumerated() {
            var prefix = ""
            if i > 0 {
                let distFromPrev = t.startDist - turns[i - 1].endDist
                if distFromPrev < 20 {
                    prefix = "into "
                } else if distFromPrev < 50 {
                    prefix = "and "
                } else {
                    let distToNext = GeoMath.jsRound(distFromPrev / 10) * 10
                    if distToNext > 10 { prefix = "\(Int(distToNext))m: " }
                }
            } else {
                let distToNext = GeoMath.jsRound(t.startDist / 10) * 10
                if distToNext > 10 { prefix = "\(Int(distToNext))m: " }
            }

            let gradeStr = format == .descriptive ? (descriptiveMap[t.tightestGrade] ?? t.tightestGrade) : t.tightestGrade
            let dirStr: String
            switch (t.dir, format) {
            case (.right, .descriptive): dirStr = "Right"
            case (.left, .descriptive): dirStr = "Left"
            case (.right, .rally): dirStr = "R"
            case (.left, .rally): dirStr = "L"
            }

            var suffix = ""
            if t.tightestGrade != "HP" {
                if t.isVeryLong { suffix += " very long" }
                else if t.isLong { suffix += " long" }
            }

            let turnText = "\(gradeStr) \(dirStr)\(suffix)"
            finalNotes.append("\(prefix)\(turnText)")

            // Marker at the apex of the turn
            let apexDist = t.startDist + t.length / 2
            let coordIndex = Int(GeoMath.jsRound(apexDist / stepSize))
            let apex = points[min(coordIndex, points.count - 1)]
            finalTurns.append(Pacenote(grade: t.tightestGrade, direction: t.dir,
                                       startDist: t.startDist, endDist: t.endDist,
                                       length: t.length, isLong: t.isLong, isVeryLong: t.isVeryLong,
                                       apex: apex, text: turnText))
        }

        let lastEndDist = turns.last?.endDist ?? 0
        let remainingDist = GeoMath.jsRound((totalLength - lastEndDist) / 10) * 10
        if remainingDist > 10 {
            finalNotes.append("\(Int(remainingDist))m: End of section")
        }

        return PacenoteResult(text: finalNotes.joined(separator: "\n"), turns: finalTurns)
    }
}
