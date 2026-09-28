import Foundation

/// Turns a `PacenoteCall` into the words a co-driver would say.
///
/// Deliberately free of AVFoundation and app settings: this is pure text, and
/// keeping it separate means a drive can be replayed and its phrasing checked
/// from a plain command-line tool as well as on device.
public enum CoDriverPhrases {

    private static let rallyGradeWords: [String: String] = [
        "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "HP": "hairpin", "Square": "square",
        "S": "straight",
    ]

    /// Rounds to the nearest 10m, the precision a co-driver actually calls.
    /// `30.4` and `36` are both "30" — finer precision is noise to a driver.
    static func callDistance(_ meters: Double) -> Int {
        Int((meters / 10).rounded(.down) * 10)
    }

    /// Builds a human-readable co-driver phrase from a (possibly chained) call.
    ///
    /// A straight is announced as a bare distance — "three left, 100, two right" —
    /// because that is how a co-driver calls a run: the corner, how far it is,
    /// then the next corner. The word "straight" is implied by the gap and adds
    /// nothing the driver does not already know.
    public static func phrase(for call: PacenoteCall, format: PacenoteFormat) -> String {
        var parts: [String] = []
        for (i, item) in call.items.enumerated() {
            let note = item.note

            if note.isStraight {
                // Distance only. A straight is not a movement, so it takes no
                // connector and no grade word — just how far.
                parts.append("\(max(callDistance(note.length), 10))")
                continue
            }

            // Every grade is spoken as a word: "three left", never "3 L", which
            // a synthesiser would read as "three el".
            let gradeWord: String
            if format == .rally {
                gradeWord = rallyGradeWords[note.grade] ?? spokenFallback(note.grade)
            } else {
                gradeWord = PacenoteGenerator.descriptiveMap[note.grade]?.lowercased()
                          ?? spokenFallback(note.grade)
            }

            let dirWord = note.direction == .left ? "left" : "right"
            var lengthWord = ""
            if note.grade != "HP" {
                if note.isVeryLong { lengthWord = " very long" }
                else if note.isLong { lengthWord = " long" }
            }
            let body = "\(gradeWord) \(dirWord)\(lengthWord)"

            if i == 0 {
                // No leading distance. The navigator already decides when a
                // note is worth calling, and at speed the call distance barely
                // changes between corners — so the co-driver said "190" before
                // almost every call, repeating an unchanged number. The
                // distances that matter are the ones a note carries itself:
                // a straight's length, and the corner's own severity.
                parts.append(body)
            } else if let connector = item.connector {
                parts.append("\(connector) \(body)")
            } else {
                parts.append(body)
            }
        }
        return parts.joined(separator: ", ")
    }

    /// Guards against a bare grade reaching the synthesiser. A grade the maps
    /// do not cover would otherwise be read letter-by-letter ("S" → "ess"),
    /// so unknown numeric grades are expanded to their English word and
    /// anything else falls back to the descriptive wording.
    static func spokenFallback(_ grade: String) -> String {
        let digits = ["zero", "one", "two", "three", "four", "five", "six",
                      "seven", "eight", "nine"]
        if let n = Int(grade), n >= 0, n < digits.count { return digits[n] }
        return PacenoteGenerator.descriptiveMap[grade]?.lowercased() ?? "corner"
    }
}
