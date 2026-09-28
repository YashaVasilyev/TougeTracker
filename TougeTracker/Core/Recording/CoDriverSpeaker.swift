import AVFoundation
import Foundation

/// Co-driver: turns a `PacenoteCall` into spoken rally instructions via TTS,
/// ducking other audio. A new call supersedes anything still being spoken (the
/// previously called note is irrelevant once the car has moved on).
public final class CoDriverSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = CoDriverSpeaker()

    private static let rallyGradeWords: [String: String] = [
        "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "HP": "hairpin", "Square": "square",
        "S": "straight",
    ]

    /// Rounds to the nearest 10m, the precision a co-driver actually calls.
    /// `30.4` and `36` are both "30" — finer precision is noise to a driver.
    private func callDistance(_ meters: Double) -> Int {
        Int((meters / 10).rounded(.down) * 10)
    }

    private let synth = AVSpeechSynthesizer()
    private var audioConfigured = false

    /// Builds a human-readable co-driver phrase from a (possibly chained) call.
    ///
    /// A straight is announced as a bare distance — "3 left, 100, 2 right" —
    /// because that is how a co-driver calls a run: the corner, how far it is,
    /// then the next corner. The word "straight" is implied by the gap and adds
    /// nothing the driver does not already know.
    public func phrase(for call: PacenoteCall, format: PacenoteFormat) -> String {
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
                gradeWord = Self.rallyGradeWords[note.grade] ?? spokenFallback(note.grade)
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
                var p = body
                if item.remaining > 12 {
                    p = "\(callDistance(item.remaining)), \(p)"
                }
                parts.append(p)
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
    private func spokenFallback(_ grade: String) -> String {
        let digits = ["zero", "one", "two", "three", "four", "five", "six",
                      "seven", "eight", "nine"]
        if let n = Int(grade), n >= 0, n < digits.count { return digits[n] }
        return PacenoteGenerator.descriptiveMap[grade]?.lowercased() ?? "corner"
    }

    public func speakCall(_ call: PacenoteCall, format: PacenoteFormat) {
        guard AppSettings.shared.voiceEnabled else { return }
        speak(phrase(for: call, format: format))
    }

    public func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(_ phrase: String) {
        guard !phrase.isEmpty else { return }
        if !audioConfigured {
            try? AVAudioSession.sharedInstance().setCategory(.playback,
                                                               mode: .spokenAudio,
                                                               options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            audioConfigured = true
        }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: phrase)
        u.rate = Float(AppSettings.shared.speechRate)
        u.pitchMultiplier = 1.0
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
    }
}
