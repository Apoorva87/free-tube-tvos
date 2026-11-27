import AVFoundation
import Observation

@MainActor @Observable
final class RoomSpokenReply: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var utterance: AVSpeechUtterance?
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private weak var pausedItem: AVPlayerItem?
    @ObservationIgnored private var resumeRate: Float = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func begin(with player: AVPlayer) {
        guard self.player !== player || pausedItem !== player.currentItem else { return }
        end(resume: false)
        self.player = player
        pausedItem = player.currentItem
        resumeRate = player.rate
        player.pause()
    }

    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let player, let pausedItem, player.currentItem === pausedItem { player.pause() }
        let next = AVSpeechUtterance(string: text)
        utterance = next
        isSpeaking = true
        synthesizer.speak(next)
    }

    func stop() {
        utterance = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    func end(resume: Bool = true) {
        stop()
        if resume, let player, let pausedItem, player.currentItem === pausedItem,
           resumeRate > 0, player.rate == 0 {
            player.playImmediately(atRate: resumeRate)
        }
        player = nil
        pausedItem = nil
        resumeRate = 0
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    private nonisolated func finished(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, let current = self.utterance, ObjectIdentifier(current) == id else { return }
            self.utterance = nil
            self.isSpeaking = false
        }
    }
}
