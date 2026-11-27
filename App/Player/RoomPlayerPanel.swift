import SwiftUI
import UIKit

enum RoomPlayerPanel: String, Identifiable {
    case creator, description, similar
    var id: Self { self }
}

struct RoomPlayerPanelView: View {
    let panel: RoomPlayerPanel
    let video: ChannelVideo
    let session: RoomViewingSession
    var onClose: (() -> Void)? = nil
    @Environment(ChannelAccount.self) private var account
    @Environment(ChannelLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    static let shelfHeight: CGFloat = 306

    var body: some View {
        if panel == .similar {
            content
                .frame(maxHeight: Self.shelfHeight)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if panel == .creator {
                let owner = library.channels.first { $0.id == video.channelID }
                    ?? RoomChannel(id: video.channelID, title: video.channelTitle)
                RoomChannelView(account: account, library: library, channel: owner,
                                returnToPlayer: close, play: play)
            } else {
                RoomVideoDetails(panel: panel, video: video, close: close, play: play)
                    .onExitCommand(perform: close)
            }
        }
        .id(video.id).id(panel)
        .background(RoomPalette.background.ignoresSafeArea(edges: panel == .similar ? .bottom : .all))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-panel-" + panel.rawValue)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func play(_ selection: ChannelVideo, in queue: [ChannelVideo]) {
        let stillViewing = session.video?.id == video.id
        close()
        if stillViewing { session.open(selection, in: queue) }
    }
}

private struct RoomVideoDetails: View {
    let panel: RoomPlayerPanel
    let video: ChannelVideo
    let close: () -> Void
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    @Environment(ChannelAccount.self) private var account
    @Environment(ChannelLibrary.self) private var library
    private var compact: Bool { panel == .similar }
    @State private var retry = 0
    @State private var content = Content.loading

    private enum Content {
        case loading, description(String), videos([ChannelVideo]), empty, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 26) {
            HStack(alignment: .center, spacing: 20) {
                if compact {
                    Text("Similar videos").font(.system(size: 26, weight: .semibold)).accessibilityAddTraits(.isHeader)
                } else {
                    Button(action: close) { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(RoomToolbarStyle()).accessibilityIdentifier("player-panel-back")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description").font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(video.title).font(.headline).foregroundStyle(RoomPalette.muted).lineLimit(2)
                            .accessibilityIdentifier("player-panel-video-title")
                    }
                }
                Spacer(minLength: 0)
            }
            switch content {
            case .loading:
                RoomLoading(text: panel == .description ? "Loading description…" : "Loading similar videos…")
                    .accessibilityIdentifier("player-panel-loading")
            case .description(let description):
                RoomDescriptionText(text: description)
                    .frame(maxWidth: 1200, maxHeight: .infinity)
            case .videos(let videos):
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(videos) { related in
                            Button { play(related, videos) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    RoomTileArtwork(url: related.thumbnail ?? related.coverThumbnail, placeholder: "play.rectangle",
                                                    duration: related.durationSeconds.map(RoomPlaylist.clock))
                                    Text(related.title).font(.system(size: 24, weight: .semibold))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    RoomTileByline(video: related, compact: true)
                                }
                                .frame(width: 276, alignment: .leading)
                            }
                            .buttonStyle(VideoButtonStyle())
                            .videoPlaylistMenu(for: related)
                            .accessibilityIdentifier("video-" + related.id)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
            case .empty:
                Text(panel == .description ? "This video has no description." : "No similar videos are available for this video.")
                    .font(.body).foregroundStyle(RoomPalette.muted).accessibilityIdentifier("player-panel-empty")
            case .failed(let reason):
                RoomNotice(message: reason).accessibilityIdentifier("player-panel-error")
                Button("Try again") { retry += 1 }.accessibilityIdentifier("player-panel-retry")
            }
        }
        .padding(.horizontal, compact ? 30 : 42)
        .padding(.vertical, compact ? 10 : 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: retry) { await load() }
    }

    @MainActor private func load() async {
        content = .loading
        do {
            let result: Content
            if panel == .description {
                let token = account.isSignedIn ? try? await account.accessToken() : nil
                try Task.checkCancellation()
                let text = try await library.api.videoDescription(for: video.id, token: token)
                result = text.map(Content.description) ?? .empty
            } else {
                let videos = try await library.api.similarVideos(to: video)
                result = videos.isEmpty ? .empty : .videos(videos)
            }
            try Task.checkCancellation()
            content = result
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}

private struct RoomDescriptionText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = Reader()
        // Selectability enables focus. Indirect scrolling handles remote swipes and directional presses.
        view.isSelectable = true
        view.isUserInteractionEnabled = true
        view.isScrollEnabled = true
        view.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.showsVerticalScrollIndicator = true
        view.indicatorStyle = .white
        view.backgroundColor = .clear
        view.layer.cornerRadius = 12
        view.layer.borderColor = UIColor.white.cgColor
        view.textColor = .white
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 20)
        view.accessibilityIdentifier = "player-description-text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    private final class Reader: UITextView {
        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            layer.borderWidth = isFocused ? 3 : 0
        }
    }
}
