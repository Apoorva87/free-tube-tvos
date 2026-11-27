import AVFoundation
import Observation

@MainActor @Observable
final class RoomViewingSession {
    enum Presentation { case closed, full, mini }

    private(set) var presentation = Presentation.closed
    private(set) var speed: Float = 1
    let playback = ChannelPlayback()
    @ObservationIgnored var onVideoStarted: ((ChannelVideo) -> Void)?
    private var queue: [ChannelVideo] = []
    private var index = 0
    private var quickCount = 0
    private(set) var queueNotice: String?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    var video: ChannelVideo? { queue.indices.contains(index) ? queue[index] : nil }
    var next: ChannelVideo? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }

    func open(_ video: ChannelVideo, in queue: [ChannelVideo]) {
        guard let position = queue.firstIndex(where: { $0.id == video.id && $0.channelID == video.channelID }) else { return }
        if presentation == .mini, self.video?.id == video.id, self.video?.channelID == video.channelID {
            expand()
            return
        }
        quickCount = 0
        self.queue = queue
        index = position
        presentation = .full
        load()
    }

    func queueFromMini(_ pick: ChannelVideo, seconds: Int?, store: RoomPlaylistStore) {
        guard presentation == .mini else { return }
        let start = index + 1
        let insertion = start + quickCount
        if video?.id == pick.id {
            showNotice("Already playing")
            return
        }
        if queue[start..<insertion].contains(where: { $0.id == pick.id }) {
            showNotice("Already queued · " + pick.title)
            return
        }
        do {
            try store.saveQuickPick(pick, seconds: seconds)
            let remainder = queue[insertion...].filter { $0.id != pick.id }
            queue.replaceSubrange(insertion..., with: [pick] + remainder)
            quickCount += 1
            showNotice("Queued · " + pick.title)
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    private func showNotice(_ text: String) {
        noticeTimer?.cancel()
        queueNotice = text
        noticeTimer = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { queueNotice = nil }
        }
    }

    func minimize() {
        guard presentation == .full, playback.phase == .playing else { return }
        presentation = .mini
    }

    func expand() {
        guard presentation == .mini else { return }
        presentation = .full
    }

    func setSpeed(_ rate: Float) {
        let player = playback.player
        let paused = player.timeControlStatus == .paused
        speed = rate
        player.defaultRate = rate
        if !paused { player.rate = rate }
    }

    func advance() {
        guard next != nil else { return }
        if quickCount > 0 { quickCount -= 1 }
        index += 1
        load()
    }

    func load() {
        guard let video else { return }
        loading?.cancel()
        playback.stop()
        loading = Task { @MainActor [onVideoStarted] in
            guard !Task.isCancelled else { return }
            await playback.play(video) { onVideoStarted?(video) }
            guard !Task.isCancelled else { return }
            if case .failed = playback.phase, presentation == .mini, quickCount > 0 {
                advance()
                return
            }
            guard playback.phase == .finished else { return }
            if next != nil { advance() }
            else if presentation == .mini { close() }
        }
    }

    func close() {
        loading?.cancel()
        loading = nil
        playback.stop()
        presentation = .closed
        noticeTimer?.cancel()
        queueNotice = nil
        quickCount = 0
        queue.removeAll()
        index = 0
    }
}
