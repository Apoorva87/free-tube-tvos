import SwiftUI

struct RoomDiscoverView: View {
    let library: ChannelLibrary
    let catalog: RoomCategoryCatalog
    let preferences: RoomDiscoverPreferences
    let interestFeed: RoomInterestFeed
    let rows: [RoomDiscoverShelf]
    let musicHistory: [ChannelVideo]
    let settings: () -> Void
    let category: RoomDiscoverCategory
    let reloadID: UUID?
    let signedIn: Bool
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let select: (RoomDiscoverCategory) -> Void
    let refresh: () -> Void
    let openMenu: () -> Void
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    let findChannels: () -> Void
    let signIn: () -> Void

    private struct Request: Equatable {
        let rows: [RoomInterestRow]
        let category: RoomDiscoverCategory
        let reloadID: UUID?
    }

    private struct MusicRequest: Equatable {
        let ids: [String]
        let refresh: UUID?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 30) {
                Text("Discover")
                    .font(.system(size: 48, weight: .bold)).tracking(-1.2)
                    .accessibilityAddTraits(.isHeader)
                categories
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(RoomToolbarStyle()).focused(focus, equals: .discoverRefresh)
                    .accessibilityLabel("Refresh Discover").accessibilityIdentifier("discover-refresh")
            }
            .padding(.horizontal, 7)
            feed.id(category)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover-screen")
        .task(id: Request(rows: category == .forYou ? preferences.rows : [], category: category, reloadID: reloadID)) {
            if category == .forYou {
                await interestFeed.load(rows: preferences.rows, force: reloadID != nil)
            } else {
                await catalog.load(category, force: reloadID != nil)
            }
        }
        .task(id: MusicRequest(ids: musicHistory.map(\.id), refresh: category == .music ? reloadID : nil)) {
            if category == .music { await catalog.music.load(history: musicHistory, refresh: reloadID) }
        }
    }

    private var categories: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(RoomDiscoverCategory.allCases) { item in
                    Button(item.title) { select(item) }
                        .buttonStyle(DiscoverChipStyle(selected: item == category))
                        .focused(focus, equals: .discoverCategory(item))
                        .accessibilityAddTraits(item == category ? .isSelected : [])
                        .accessibilityIdentifier("discover-category-" + item.id)
                }
            }
            .padding(5)
        }
        .scrollIndicators(.hidden)
        .focusSection()
    }

    private var feed: some View {
        let personal = category == .forYou
        let hasLibraryRows = preferences.rows.contains { $0.enabled && $0.query.isEmpty }
        let loading = personal ? interestFeed.isLoading || (hasLibraryRows && (library.isLoading || library.discoverLoading))
            : catalog.category != category || catalog.isLoading || (category == .music && catalog.music.isLoading)
        let categoryIssue = catalog.category == category ? catalog.errorMessage : nil
        let issue = personal ? interestFeed.errorMessage ?? (hasLibraryRows ? library.warning : nil)
            : categoryIssue ?? (category == .music ? catalog.music.errorMessage : nil)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let issue { RoomNotice(message: issue) }
                if rows.isEmpty {
                    if loading {
                        RoomLoading(text: personal ? "Finding videos for you…" : "Loading \(category.title)…")
                    } else if personal && hasLibraryRows && library.discoverFailed && issue == nil {
                        RoomNotice(message: "Couldn’t load your recommendations. Refresh Discover to try again.")
                    } else if personal && hasLibraryRows && library.followed.isEmpty && !preferences.rows.contains(where: { $0.enabled && !$0.query.isEmpty }) {
                        emptyLibrary
                    } else if personal {
                        Button("Choose Discover rows", action: settings).buttonStyle(RoomToolbarStyle())
                    } else if issue == nil {
                        Text(personal ? "No recommendations or recent uploads yet." : "No videos available for \(category.title).")
                            .font(.system(size: 27)).foregroundStyle(RoomPalette.muted)
                    }
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        RoomShelfTitle(title: row.title)
                            .accessibilityIdentifier("discover-shelf-" + row.id)
                        RoomVideoShelf(videos: row.videos, focus: focus, discoveryShelfID: row.id,
                                       openMenu: openMenu) { video in play(video, row.videos) }
                    }
                }
            }
            .padding(.horizontal, 7).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .onChange(of: rows) { previous, current in
            guard let target = focus.wrappedValue, case .shelfVideo = target else { return }
            let next = Self.availableFocus(target, category: category, rows: current, previous: previous)
            if target != next { focus.wrappedValue = next }
        }
    }

    static func availableFocus(_ target: RoomBrowseFocus, category: RoomDiscoverCategory,
                               rows: [RoomDiscoverShelf], previous: [RoomDiscoverShelf] = []) -> RoomBrowseFocus {
        guard case let .shelfVideo(shelfID, videoID) = target else { return target }
        guard let row = rows.first(where: { $0.id == shelfID }), !row.videos.isEmpty else {
            return .discoverCategory(category)
        }
        if row.videos.contains(where: { $0.id == videoID }) { return target }
        // Keep the column when a refreshed row removes the current video.
        let index = previous.first { $0.id == shelfID }?.videos.firstIndex { $0.id == videoID } ?? 0
        return .shelfVideo(shelf: row.id, video: row.videos[min(index, row.videos.count - 1)].id)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoomShelfTitle(title: "Your recommendations")
            Text(signedIn ? "Follow a channel to see its recent uploads here." :
                    "Follow a channel on this Apple TV or sign in to see recommendations and recent uploads.")
                .font(.system(size: 27)).foregroundStyle(RoomPalette.muted)
            HStack(spacing: 18) {
                Button("Find a channel", action: findChannels).focused(focus, equals: .discoverFind)
                if !signedIn {
                    Button("Sign in to YouTube", action: signIn).focused(focus, equals: .discoverSignIn)
                }
            }
            .buttonStyle(RoomToolbarStyle())
        }
    }
}

private struct DiscoverChipStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 25, weight: .semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 21).frame(minHeight: 51)
            .foregroundStyle(focused || selected ? Color.black : .white)
            .background(focused ? Color.white : (selected ? RoomPalette.accent : RoomPalette.surface), in: Capsule())
            .overlay {
                if focused {
                    Capsule().strokeBorder(selected ? RoomPalette.accent : .white, lineWidth: 3).padding(-4)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
