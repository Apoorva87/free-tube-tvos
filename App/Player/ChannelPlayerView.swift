import AVKit
import SwiftUI

@MainActor
struct ChannelPlayerView: View {
    static let miniVideoWidth: CGFloat = 640
    private static let miniControlsHeight: CGFloat = 54
    static let miniHeight = miniVideoWidth * 9 / 16 + miniControlsHeight

    let session: RoomViewingSession
    @State private var sheet: PlayerSheet?
    @State private var handoffFailed = false
    @FocusState private var youtubeButtonFocused: Bool

    let mini: Bool

    private enum PlayerSheet: Identifiable {
        case playlist(ChannelVideo)
        case details(RoomPlayerPanel, ChannelVideo)

        var id: String {
            switch self {
            case .playlist(let video): "playlist-" + video.id
            case .details(let panel, let video): panel.rawValue + "-" + video.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let video = session.video {
                    if session.playback.phase == .playing || (session.playback.phase == .finished && session.playback.hasPreparedNext) {
                        NativePlayer(session: session, miniature: mini, showingSheet: sheet != nil,
                                     openPanel: { sheet = .details($0, video) }, save: { sheet = .playlist(video) })
                            .accessibilityIdentifier("native-playback")
                            .accessibilityHidden(mini)
                            .allowsHitTesting(!mini)
                    } else if mini {
                        Text(video.title).font(.headline).lineLimit(2).padding()
                    } else {
                        VStack(spacing: 24) {
                            Text(video.channelTitle).font(.headline).foregroundStyle(.secondary)
                            Text(video.title).font(.title2).multilineTextAlignment(.center).lineLimit(3)
                                .accessibilityIdentifier("playing-title")
                            switch session.playback.phase {
                            case .loading:
                                ProgressView().padding(.top, 12).accessibilityLabel("Loading video")
                            case .failed(let reason):
                                Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary)
                                if let next = session.next {
                                    Button("Play next video") { session.advance() }
                                        .accessibilityIdentifier("next-after-unavailable").accessibilityValue(next.title)
                                }
                                HStack {
                                    Button("Open in YouTube") { Task { await openInYouTube(video) } }
                                        .focused($youtubeButtonFocused).accessibilityIdentifier("youtube-playback")
                                    Button("Try Again") { session.load() }
                                    Button("Back") { session.close() }
                                }
                                Text(handoffFailed ? "YouTube didn’t open. Check that it’s installed, then select Open in YouTube." :
                                     "Playback in the YouTube app uses its own ad settings.")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .finished:
                                Button("Back to channels") { session.close() }
                            case .playing: EmptyView()
                            }
                            HStack(spacing: 22) {
                                Button("View creator") { sheet = .details(.creator, video) }
                                Button("Description") { sheet = .details(.description, video) }
                                Button("More like this") { sheet = .details(.similar, video) }
                            }
                        }
                        .frame(maxWidth: 1050).padding(48)
                    }
                }
            }
            if mini {
                HStack(spacing: 12) {
                    Text(session.queueNotice ?? session.video?.title ?? "").font(.system(size: 19, weight: .semibold))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: session.expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("Expand video").accessibilityIdentifier("mini-expand")
                    Button(action: session.close) { Image(systemName: "xmark") }
                        .accessibilityLabel("Close video").accessibilityIdentifier("mini-close")
                }
                .buttonStyle(MiniPlayerButtonStyle()).padding(.horizontal, 14).frame(height: Self.miniControlsHeight)
                .background(Color(white: 0.12)).focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: mini ? 14 : 0))
        .overlay { if mini { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.35), lineWidth: 1) } }
        .ignoresSafeArea(edges: mini ? [] : .all)
        .onExitCommand(perform: mini || sheet != nil ? nil : { session.close() })
        .sheet(item: $sheet) { item in
            switch item {
            case .playlist(let video):
                RoomAddToPlaylistView(video: video)
            case .details(let panel, let video):
                RoomPlayerPanelView(panel: panel, video: video, session: session)
                    // Scrollable content has no intrinsic height while a TV sheet is sizing itself.
                    .frame(width: panel == .description ? 1320 : 1560, height: 860)
            }
        }
        .onChange(of: session.video?.id) { sheet = nil }
        .onChange(of: session.playback.phase) { _, phase in
            handoffFailed = false
            if case .failed = phase { youtubeButtonFocused = !mini }
        }
    }

    private func openInYouTube(_ video: ChannelVideo) async {
        if await Self.openYouTube(video) { session.close() }
        else { handoffFailed = true }
    }

    static func openYouTube(_ video: ChannelVideo) async -> Bool {
        var link = URLComponents()
        link.scheme = "youtube"
        link.host = "www.youtube.com"
        link.path = "/watch"
        link.queryItems = [URLQueryItem(name: "v", value: video.id)]
        guard let url = link.url else { return false }
        return await UIApplication.shared.open(url)
    }
}

private struct MiniPlayerButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 18, weight: .bold)).frame(width: 40, height: 40)
            .foregroundStyle(focused ? .black : .white)
            .background(focused ? Color.white : Color(white: 0.25), in: Circle())
    }
}

@MainActor
private struct NativePlayer: UIViewControllerRepresentable {
    @Environment(ChannelAccount.self) private var account
    @Environment(ChannelLibrary.self) private var library
    @Environment(RoomPlaylistStore.self) private var playlists
    let session: RoomViewingSession
    let miniature: Bool
    let showingSheet: Bool
    let openPanel: (RoomPlayerPanel) -> Void
    let save: () -> Void

    @MainActor final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let session: RoomViewingSession
        var videoID: String?
        var next: ChannelVideo?
        var configuredSpeed: Float?
        var showingSheet = false
        let shade = PlaybackOverlay()
        let scanGestures: RoomScanGestures
        weak var similarOverlay: UIViewController?

        init(session: RoomViewingSession) {
            self.session = session
            scanGestures = RoomScanGestures(scanner: session.playback.scanner) { [weak session] in
                session?.presentation == .full && session?.playback.canScanVideo == true
            }
        }

        nonisolated func playerViewController(_ controller: AVPlayerViewController, willTransitionToVisibilityOfTransportBar visible: Bool,
                                              with coordinator: any AVPlayerViewControllerAnimationCoordinator) {
            Task { @MainActor [weak self] in self?.scanGestures.transportBarVisible = visible }
        }

        nonisolated func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            // AVKit has finished handling its own menus. SwiftUI owns the embedded player's presentation.
            Task { @MainActor [weak self, weak playerViewController] in
                guard let self, let playerViewController, !showingSheet, playerViewController.presentedViewController == nil,
                      session.presentation == .full, session.video?.id == videoID else { return }
                session.close()
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = session.playback.player
        // The browsing window hosts this same controller and routes remote presses to the catalog.
        controller.allowsPictureInPicturePlayback = false
        controller.speeds = []
        if !miniature { context.coordinator.scanGestures.install(on: controller) }
        if let overlay = controller.contentOverlayView {
            let shade = context.coordinator.shade
            shade.togglePresentation = miniature ? session.expand : session.minimize
            shade.frame = overlay.bounds
            shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shade.backgroundColor = .black
            shade.alpha = 0
            shade.isUserInteractionEnabled = false
            overlay.addSubview(shade)
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== session.playback.player { controller.player = session.playback.player }
        session.updateSystemNextCommand()
        controller.showsPlaybackControls = !miniature
        controller.view.isUserInteractionEnabled = !miniature
        let coordinator = context.coordinator
        coordinator.shade.alpha = session.playback.fadeFraction
        coordinator.showingSheet = showingSheet
        coordinator.scanGestures.enabled = !miniature && !showingSheet && session.presentation == .full
        if !miniature, let video = session.video, coordinator.videoID != video.id {
            let panel = RoomPlayerPanelView(panel: .similar, video: video, session: session, onClose: { [weak coordinator] in
                coordinator?.similarOverlay?.dismiss(animated: true)
            })
            let overlay = UIHostingController(rootView: panel.environment(account).environment(library).environment(playlists).environment(session).preferredColorScheme(.dark))
            overlay.preferredContentSize = CGSize(width: 1920, height: RoomPlayerPanelView.shelfHeight)
            overlay.view.backgroundColor = .clear
            overlay.title = "More like this"
            coordinator.similarOverlay = overlay
            controller.customOverlayViewController = overlay
        }
        guard coordinator.configuredSpeed != session.speed || coordinator.next != session.next || coordinator.videoID != session.video?.id else { return }
        coordinator.videoID = session.video?.id
        coordinator.configuredSpeed = session.speed
        coordinator.next = session.next
        let speeds: [(Float, String)] = [(0.5, "0.5×"), (1, "1×"), (1.25, "1.25×"), (1.5, "1.5×"), (2, "2×")]
        let choices = speeds.map { rate, title in
            UIAction(title: title, state: rate == session.speed ? .on : .off) { _ in session.setSpeed(rate) }
        }
        let speed = UIMenu(title: "Playback Speed", image: UIImage(systemName: "speedometer"),
                           options: .singleSelection, children: choices)
        let minimize = UIAction(title: "Watch while browsing", image: UIImage(systemName: "pip.enter")) { _ in
            session.minimize()
        }
        let add = UIAction(title: "Add to playlist", image: UIImage(systemName: "text.badge.plus")) { _ in save() }
        let creator = UIAction(title: "View creator", image: UIImage(systemName: "person.crop.circle")) { _ in openPanel(.creator) }
        let description = UIAction(title: "Description", image: UIImage(systemName: "text.alignleft")) { _ in openPanel(.description) }
        var controls: [UIMenuElement] = [creator, description, speed, minimize, add]
        controller.infoViewActions = [creator, description]
        if let next = session.next {
            controls.append(UIAction(title: "Next: \(next.title)", image: UIImage(systemName: "forward.end.fill")) { _ in
                session.advance()
            })
        }
        controller.transportBarCustomMenuItems = controls
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.scanGestures.cancel()
    }
}

// While browsing, focus belongs to the catalog. The player's window sees the
// remote button in either presentation, including when the small player has no focus.
private final class PlaybackOverlay: UIView, UIGestureRecognizerDelegate {
    var togglePresentation: (() -> Void)?
    private lazy var playPauseHold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(heldPlayPause))
        gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        gesture.minimumPressDuration = 0.65
        gesture.delaysTouchesBegan = true
        gesture.delegate = self
        return gesture
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        playPauseHold.view?.removeGestureRecognizer(playPauseHold)
        window?.addGestureRecognizer(playPauseHold)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // SwiftUI routes the browsing screen's short press through a shared recognizer.
        other.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.playPause.rawValue))
    }

    @objc private func heldPlayPause(_ gesture: UILongPressGestureRecognizer) {
        // Changing views on release keeps this press from reaching the newly visible controls.
        if gesture.state == .ended { togglePresentation?() }
    }
}

@MainActor @Observable
final class ChannelPlayback {
    enum Phase: Equatable { case loading, playing, finished, failed(String) }
    var phase = Phase.loading
    @ObservationIgnored let scrubFrames = RoomScrubFrames()
    @ObservationIgnored lazy var scanner = RoomVideoScanner(canPreview: scrubFrames.canPreview, image: scrubFrames.image,
                                                            frameRange: scrubFrames.frameRange)
    var canScanVideo: Bool { phase == .playing && audioFadeFraction == 0 }
    private(set) var rateLimited = false
    @ObservationIgnored var onRateLimited: ((Date) -> Void)?
    @ObservationIgnored var djRequestsHeld: (() -> Bool)?
    @ObservationIgnored private var preparedStatus: NSKeyValueObservation?
    static let softFadeKey = "room.playback.soft-fade"
    static let overlapKey = "room.playback.overlap-seconds"
    static let defaultOverlap = 0.55
    static let overlapOptions = [0.25, defaultOverlap, 1, 2, 4, 6]
    private(set) var overlapSeconds = defaultOverlap
    @ObservationIgnored private var audioFadeFraction = 0.0
    private var softFadeEnabled = true

    func configureOverlap(seconds: Double) {
        overlapSeconds = Self.overlapOptions.contains(seconds) ? seconds : Self.defaultOverlap
    }
    private(set) var incomingPlayer: AVQueuePlayer?
    private(set) var player: AVQueuePlayer = {
        let player = AVQueuePlayer()
        // The session owns queue priority and observes the outgoing item's end.
        player.actionAtItemEnd = .pause
        return player
    }()
    private(set) var fadeFraction = 0.0
    private var originalVolume: Float?
    private var fadeObserver: Any?
    private var preparedID: String?
    private var preparedItem: AVPlayerItem?
    private var preparing: Task<Void, Never>?
    var hasPreparedNext: Bool { preparedItem != nil }
    private let resolver = PublicVideoPlayer()
    private let itemResolver: (@MainActor (ChannelVideo) async throws -> AVPlayerItem)?

    init(itemResolver: (@MainActor (ChannelVideo) async throws -> AVPlayerItem)? = nil) {
        self.itemResolver = itemResolver
    }

    private var activeID = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var transportObservation: NSKeyValueObservation?
    private var progressObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var eventsContinuation: AsyncStream<Event>.Continuation?

    private enum Event: Sendable { case status(AVPlayerItem.Status), started, ended, failed }

    func configureSoftFade(_ enabled: Bool, next: ChannelVideo?) {
        guard enabled != softFadeEnabled else { return }
        softFadeEnabled = enabled
        discardPrepared()
        prepareNext(next)
    }

    func prepareNext(_ video: ChannelVideo?) {
        guard video?.id != preparedID else { return }
        discardPrepared()
        guard let video, let current = player.currentItem else { return }
        preparedID = video.id
        let generation = activeID
        preparing = Task {
            do {
                guard djRequestsHeld?() != true, !Task.isCancelled else { return }
                let item = try await resolveItem(video)
                guard !Task.isCancelled, activeID == generation, player.currentItem === current else { return }
                if softFadeEnabled {
                    let incoming = AVQueuePlayer(items: [item])
                    incoming.actionAtItemEnd = .pause
                    incoming.isMuted = player.isMuted
                    incoming.volume = 0
                    incomingPlayer = incoming
                    transportObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in self?.updateFade() }
                    }
                } else {
                    guard player.canInsert(item, after: current) else { return }
                    player.insert(item, after: current)
                }
                preparedItem = item
                preparedStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        guard let self, self.preparedItem === item else { return }
                        if self.hasRateLimitError(item) { self.reportRateLimit(retryAfter: nil) }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    preparedID = nil
                    _ = recordRateLimit(error)
                }
            }
        }
    }

    private func discardPrepared() {
        preparedStatus?.invalidate()
        preparedStatus = nil
        preparing?.cancel()
        preparing = nil
        if let preparedItem, player.items().contains(preparedItem), player.currentItem !== preparedItem {
            player.remove(preparedItem)
        }
        transportObservation?.invalidate()
        transportObservation = nil
        incomingPlayer?.pause()
        incomingPlayer?.removeAllItems()
        incomingPlayer = nil
        preparedItem = nil
        preparedID = nil
        setFade(0)
    }

    private func hasRateLimitError(_ item: AVPlayerItem) -> Bool {
        item.errorLog()?.events.last?.errorStatusCode == 429
    }

    private func reportRateLimit(retryAfter: String?) {
        let requested = RoomDJCooldown.retryDate(retryAfter)
        let until = itemResolver == nil ? RoomDJCooldown.record(until: requested) : requested
        onRateLimited?(until)
    }

    private func recordRateLimit(_ error: Error) -> Bool {
        guard let failure = error as? PublicPlayerError else { return false }
        switch failure {
        case .rateLimited(let retryAfter): reportRateLimit(retryAfter: retryAfter)
        case .badResponse(429): reportRateLimit(retryAfter: nil)
        default: return false
        }
        return true
    }

    private func resolveItem(_ video: ChannelVideo) async throws -> AVPlayerItem {
        if let itemResolver { return try await itemResolver(video) }
        let media = try await resolver.media(videoID: video.id, channelID: video.channelID)
        try Task.checkCancellation()
        let item = try await Self.item(for: media.stream)
        scrubFrames.register(item, storyboardSpec: media.storyboardSpec)
        item.externalMetadata = [Self.metadata(.commonIdentifierTitle, video.title), Self.metadata(.commonIdentifierArtist, video.channelTitle)]
        return item
    }

    func play(_ video: ChannelVideo, usePrepared: Bool = false, onStart: () -> Void = {}) async {
        scanner.stop()
        if usePrepared, preparedID == video.id, preparedItem == nil {
            await preparing?.value
            guard !Task.isCancelled else { return }
        }
        // A pending prefetch can receive a 429 while the current track is ending.
        if djRequestsHeld?() == true {
            rateLimited = true
            phase = .failed(PublicPlayerError.rateLimited(retryAfter: nil).localizedDescription)
            return
        }
        let warm = usePrepared && preparedID == video.id ? preparedItem : nil
        let incoming = incomingPlayer
        let reuse = warm.flatMap { item in
            item.status != .failed && (incoming?.currentItem === item || player.items().contains(item)) ? item : nil
        }
        if reuse != nil {
            activeID = UUID()
            clearObservers()
            preparedItem = nil
            incomingPlayer = nil
            discardPrepared()
            if let incoming {
                incoming.defaultRate = player.defaultRate
                incoming.isMuted = player.isMuted
                incoming.volume = player.volume
                player.pause()
                player.removeAllItems()
                player = incoming
            }
            phase = .playing
        } else {
            stop()
        }
        let id = activeID
        let startupDeadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(20))
            guard id == activeID else { return }
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.currentTime().seconds <= 0
            guard phase == .loading || waiting else { return }
            stop()
            phase = .failed("The video didn’t start in freeTube.")
        }
        defer { startupDeadline.cancel() }
        do {
            let item: AVPlayerItem
            if let reuse { item = reuse }
            else { item = try await resolveItem(video) }
            try Task.checkCancellation()
            guard id == activeID else { return }
            let events = observe(item)
            defer { if id == activeID { clearObservers() } }
            if reuse == nil { player.replaceCurrentItem(with: item) }
            else if incoming == nil { player.advanceToNextItem() }
            player.play()
            for await event in events {
                guard !Task.isCancelled, id == activeID else { return }
                switch event {
                case .started: recordPlaybackStart(onStart)
                case .status(.readyToPlay): phase = .playing
                case .status(.failed), .failed:
                    if hasRateLimitError(item) {
                        rateLimited = true
                        reportRateLimit(retryAfter: nil)
                        phase = .failed(PublicPlayerError.rateLimited(retryAfter: nil).localizedDescription)
                        return
                    }
                    // A URL resolved during a long video can expire before its first frame.
                    if reuse != nil, progressObserver != nil {
                        await play(video, onStart: onStart)
                        return
                    }
                    phase = .failed("freeTube couldn’t play the stream YouTube supplied for this video.")
                    return
                case .ended:
                    scanner.stop()
                    recordPlaybackStart(onStart)
                    phase = .finished
                    return
                default: continue
                }
            }
        } catch {
            guard !Task.isCancelled, id == activeID else { return }
            rateLimited = recordRateLimit(error)
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        scanner.stop()
        rateLimited = false
        activeID = UUID()
        clearObservers()
        discardPrepared()
        player.pause()
        player.removeAllItems()
        phase = .loading
    }

    private func observe(_ item: AVPlayerItem) -> AsyncStream<Event> {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        eventsContinuation = continuation
        // SmartTubeIOS's AVPlayerItem status observation, kept active until the item ends.
        statusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            continuation.yield(.status(item.status))
        }
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { time in
            if time.isNumeric && time > .zero { continuation.yield(.started) }
        }
        fadeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 24), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFade() }
        }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil) { _ in
                continuation.yield(.ended)
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: nil) { _ in
                continuation.yield(.failed)
            },
        ]
        return events
    }

    private func recordPlaybackStart(_ onStart: () -> Void) {
        guard let progressObserver else { return }
        player.removeTimeObserver(progressObserver)
        self.progressObserver = nil
        onStart()
    }

    private func updateFade() {
        guard let preparedItem, preparedItem.status != .failed,
              let current = player.currentItem, current.duration.isNumeric else {
            setFade(0)
            return
        }
        let end = current.forwardPlaybackEndTime.isNumeric
            ? CMTimeMinimum(current.duration, current.forwardPlaybackEndTime) : current.duration
        let distance = end.seconds - player.currentTime().seconds
        if let incoming = incomingPlayer {
            // At natural end AVFoundation pauses the outgoing player. Let the
            // incoming clock continue through promotion, including that callback.
            if player.timeControlStatus != .playing || player.rate <= 0 {
                if player.currentTime() < end || player.timeControlStatus == .waitingToPlayAtSpecifiedRate { incoming.pause() }
                return
            }
            let remaining = distance / Double(player.rate)
            let ready = preparedItem.status == .readyToPlay
            // Leave enough of even a very short clip to play after the picture changes.
            let incomingLength = preparedItem.duration.seconds / Double(player.rate)
            let overlap = incomingLength.isFinite && incomingLength > 0 ? min(overlapSeconds, incomingLength / 2) : overlapSeconds
            let fraction = min(1, max(0, 1 - remaining / (ready ? overlap : 0.35)))
            let pictureWindow = ready ? min(Self.defaultOverlap, overlap) : 0.35
            setFade(fraction, picture: min(1, max(0, 1 - remaining / pictureWindow)))
            if ready && fraction > 0 {
                incoming.isMuted = player.isMuted
                incoming.volume = (originalVolume ?? player.volume) * Float(fraction)
                if incoming.rate != player.rate { incoming.playImmediately(atRate: player.rate) }
            } else if incoming.rate != 0 || incoming.currentTime().seconds > 0 {
                incoming.pause()
                incoming.volume = 0
                incoming.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else {
            let remaining = distance / Double(player.rate)
            setFade(player.rate > 0 && remaining.isFinite ? min(1, max(0, 1 - remaining / 0.35)) : 0)
        }
    }

    private func setFade(_ fraction: Double, picture: Double? = nil) {
        let shade = picture ?? fraction
        guard fraction != audioFadeFraction || shade != fadeFraction else { return }
        audioFadeFraction = fraction
        if fraction > 0, scanner.busy { scanner.stop() }
        if fraction > 0, originalVolume == nil { originalVolume = player.volume }
        fadeFraction = shade
        if let originalVolume { player.volume = originalVolume * Float(1 - fraction) }
        if fraction == 0 { originalVolume = nil }
    }

    private func clearObservers() {
        transportObservation?.invalidate()
        transportObservation = nil
        if let fadeObserver {
            player.removeTimeObserver(fadeObserver)
            self.fadeObserver = nil
        }
        eventsContinuation?.finish()
        eventsContinuation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let progressObserver { player.removeTimeObserver(progressObserver) }
        progressObserver = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }

    private static func metadata(_ identifier: AVMetadataIdentifier, _ text: String) -> AVMetadataItem {
        let value = AVMutableMetadataItem()
        value.identifier = identifier
        value.value = text as NSString
        value.extendedLanguageTag = "und"
        return value
    }

    private static func item(for stream: PublicVideoStream) async throws -> AVPlayerItem {
        switch stream {
        case .single(let url): return AVPlayerItem(url: url)
        case .separate(let videoURL, let audioURL):
            let video = AVURLAsset(url: videoURL)
            let audio = AVURLAsset(url: audioURL)
            async let videoTracks = video.loadTracks(withMediaType: .video)
            async let audioTracks = audio.loadTracks(withMediaType: .audio)
            let (videos, audios) = try await (videoTracks, audioTracks)
            guard let sourceVideo = videos.first, let sourceAudio = audios.first else { throw PublicPlayerError.unsupported }
            let videoRange = try await sourceVideo.load(.timeRange)
            let audioRange = try await sourceAudio.load(.timeRange)
            let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
            guard duration.isNumeric, duration > .zero else { throw PublicPlayerError.unsupported }
            let composition = AVMutableComposition()
            for (track, type, start) in [(sourceVideo, AVMediaType.video, videoRange.start), (sourceAudio, .audio, audioRange.start)] {
                guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw PublicPlayerError.unsupported }
                try target.insertTimeRange(CMTimeRange(start: start, duration: duration), of: track, at: .zero)
            }
            return AVPlayerItem(asset: composition)
        }
    }
}
