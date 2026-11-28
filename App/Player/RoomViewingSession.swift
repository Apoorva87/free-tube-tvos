import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable
final class RoomViewingSession {
    enum Presentation { case closed, full, mini }

    private(set) var presentation = Presentation.closed
    private(set) var speed: Float = 1
    let playback: ChannelPlayback
    let djStation: RoomDJStation
    private var waitingForDJTrack = false
    private var djTrackStarted = false
    @ObservationIgnored private var djTransport: NSKeyValueObservation?
    @ObservationIgnored private var delayedDJPreparation: Task<Void, Never>?
    private var djPreparationID: String?
    private var lastDJPreparation: ContinuousClock.Instant?
    private var selectedDJTrackID: String?
    private var loadID = UUID()
    @ObservationIgnored var onVideoStarted: ((ChannelVideo) -> Void)?
    private var queue: [ChannelVideo] = []
    private var index = 0
    private var quickCount = 0
    private var playsRelated = false
    private(set) var attemptedIDs = Set<String>()
    @ObservationIgnored private var relatedTask: Task<Void, Never>?
    @ObservationIgnored private let recommendations: (ChannelVideo) async throws -> [ChannelVideo]

    private(set) var queueNotice: String?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var nextCommandTarget: Any?

    init(playback: ChannelPlayback = ChannelPlayback(), djStation: RoomDJStation = RoomDJStation(),
         recommendations: @escaping (ChannelVideo) async throws -> [ChannelVideo] = ChannelCatalog().similarVideos) {
        self.playback = playback
        self.djStation = djStation
        self.recommendations = recommendations
        djStation.session = self
        playback.djRequestsHeld = { [weak djStation] in
            guard let djStation, djStation.isActive else { return false }
            return !djStation.requestsAllowed()
        }
        playback.onRateLimited = { [weak djStation] deadline in
            guard let djStation, djStation.isActive else { return }
            djStation.hold(until: deadline)
        }
    }

    var video: ChannelVideo? { queue.indices.contains(index) ? queue[index] : nil }
    var next: ChannelVideo? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }

    var upcoming: [ChannelVideo] { Array(queue.dropFirst(index + 1)) }

    var canFillDJQueue: Bool {
        djTrackStarted && (playback.player.timeControlStatus == .playing || waitingForDJTrack)
    }

    var nextForPreparation: ChannelVideo? {
        guard djStation.isActive else { return next }
        guard djTrackStarted, playback.player.timeControlStatus == .playing, !djStation.isSearching,
              djStation.requestsAllowed() else { return nil }
        return next
    }

    func startDJ(_ video: ChannelVideo, resetHistory: Bool) {
        selectedDJTrackID = video.id
        playsRelated = false
        quickCount = 0
        if resetHistory {
            attemptedIDs = []
            lastDJPreparation = nil
        }
        queue = [video]
        index = 0
        presentation = .mini
        load()
    }

    func replaceDJUpcoming(_ videos: [ChannelVideo]) {
        guard djStation.isActive, let current = video else { return }
        queue = [current] + videos
        index = 0
        quickCount = 0
        resumeDJQueue()
    }

    func appendDJUpcoming(_ videos: [ChannelVideo]) {
        queue.append(contentsOf: videos)
        resumeDJQueue()
    }

    func placeDJUpcoming(_ song: ChannelVideo, at position: RoomDJQueuePosition) {
        let start = index + 1
        if let existing = queue[start...].firstIndex(where: { $0.id == song.id }) {
            queue.remove(at: existing)
            if existing < start + quickCount { quickCount -= 1 }
        }
        switch position {
        case .next:
            queue.insert(song, at: start)
            quickCount += 1
        case .end:
            queue.append(song)
        }
        resumeDJQueue()
    }

    func removeDJUpcoming(id: String) {
        let start = index + 1
        guard let position = queue[start...].firstIndex(where: { $0.id == id }) else { return }
        if position == start, djTrackStarted || djPreparationID == id {
            // A handoff in progress owns its previous head until the new track starts.
            cancelDJPreparation(discardItem: true)
        }
        if position < start + quickCount { quickCount -= 1 }
        queue.remove(at: position)
        resumeDJQueue()
    }

    private func cancelDJPreparation(discardItem: Bool) {
        delayedDJPreparation?.cancel()
        delayedDJPreparation = nil
        djPreparationID = nil
        if discardItem { playback.prepareNext(nil) }
    }

    func suspendDJQueue() {
        cancelDJPreparation(discardItem: djTrackStarted)
    }

    func holdDJQueue() {
        if djStation.isActive { cancelDJPreparation(discardItem: true) }
    }

    private func prepareDJNext() {
        guard djPreparationID != next?.id else { return }
        cancelDJPreparation(discardItem: true)
        guard let pick = next else { return }
        djPreparationID = pick.id
        delayedDJPreparation = Task {
            if let lastDJPreparation {
                try? await ContinuousClock().sleep(until: lastDJPreparation.advanced(by: .seconds(6)))
            }
            guard !Task.isCancelled, djPreparationID == pick.id, nextForPreparation?.id == pick.id else { return }
            lastDJPreparation = .now
            playback.prepareNext(pick)
        }
    }

    func resumeDJQueue() {
        guard djStation.isActive, !djStation.isSearching, djStation.requestsAllowed() else { return }
        if djPreparationID != nil, djPreparationID != next?.id { cancelDJPreparation(discardItem: true) }
        if waitingForDJTrack, next != nil { advance() }
        else if djTrackStarted, playback.player.timeControlStatus == .playing { prepareDJNext() }
    }

    private func watchDJTransport() {
        let player = playback.player
        djTransport = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, player === playback.player, djTrackStarted, djStation.isActive else { return }
                if player.timeControlStatus == .playing {
                    resumeDJQueue()
                    djStation.fillIfLow()
                } else if !waitingForDJTrack, let item = player.currentItem {
                    // AVFoundation pauses at the natural end while the final queue refill may still be running.
                    let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
                    if end.isNumeric && item.currentTime() >= end { return }
                    djStation.pauseRefill()
                    if !playback.hasPreparedNext { cancelDJPreparation(discardItem: true) }
                }
            }
        }
    }

    func open(_ video: ChannelVideo, in queue: [ChannelVideo]) {
        guard queue.contains(where: { $0.id == video.id }) else { return }
        start(video, in: [video], related: true)
    }

    func openPlaylist(_ video: ChannelVideo, in queue: [ChannelVideo]) {
        start(video, in: queue, related: false)
    }

    private func start(_ video: ChannelVideo, in queue: [ChannelVideo], related: Bool) {
        guard let position = queue.firstIndex(where: { $0.id == video.id && $0.channelID == video.channelID }) else { return }
        let wasDJ = djStation.isActive
        djStation.end()
        if !wasDJ, presentation == .mini, self.video?.id == video.id, self.video?.channelID == video.channelID,
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
        if djStation.isActive { resumeDJQueue() } else { playback.prepareNext(next) }
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

    // AVKit handles play, pause and time-based Siri commands. The app owns the logical queue.
    func updateSystemNextCommand() {
        let available = presentation != .closed && next != nil
        if !available {
            removeSystemNextCommand()
            return
        }
        let command = MPRemoteCommandCenter.shared().nextTrackCommand
        if nextCommandTarget == nil {
            nextCommandTarget = command.addTarget { @Sendable [weak self] _ in
                self?.handleSystemNext() ?? .noActionableNowPlayingItem
            }
        }
        if !command.isEnabled { command.isEnabled = true }
    }

    private func removeSystemNextCommand() {
        guard let nextCommandTarget else { return }
        let command = MPRemoteCommandCenter.shared().nextTrackCommand
        command.removeTarget(nextCommandTarget)
        command.isEnabled = false
        self.nextCommandTarget = nil
    }

    nonisolated func handleSystemNext() -> MPRemoteCommandHandlerStatus {
        let action: @MainActor () -> MPRemoteCommandHandlerStatus = {
            guard self.presentation != .closed, self.video != nil else { return .noActionableNowPlayingItem }
            guard self.next != nil else { return .noSuchContent }
            return self.advance() ? .success : .commandFailed
        }
        if Thread.isMainThread { return MainActor.assumeIsolated { action() } }
        return DispatchQueue.main.sync { action() }
    }

    @discardableResult
    func advance() -> Bool {
        guard next != nil, !djStation.isActive || djStation.requestsAllowed(userInitiated: true) else { return false }
        selectedDJTrackID = nil
        if quickCount > 0 { quickCount -= 1 }
        index += 1
        if djStation.isActive {
            queue.removeFirst(index)
            index = 0
        }
        beginPlayback(usePrepared: true)
        return true
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

    func load() {
        guard !djStation.isActive || djStation.requestsAllowed(userInitiated: true) else { return }
        beginPlayback()
    }

    private func beginPlayback(usePrepared: Bool = false, retrySelectedDJTrack: Bool = true) {
        guard let video, !djStation.isActive || djStation.requestsAllowed() else { return }
        loadID = UUID()
        let generation = loadID
        // A handoff can immediately adopt any work already started for the next item.
        cancelDJPreparation(discardItem: false)
        djTransport?.invalidate()
        djTransport = nil
        djTrackStarted = false
        waitingForDJTrack = false
        loading?.cancel()
        relatedTask?.cancel()
        relatedTask = nil
        attemptedIDs.insert(video.id)
        if !usePrepared { playback.stop() }
        if djStation.isActive { djStation.currentChanged(to: video) }
        loading = Task { @MainActor [onVideoStarted] in
            guard !Task.isCancelled else { return }
            await playback.play(video, usePrepared: usePrepared) {
                guard loadID == generation, !Task.isCancelled else { return }
                selectedDJTrackID = nil
                onVideoStarted?(video)
                if playsRelated { prepareRelated(for: video) }
                else if djStation.isActive {
                    djTrackStarted = true
                    watchDJTransport()
                    resumeDJQueue()
                    djStation.fillIfLow()
                } else { playback.prepareNext(next) }
            }
            guard generation == loadID, !Task.isCancelled else { return }
            if djStation.isActive {
                if !djStation.requestsAllowed() || playback.rateLimited {
                    waitingForDJTrack = playback.phase == .finished
                    return
                }
                // A directly selected recording stays selected if its stream cannot start.
                if case .failed = playback.phase, selectedDJTrackID == video.id {
                    if retrySelectedDJTrack {
                        try? await Task.sleep(for: .seconds(1))
                        guard generation == loadID, !Task.isCancelled else { return }
                        beginPlayback(retrySelectedDJTrack: false)
                    }
                    return
                }
                switch playback.phase {
                case .finished, .failed:
                    if next != nil, !djStation.isSearching { advance() }
                    else {
                        waitingForDJTrack = true
                        djStation.fillIfLow()
                    }
                default: break
                }
                return
            }
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
        removeSystemNextCommand()
        selectedDJTrackID = nil
        loadID = UUID()
        waitingForDJTrack = false
        cancelDJPreparation(discardItem: false)
        djTransport?.invalidate()
        djTransport = nil
        djTrackStarted = false
        djStation.end()
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
