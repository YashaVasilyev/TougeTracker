import AVFoundation
import Foundation

/// Co-driver: says a `PacenoteCall` out loud.
///
/// Prefers the recorded rally pack and falls back to the system voice, so the
/// app still talks when the pack is absent — which it is in the simulator and
/// in any build without the audio bundled.
///
/// A new call supersedes anything still being spoken: by the time the next
/// corner is called the previous one is history, and letting two calls run on
/// top of each other produces overlapping noise rather than pacenotes.
///
/// The wording lives in `CoDriverPhrases`; this type only makes noise.
public final class CoDriverSpeaker: NSObject, AVSpeechSynthesizerDelegate,
                                   AVAudioPlayerDelegate {

    public static let shared = CoDriverSpeaker()

    private let synth = AVSpeechSynthesizer()
    private var audioConfigured = false

    /// The recorded clips, if the pack is bundled. Loaded once — the index is
    /// just a set of file names.
    private let pack: VoicePack?
    private var player: AVAudioPlayer?
    /// The clips of the call currently being spoken, and how far through it is.
    private var queue: [String] = []
    private var queueIndex = 0

    public override init() {
        self.pack = VoicePack.bundled()
        super.init()
    }

    /// Builds a human-readable co-driver phrase from a (possibly chained) call.
    public func phrase(for call: PacenoteCall, format: PacenoteFormat) -> String {
        CoDriverPhrases.phrase(for: call, format: format)
    }

    /// True when the recorded pack is available to speak from.
    public var hasRecordedVoice: Bool { pack != nil }

    public func speakCall(_ call: PacenoteCall, format: PacenoteFormat) {
        guard AppSettings.shared.voiceEnabled else { return }
        let text = phrase(for: call, format: format)
        guard !text.isEmpty else { return }
        configureAudio()

        // A recorded call that resolves to no clips at all — an unusual
        // sequence the pack does not cover — is read out instead of dropped.
        if let pack, AppSettings.shared.useRecordedVoice, !pack.clips(for: text).isEmpty {
            speakClips(pack.clips(for: text))
        } else {
            speakWithSystemVoice(text)
        }
    }

    public func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        queue = []
        queueIndex = 0
    }

    private func configureAudio() {
        guard !audioConfigured else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback,
                                                       mode: .spokenAudio,
                                                       options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        audioConfigured = true
    }

    /// Plays a call's clips back to back, each with its natural length.
    private func speakClips(_ clips: [String]) {
        stop()
        queue = clips
        queueIndex = 0
        playNext()
    }

    private func playNext() {
        guard queueIndex < queue.count else { return }
        let name = queue[queueIndex]
        guard let url = VoicePack.url(forClip: name) else {
            // A clip named in the index but missing on disk: skip it rather than
            // abandoning the rest of the call.
            queueIndex += 1
            playNext()
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            next.prepareToPlay()
            next.play()
            player = next
        } catch {
            queueIndex += 1
            playNext()
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        queueIndex += 1
        playNext()
    }

    private func speakWithSystemVoice(_ phrase: String) {
        stop()
        let u = AVSpeechUtterance(string: phrase)
        u.rate = Float(AppSettings.shared.speechRate)
        u.pitchMultiplier = 1.0
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
    }
}
