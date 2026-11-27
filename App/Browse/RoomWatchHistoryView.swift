import SwiftUI

extension RoomWatchHistoryStore {
    var firstFocus: RoomBrowseFocus {
        videos.first.map { .video($0.id) } ?? .historyBrowse
    }
}

struct RoomWatchHistoryView: View {
    let store: RoomWatchHistoryStore
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    let browse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let issue = store.issue {
                    RoomNotice(message: issue)
                }
                if store.videos.isEmpty {
                    if store.issue == nil {
                        RoomHeading(title: "No watch history yet", subtitle: "Videos you watch in freeTube on this Apple TV will appear here.")
                            .accessibilityIdentifier("history-empty")
                    }
                    Button("Browse Home", action: browse)
                        .focused(focus, equals: .historyBrowse)
                        .accessibilityIdentifier("history-browse")
                } else {
                    let videos = store.videos
                    RoomVideoGrid(videos: videos) { video in play(video, videos) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .onChange(of: store.firstFocus) { previous, current in
            if previous == .historyBrowse, focus.wrappedValue == previous {
                focus.wrappedValue = current
            }
        }
    }
}
