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

    /// Says a junction or sign, as one clip or one sentence.
    ///
    /// The same two paths as a pacenote call: the recorded warning when the pack
    /// has one, the system voice when it does not. A rally pack has no stop sign
    /// in it, so this is usually the second — and saying "stop sign" plainly is
    /// better than the clip's vaguer "caution".
    public func speakWarning(_ phrase: String) {
        guard AppSettings.shared.voiceEnabled else { return }
        configureAudio()
        if let pack, AppSettings.shared.useRecordedVoice, !pack.clips(for: phrase).isEmpty {
            speakClips(pack.clips(for: phrase))
        } else {
            speakWithSystemVoice(phrase)
        }
    }

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
        pendingIfBusy = false
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
    ///
    /// If the previous call is still being spoken it is *not* cut off. Stopping
    /// mid-word is worse than being a fraction late: the driver hears half a
    /// corner, and half a corner is a corner they might act on. The new call
    /// waits its turn. The navigator only calls a corner when it is imminent, so
    /// the wait is bounded by the call distance, not unbounded.
    private func speakClips(_ clips: [String]) {
        let wasSpeaking = player?.isPlaying == true || synth.isSpeaking
        stop()
        queue = clips
        queueIndex = 0
        pendingIfBusy = wasSpeaking
        if wasSpeaking { return }
        playNext()
    }

    /// Whether a call arrived while the previous one was still going.
    private var pendingIfBusy = false

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
        if queueIndex >= queue.count { finishCall() }
        else { playNext() }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didFinish utterance: AVSpeechUtterance) {
        finishCall()
    }

    /// The queue is empty, so start anything that was held back.
    private func finishCall() {
        player = nil
        if pendingIfBusy {
            pendingIfBusy = false
            playNext()
        } else {
            queue = []
            queueIndex = 0
        }
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
