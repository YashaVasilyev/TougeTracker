import AVFoundation
import Foundation

/// Co-driver: speaks a `PacenoteCall` via TTS, ducking other audio. A new call
/// supersedes anything still being spoken (the previously called note is
/// irrelevant once the car has moved on).
///
/// The wording lives in `CoDriverPhrases`; this type only makes noise.
public final class CoDriverSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = CoDriverSpeaker()

    private let synth = AVSpeechSynthesizer()
    private var audioConfigured = false

    /// Builds a human-readable co-driver phrase from a (possibly chained) call.
    public func phrase(for call: PacenoteCall, format: PacenoteFormat) -> String {
        CoDriverPhrases.phrase(for: call, format: format)
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
