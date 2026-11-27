import AVKit
import SwiftUI

@MainActor
struct ChannelPlayerView: View {
    static let miniVideoWidth: CGFloat = 640
    private static let miniControlsHeight: CGFloat = 54
    static let miniHeight = miniVideoWidth * 9 / 16 + miniControlsHeight

    let session: RoomViewingSession
    private enum PlayerSheet: Identifiable {
        case ask(ChannelVideo), save(ChannelVideo)
        var id: String {
            switch self {
            case .ask(let video): "ask-" + video.id
            case .save(let video): "save-" + video.id
            }
        }
    }
    @State private var sheet: PlayerSheet?
    @State private var handoffFailed = false
    @FocusState private var youtubeButtonFocused: Bool

    let mini: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let video = session.video {
                    if session.playback.phase == .playing {
                        NativePlayer(session: session, miniature: mini, ask: { sheet = .ask(video) }, save: { sheet = .save(video) })
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
                        }
                        .frame(maxWidth: 1050).padding(48)
                    }
                }
            }
            if mini {
                HStack(spacing: 12) {
                    Text(session.video?.title ?? "").font(.system(size: 19, weight: .semibold))
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
        .sheet(item: $sheet) { choice in
            switch choice {
            case .ask(let video): RoomAskView(video: video, startsTalking: true)
            case .save(let video): RoomAddToPlaylistView(video: video)
            }
        }
        .onChange(of: session.playback.phase) { _, phase in
            handoffFailed = false
            if case .failed = phase { youtubeButtonFocused = !mini }
        }
    }

    private func openInYouTube(_ video: ChannelVideo) async {
        var link = URLComponents()
        link.scheme = "youtube"
        link.host = "www.youtube.com"
        link.path = "/watch"
        link.queryItems = [URLQueryItem(name: "v", value: video.id)]
        guard let url = link.url else { handoffFailed = true; return }
        if await UIApplication.shared.open(url) { session.close() }
        else { handoffFailed = true }
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
    let session: RoomViewingSession
    let miniature: Bool
    let ask: () -> Void
    let save: () -> Void

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let session: RoomViewingSession
        var videoID: String?
        var next: ChannelVideo?
        var configuredSpeed: Float?

        init(session: RoomViewingSession) { self.session = session }

        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            // AVKit has finished handling its own menus. SwiftUI owns the embedded player's presentation.
            Task { @MainActor [session] in
                if session.presentation == .full { session.close() }
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
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.showsPlaybackControls = !miniature
        controller.view.isUserInteractionEnabled = !miniature
        let coordinator = context.coordinator
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
        let assistant = UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { _ in ask() }
        let add = UIAction(title: "Add to playlist", image: UIImage(systemName: "text.badge.plus")) { _ in save() }
        var controls: [UIMenuElement] = [speed, minimize, assistant, add]
        if let next = session.next {
            controls.append(UIAction(title: "Next: \(next.title)", image: UIImage(systemName: "forward.end.fill")) { _ in
                session.advance()
            })
        }
        controller.transportBarCustomMenuItems = controls
    }
}

@MainActor @Observable
final class ChannelPlayback {
    enum Phase: Equatable { case loading, playing, finished, failed(String) }
    var phase = Phase.loading
    let player = AVPlayer()
    private let resolver = PublicVideoPlayer()
    private var activeID = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var progressObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var eventsContinuation: AsyncStream<Event>.Continuation?

    private enum Event: Sendable { case status(AVPlayerItem.Status), started, ended, failed }

    func play(_ video: ChannelVideo, onStart: () -> Void = {}) async {
        stop()
        let id = activeID
        let startupDeadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(20))
            guard id == activeID else { return }
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && player.currentTime().seconds <= 0
            guard phase == .loading || waiting else { return }
            stop()
            phase = .failed("The video didn’t start in Free Tube.")
        }
        defer { startupDeadline.cancel() }
        do {
            let stream = try await resolver.stream(videoID: video.id, channelID: video.channelID)
            guard id == activeID else { return }
            let item = try await Self.item(for: stream)
            try Task.checkCancellation()
            guard id == activeID else { return }
            item.externalMetadata = [Self.metadata(.commonIdentifierTitle, video.title), Self.metadata(.commonIdentifierArtist, video.channelTitle)]
            let events = observe(item)
            defer { if id == activeID { clearObservers() } }
            player.replaceCurrentItem(with: item)
            player.play()
            for await event in events {
                guard !Task.isCancelled, id == activeID else { return }
                switch event {
                case .started: recordPlaybackStart(onStart)
                case .status(.readyToPlay): phase = .playing
                case .status(.failed), .failed:
                    phase = .failed("Free Tube couldn’t play the stream YouTube supplied for this video.")
                    return
                case .ended:
                    recordPlaybackStart(onStart)
                    phase = .finished
                    return
                default: continue
                }
            }
        } catch {
            guard !Task.isCancelled, id == activeID else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        activeID = UUID()
        clearObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
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

    private func clearObservers() {
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
