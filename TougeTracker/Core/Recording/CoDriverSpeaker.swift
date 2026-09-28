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
    ]

    private let synth = AVSpeechSynthesizer()
    private var audioConfigured = false

    /// Builds a human-readable co-driver phrase from a (possibly chained) call.
    public func phrase(for call: PacenoteCall, format: PacenoteFormat) -> String {
        var parts: [String] = []
        for (i, item) in call.items.enumerated() {
            let gradeWord: String
            if format == .rally {
                gradeWord = Self.rallyGradeWords[item.note.grade] ?? item.note.grade
            } else {
                gradeWord = PacenoteGenerator.descriptiveMap[item.note.grade]?.lowercased()
                          ?? item.note.grade.lowercased()
            }
            let dirWord = item.note.direction == .left ? "left" : "right"
            var lengthWord = ""
            if item.note.grade != "HP" {
                if item.note.isVeryLong { lengthWord = " very long" }
                else if item.note.isLong { lengthWord = " long" }
            }

            if i == 0 {
                var p = "\(gradeWord) \(dirWord)\(lengthWord)"
                if item.remaining > 12 {
                    p = "\(Int((item.remaining / 10).rounded(.down) * 10)), \(p)"
                }
                parts.append(p)
            } else if let connector = item.connector {
                parts.append("\(connector) \(gradeWord) \(dirWord)\(lengthWord)")
            } else {
                parts.append("\(gradeWord) \(dirWord)\(lengthWord)")
            }
        }
        return parts.joined(separator: ", ")
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
