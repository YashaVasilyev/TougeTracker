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
    /// Saved routes store pacenotes as JSON, so a note written before tightens
    /// and opens existed has no `trend` key at all. Decoding it as `.none` keeps
    /// every route saved so far readable rather than failing the whole route.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grade = try c.decode(String.self, forKey: .grade)
        direction = try c.decodeIfPresent(PacenoteDirection.self, forKey: .direction)
        startDist = try c.decode(Double.self, forKey: .startDist)
        endDist = try c.decode(Double.self, forKey: .endDist)
        length = try c.decode(Double.self, forKey: .length)
        isLong = try c.decode(Bool.self, forKey: .isLong)
        isVeryLong = try c.decode(Bool.self, forKey: .isVeryLong)
        apex = try c.decode(GeoPoint.self, forKey: .apex)
        text = try c.decode(String.self, forKey: .text)
        trend = try c.decodeIfPresent(CornerTrend.self, forKey: .trend) ?? .none
    }

    /// "1", "3", "5", "6", "Square", or "HP" (grades 2/4 are never emitted by the algorithm).
    /// "S" marks a straight, which has no direction.
    public var grade: String
    /// Nil for a straight ("S"), which bends neither way.
    public var direction: PacenoteDirection?
    public var startDist: Double
    public var endDist: Double
    public var length: Double
    public var isLong: Bool
    public var isVeryLong: Bool
    public var apex: GeoPoint
    /// Baked text in rally format, e.g. "4 R long" (matches the JS generator output).
    public var text: String
    /// Whether the corner tightens or opens as it goes. `.none` for a straight.
    public var trend: CornerTrend

    public init(grade: String, direction: PacenoteDirection?, startDist: Double, endDist: Double,
                length: Double, isLong: Bool, isVeryLong: Bool, apex: GeoPoint, text: String,
                trend: CornerTrend = .none) {
        self.grade = grade
        self.direction = direction
        self.startDist = startDist
        self.endDist = endDist
        self.length = length
        self.isLong = isLong
        self.isVeryLong = isVeryLong
        self.apex = apex
        self.text = text
        self.trend = trend
    }

    /// A straight has no direction to call.
    public var isStraight: Bool { direction == nil }
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

/// Turns a road's geometry into rally pacenotes.
///
/// Originally a port of Tougefinder's `src/services/pacenotes.js`, and still
/// recognisably that pipeline. It is no longer kept identical to it: the
/// vocabulary, the call chaining and the severity ladder have all moved on, and
/// the two implementations now differ by design. The goldens in
/// `TougeTrackerTests/Fixtures` therefore record what *this* produces, and the
/// tests check that it keeps doing so — not that it matches another codebase.
public enum PacenoteGenerator {

    /// Severity counts up towards the tight end. `Flat` sits just above a
    /// straight and below a 6: it is a real bend, but the gentlest one called.
    static let severityOrder: [String: Int] = [
        "S": 0, "Flat": 1, "6": 2, "5": 3, "4": 4, "3": 5, "2": 6, "1": 7,
        "Square": 8, "HP": 9,
    ]

    public static let descriptiveMap: [String: String] = [
        "HP": "Hairpin", "Square": "Square",
        "Flat": "Flat",
        "1": "Sharp", "2": "Sharp", "3": "Tight", "4": "Tight",
        "5": "Moderate", "6": "Slight", "S": "Straight",
    ]

    static func severity(_ grade: String) -> Int {
        severityOrder[grade] ?? 0
    }

    /// Renders one note as text. Shared by `formatted(_:format:)` and the
    /// generator so the preview card and the pacenote list can never disagree.
    ///
    /// A straight has no direction and no severity — it is *only* a distance.
    /// Writing "S 150m" adds a word that says nothing: the number is the whole
    /// note, and it is what the co-driver calls out loud too.
    static func describe(grade: String, dir: PacenoteDirection?, format: PacenoteFormat,
                         isLong: Bool, isVeryLong: Bool, isHairpin: Bool,
                         straightLengthMeters: Double? = nil) -> String {
        let gradeStr = format == .descriptive ? (descriptiveMap[grade] ?? grade) : grade
        guard let dir else {
            guard let straightLengthMeters else { return gradeStr }
            return "\(roundedMeters(straightLengthMeters))m"
        }

        let dirStr: String
        switch (dir, format) {
        case (.right, .descriptive): dirStr = "Right"
        case (.left, .descriptive): dirStr = "Left"
        case (.right, .rally): dirStr = "R"
        case (.left, .rally): dirStr = "L"
        }
        var suffix = ""
        if !isHairpin {
            if isVeryLong { suffix = " very long" } else if isLong { suffix = " long" }
        }
        return "\(gradeStr) \(dirStr)\(suffix)"
    }

    /// Distances are called to the nearest 10m; finer precision is noise.
    public static func roundedMeters(_ meters: Double) -> Int {
        max(10, Int((meters / 10).rounded(.down) * 10))
    }

    /// Distance between two notes' apexes.
    ///
    /// Apex-to-apex is the honest measure of how far apart two corners are. The
    /// gap between one turn's *end* and the next turn's *start* understates it,
    /// badly so for long turns: two 60m corners butted together have a 10m
    /// end-gap while their apexes are 60m apart, and reading that as one
    /// continuous movement is wrong.
    public static func apexGap(from a: Pacenote, to b: Pacenote) -> Double {
        (b.startDist + b.length / 2) - (a.startDist + a.length / 2)
    }

    /// The connector for a pair of notes, from their apex distance.
    ///
    /// Under 20m the two corners are one movement; from 20m to 50m the short
    /// run is called out; beyond that the straight gets its own distance note
    /// and the corner needs no connector.
    public static func connector(from a: Pacenote, to b: Pacenote) -> String? {
        let gap = apexGap(from: a, to: b)
        if gap < 20 { return "into" }
        if gap <= 50 { return "followed by" }
        return nil
    }

    /// Renders a run of notes as lines, with the connector between each pair.
    ///
    /// The written `text` from `generate` already carries connectors, but the
    /// list views render each note on its own — and a bare list of corners gave
    /// no clue how they related. This applies the same apex-based rule so a
    /// list reads "5 L long / into 5 R long / 80m" rather than three
    /// disconnected corners.
    public static func renderedList(_ notes: [Pacenote],
                                     format: PacenoteFormat = .rally) -> [String] {
        var out: [String] = []
        for (i, note) in notes.enumerated() {
            let text = formatted(note, format: format)
            guard i > 0 else { out.append(text); continue }
            // A straight states its own distance, so nothing is inserted after
            // one; the gap is already spoken for.
            let previous = notes[i - 1]
            // A straight is a distance, not a movement: nothing is inserted
            // before one, and nothing after one either.
            if !previous.isStraight, !note.isStraight,
               let connector = connector(from: previous, to: note) {
                out.append("\(connector) \(text)")
            } else {
                out.append(text)
            }
        }
        return out
    }

    public static func formatted(_ note: Pacenote, format: PacenoteFormat = .rally) -> String {
        // The trend is part of the note, so anything that renders a note has to
        // render it. Without this the generated text said "3 R very long
        // tightens" while the preview card and the detail list — which come
        // through here — said only "3 R very long".
        let base = _formatted(note, format: format)
        return note.isStraight ? base : base + CornerTrend.spelling(note.trend)
    }

    private static func _formatted(_ note: Pacenote, format: PacenoteFormat) -> String {
        describe(grade: note.grade, dir: note.direction, format: format,
                 isLong: note.isLong, isVeryLong: note.isVeryLong, isHairpin: note.grade == "HP",
                 straightLengthMeters: note.isStraight ? note.length : nil)
    }

    /// The corner radius boundaries, in metres, tightest first. The last band is
    /// `Flat` rather than a number; anything wider than the last edge is not a
    /// corner at all.
    ///
    /// The ladder once had four bands (1/3/5/6) and never produced 2 or 4, even
    /// though both were listed in `severityOrder` and `descriptiveMap` — so half
    /// the vocabulary was unreachable and the step between neighbouring
    /// severities was a whole grade. The four original edges (20/50/80/150) are
    /// kept, two inserted at the midpoints of the bands they split, and one
    /// added above the top for bends too gentle to be called a 6.
    ///
    /// Without that top band a 200m-radius bend was not a corner at all: it fell
    /// outside every edge and was called a straight, so a real change of
    /// direction went uncalled. Measured over the real tiles, adding it makes
    /// 2.4%% of notes and adds about 1.4%% to the note count overall.
    public static let severityRadiusBands: [Double] = [20, 32, 50, 64, 80, 150, 300]

    /// The severity for a corner of the given radius.
    ///
    /// Returns `"S"` for anything wider than the last band. Bands are read in
    /// order, so a tight corner lands in the first band it fits and the ladder
    /// degrades gracefully if the list is ever re-tuned. The widest band is
    /// named rather than numbered: there is no severity 7.
    public static func grade(forRadius radius: Double) -> String {
        for (index, edge) in severityRadiusBands.enumerated() where radius < edge {
            return index == severityRadiusBands.count - 1 ? "Flat" : "\(index + 1)"
        }
        return "S"
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

                let grade = PacenoteGenerator.grade(forRadius: radius)

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
            var trend: CornerTrend = .none
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

        // --- Step 4.2: Does each corner tighten or open? ---
        //
        // A separate pass over the original geometry, because the trend needs a
        // finer sampling and a longer baseline than severity does, and changing
        // the severity pass to suit it would inflate the note count by 11% to
        // annotate three percent of corners.
        //
        // Two exclusions, both because the modifier would contradict the grade.
        // A hairpin is already the tightest thing in the vocabulary, and saying
        // one tightens adds nothing. A grade 1 cannot get tighter either, and
        // "one right tightens" is not a thing a co-driver says.
        for idx in turns.indices {
            guard turns[idx].tightestGrade != "HP",
                  turns[idx].tightestGrade != "1" else { continue }
            turns[idx].trend = CornerTrendDetector.trend(along: smoothedCoords,
                                                         from: turns[idx].startDist,
                                                         to: turns[idx].endDist)
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

        // A straight is announced by its length, and only when the run is long
        // enough for the number to mean something. Below this the gap belongs to
        // the corner it introduces, which carries a connector instead.
        let minimumStraightMeters: Double = 50

        for (i, t) in turns.enumerated() {
            // The gap since the previous turn. A long one is labelled by a
            // straight note below, so the turn itself must not repeat the same
            // distance — that would read as two identical calls.
            // The gap between consecutive turns, measured apex to apex. Using
            // the end-to-start distance understated it badly for long corners:
            // two 60m turns butted together showed a 10m gap and were read as
            // one continuous movement when their apexes were 60m apart.
            let gap: Double = {
                guard i > 0 else { return t.startDist }
                let previous = turns[i - 1]
                let previousApex = previous.startDist + previous.length / 2
                return (t.startDist + t.length / 2) - previousApex
            }()
            let isLabelledStraight = i > 0 && gap >= minimumStraightMeters

            // How the gap since the previous turn is announced:
            //   under 20m  → the corner reads "into" (one movement)
            //   20-50m    → the corner reads "followed by"
            //   over 50m  → the straight gets its own distance note, and the
            //                corner needs no connector
            var prefix = ""
            if isLabelledStraight {
                prefix = ""
            } else if i > 0 {
                if gap < 20 {
                    prefix = "into "
                } else {
                    prefix = "followed by "
                }
            } else {
                let distToNext = GeoMath.jsRound(gap / 10) * 10
                if distToNext > 10 { prefix = "\(Int(distToNext))m: " }
            }

            // Label the stretch of road that leads into this turn, if it was
            // long enough to be worth calling out. This is emitted *before* the
            // turn so the notes read in the order the driver meets them:
            // "210m: S" then "followed by Square R".
            if isLabelledStraight {
                let start = turns[i - 1].endDist
                let straightLength = gap
                // The note carries its own length, so no distance prefix: the
                // prefix is only for notes that are not self-describing.
                let straightText = describe(grade: "S", dir: nil, format: format,
                                            isLong: false, isVeryLong: false, isHairpin: false,
                                            straightLengthMeters: straightLength)
                finalNotes.append(straightText)
                // A straight has no apex of its own; anchor it at its midpoint
                // so the map marker and the co-driver timing land on the road.
                let midIndex = Int(GeoMath.jsRound((start + straightLength / 2) / stepSize))
                finalTurns.append(Pacenote(grade: "S", direction: nil,
                                           startDist: start, endDist: t.startDist,
                                           length: straightLength, isLong: false, isVeryLong: false,
                                           apex: points[min(midIndex, points.count - 1)],
                                           text: straightText))
            }

            let turnText = describe(grade: t.tightestGrade, dir: t.dir, format: format,
                                    isLong: t.isLong, isVeryLong: t.isVeryLong,
                                    isHairpin: t.tightestGrade == "HP")
            // The word is appended here rather than only in the voice, so the
            // written note and the spoken call cannot disagree.
            let spelled = turnText + CornerTrend.spelling(t.trend)
            finalNotes.append("\(prefix)\(spelled)")

            // Marker at the apex of the turn
            let apexDist = t.startDist + t.length / 2
            let coordIndex = Int(GeoMath.jsRound(apexDist / stepSize))
            let apex = points[min(coordIndex, points.count - 1)]
            // Built into a local first: constructing this inline pushed the
            // type-checker past its budget for this loop body.
            let turnNote = Pacenote(grade: t.tightestGrade, direction: t.dir,
                                    startDist: t.startDist, endDist: t.endDist,
                                    length: t.length, isLong: t.isLong, isVeryLong: t.isVeryLong,
                                    apex: apex, text: turnText, trend: t.trend)
            finalTurns.append(turnNote)
        }

        let lastEndDist = turns.last?.endDist ?? 0
        let remainingDist = GeoMath.jsRound((totalLength - lastEndDist) / 10) * 10
        if remainingDist > 10 {
            finalNotes.append("\(Int(remainingDist))m: End of section")
        }

        return PacenoteResult(text: finalNotes.joined(separator: "\n"), turns: finalTurns)
    }
}
