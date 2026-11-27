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
    private var playsRelated = false
    private var attemptedIDs = Set<String>()
    @ObservationIgnored private var relatedTask: Task<Void, Never>?
    @ObservationIgnored private let recommendations: (ChannelVideo) async throws -> [ChannelVideo]

    private(set) var queueNotice: String?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(recommendations: @escaping (ChannelVideo) async throws -> [ChannelVideo] = ChannelCatalog().similarVideos) {
        self.recommendations = recommendations
    }

    var video: ChannelVideo? { queue.indices.contains(index) ? queue[index] : nil }
    var next: ChannelVideo? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }

    func open(_ video: ChannelVideo, in queue: [ChannelVideo]) {
        guard queue.contains(where: { $0.id == video.id }) else { return }
        start(video, in: [video], related: true)
    }

    func openPlaylist(_ video: ChannelVideo, in queue: [ChannelVideo]) {
        start(video, in: queue, related: false)
    }

    private func start(_ video: ChannelVideo, in queue: [ChannelVideo], related: Bool) {
        guard let position = queue.firstIndex(where: { $0.id == video.id && $0.channelID == video.channelID }) else { return }
        if presentation == .mini, self.video?.id == video.id, self.video?.channelID == video.channelID,
           related == playsRelated, related || queue == self.queue {
            expand()
            return
        }
        playsRelated = related
        attemptedIDs = []
        quickCount = 0
        self.queue = queue
        index = position
        presentation = .full
        load()
    }

    func addToQuickPlaylist(_ pick: ChannelVideo, seconds: Int?, store: RoomPlaylistStore) {
        do {
            try store.saveQuickPick(pick, seconds: seconds)
        } catch {
            showNotice(error.localizedDescription)
            return
        }
        guard presentation != .closed else {
            showNotice("Saved to Quick Playlist · " + pick.title)
            return
        }
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
        let remainder = queue[insertion...].filter { $0.id != pick.id }
        queue.replaceSubrange(insertion..., with: [pick] + remainder)
        quickCount += 1
        playback.prepareNext(next)
        showNotice("Queued · " + pick.title)
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
        load(usePrepared: true)
    }

    // Keep explicit picks at the front. Replace old recommendations as soon as
    // the new video starts, so every automatic transition uses its own watch page.
    private func prepareRelated(for video: ChannelVideo) {
        let start = index + 1 + quickCount
        queue.removeSubrange(start...)
        playback.prepareNext(next)
        relatedTask = Task {
            guard !Task.isCancelled else { return }
            let matches = (try? await recommendations(video)) ?? []
            guard !Task.isCancelled else { return }
            var excluded = attemptedIDs.union(queue.map(\.id))
            queue.append(contentsOf: matches.filter { excluded.insert($0.id).inserted })
            playback.prepareNext(next)
        }
    }

    func load(usePrepared: Bool = false) {
        guard let video else { return }
        loading?.cancel()
        relatedTask?.cancel()
        relatedTask = nil
        attemptedIDs.insert(video.id)
        if !usePrepared { playback.stop() }
        loading = Task { @MainActor [onVideoStarted] in
            guard !Task.isCancelled else { return }
            await playback.play(video, usePrepared: usePrepared) {
                onVideoStarted?(video)
                if playsRelated { prepareRelated(for: video) }
                else { playback.prepareNext(next) }
            }
            guard !Task.isCancelled else { return }
            if case .failed = playback.phase, next != nil, playsRelated || (presentation == .mini && quickCount > 0) {
                advance()
                return
            }
            guard playback.phase == .finished else { return }
            if playsRelated, next == nil {
                await relatedTask?.value
                guard !Task.isCancelled else { return }
                if next == nil {
                    prepareRelated(for: video)
                    await relatedTask?.value
                }
            }
            guard !Task.isCancelled else { return }
            if next != nil { advance() }
            else if presentation == .mini { close() }
        }
    }

    func close() {
        loading?.cancel()
        loading = nil
        relatedTask?.cancel()
        relatedTask = nil
        attemptedIDs = []
        playback.stop()
        presentation = .closed
        noticeTimer?.cancel()
        queueNotice = nil
        quickCount = 0
        queue.removeAll()
        index = 0
    }
}
