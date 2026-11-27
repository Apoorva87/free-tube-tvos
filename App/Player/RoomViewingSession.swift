import AVFoundation
import Observation

@MainActor @Observable
final class RoomViewingSession {
    enum Presentation { case closed, full, mini }

    private(set) var presentation = Presentation.closed
    private(set) var speed: Float = 1
    let playback = ChannelPlayback()
    private var queue: [ChannelVideo] = []
    private var index = 0
    @ObservationIgnored private var loading: Task<Void, Never>?

    var video: ChannelVideo? { queue.indices.contains(index) ? queue[index] : nil }
    var next: ChannelVideo? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }

    func open(_ video: ChannelVideo, in queue: [ChannelVideo]) {
        guard let position = queue.firstIndex(where: { $0.id == video.id && $0.channelID == video.channelID }) else { return }
        if presentation == .mini, self.video?.id == video.id, self.video?.channelID == video.channelID {
            self.queue = queue
            index = position
            expand()
            return
        }
        self.queue = queue
        index = position
        presentation = .full
        load()
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
        index += 1
        load()
    }

    func load() {
        guard let video else { return }
        loading?.cancel()
        playback.stop()
        loading = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await playback.play(video)
            guard !Task.isCancelled, playback.phase == .finished else { return }
            if next != nil { advance() }
            else if presentation == .mini { close() }
        }
    }

    func close() {
        loading?.cancel()
        loading = nil
        playback.stop()
        presentation = .closed
        queue.removeAll()
        index = 0
    }
}
