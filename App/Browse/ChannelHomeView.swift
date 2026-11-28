import AVFoundation
import SwiftUI

enum RoomSection: String, CaseIterable {
    case discover = "Discover", home = "Home", channels = "Channels", search = "Search", playlists = "Playlists", history = "History", dj = "DJ", assistant = "Ask AI", settings = "Settings"
    static let sidebarOrder: [Self] = [.discover, .home, .channels, .playlists, .history, .dj, .search, .assistant, .settings]
    var title: String {
        switch self {
        case .channels: "Subscriptions"
        case .dj: "DJ Mode"
        default: rawValue
        }
    }
    var navigationID: String { self == .assistant ? "assistant" : rawValue.lowercased() }
    var icon: String {
        switch self {
        case .discover: "safari.fill"
        case .home: "house.fill"
        case .channels: "rectangle.stack.fill"
        case .search: "magnifyingglass"
        case .assistant: "sparkles"
        case .settings: "gearshape"
        case .playlists: "list.and.film"
        case .history: "clock.arrow.circlepath"
        case .dj: "music.note.list"
        }
    }
}

enum RoomBrowseFocus: Hashable {
    case settingsFirst, menu, featured, newPlaylist, assistantPrompt, djSearch, searchQuery, historyBrowse, navigation(RoomSection), subscriptionFilter(String?), account, video(String), channel(String)
    case discoverCategory(RoomDiscoverCategory), discoverRefresh, discoverFind, discoverSignIn
    case shelfVideo(shelf: String, video: String)

    static func video(_ id: String, in shelf: String?) -> Self {
        shelf.map { .shelfVideo(shelf: $0, video: id) } ?? .video(id)
    }
}

private struct RoomFocusKey: EnvironmentKey {
    static var defaultValue: FocusState<RoomBrowseFocus?>.Binding? { nil }
}

extension EnvironmentValues {
    var roomBrowseFocus: FocusState<RoomBrowseFocus?>.Binding? {
        get { self[RoomFocusKey.self] }
        set { self[RoomFocusKey.self] = newValue }
    }
}

struct ChannelHomeView: View {
    let account: ChannelAccount
    let onPlay: (ChannelVideo, [ChannelVideo]) -> Void
    @State private var accountOpen = ProcessInfo.processInfo.arguments.contains("--sign-in") ||
        ProcessInfo.processInfo.arguments.contains("--switch-profile")
    @State private var startsProfileSwitch = ProcessInfo.processInfo.arguments.contains("--switch-profile")

    var body: some View {
        // Discard account-derived listings, previews and async tasks together on sign-out.
        RoomShell(account: account, onPlay: onPlay, accountOpen: $accountOpen, startsProfileSwitch: $startsProfileSwitch).id(account.sessionID)
            .onChange(of: account.sessionID) { _, _ in
                if account.isSignedIn { accountOpen = false }
            }
    }
}

private struct RoomShell: View {
    @Environment(RoomViewingSession.self) private var viewing
    let account: ChannelAccount
    let onPlay: (ChannelVideo, [ChannelVideo]) -> Void
    @State private var library = ChannelLibrary()
    @State private var history = RoomWatchHistoryStore()
    @State private var recentSearches = RoomSearchHistory()
    @State private var systemSearch: RoomSystemSearch.Request?
    @State private var section = RoomSection.discover
    @State private var chosenCategory: RoomDiscoverCategory?
    @State private var categoryCatalog = RoomCategoryCatalog()
    @State private var preferences = RoomDiscoverPreferences()
    @State private var interestFeed = RoomInterestFeed()
    @State private var categoryReload: UUID?
    @Binding var accountOpen: Bool
    @Binding var startsProfileSwitch: Bool
    @State private var channel: RoomChannel?
    @State private var menuOpen = false
    @State private var lastTile: RoomBrowseFocus?
    @State private var featureOptions = false
    @State private var savingVideo: ChannelVideo?
    @FocusState private var focus: RoomBrowseFocus?

    private var discoverCategory: RoomDiscoverCategory {
        chosenCategory ?? .forYou
    }

    private var discoverRows: [RoomDiscoverShelf] {
        if discoverCategory == .forYou { return personalizedRows }
        let rows = categoryCatalog.category == discoverCategory ? categoryCatalog.shelves : []
        return discoverCategory == .music ? categoryCatalog.music.shelves(history: history.videos, publicRows: rows) : rows
    }

    private var personalizedRows: [RoomDiscoverShelf] {
        let enabled = preferences.rows.filter(\.enabled)
        let legacy = enabled.contains { $0.query.isEmpty } ? library.discoverShelves : []
        var seen = Set<String>()
        return enabled.flatMap { row -> [RoomDiscoverShelf] in
            switch row.id {
            case "personal": return legacy.filter { ["for-you", "from-subscriptions"].contains($0.id) }
            case "channels": return legacy.filter { $0.id.hasPrefix("channel-") }
            default: return interestFeed.shelves.filter { $0.id == row.id }
            }
        }.compactMap { shelf in
            let videos = shelf.videos.filter { seen.insert($0.id).inserted }
            return videos.isEmpty ? nil : RoomDiscoverShelf(id: shelf.id, title: shelf.title, videos: videos)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            browse
            if viewing.presentation == .closed, let notice = viewing.queueNotice {
                Text(notice).font(.headline).padding().background(.regularMaterial, in: Capsule())
                    .padding(24).allowsHitTesting(false)
            }
            if viewing.presentation == .mini {
                ChannelPlayerView(session: viewing, mini: true)
                    .frame(width: ChannelPlayerView.miniVideoWidth, height: ChannelPlayerView.miniHeight)
                    .padding(22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPlayPauseCommand(perform: viewing.presentation == .mini ? {
            let player = viewing.playback.player
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        } : nil)
        .fullScreenCover(isPresented: Binding(
            get: { viewing.presentation == .full },
            set: { if !$0, viewing.presentation == .full { viewing.close() } }
        )) {
            ChannelPlayerView(session: viewing, mini: false)
        }
        .environment(library)
        .onChange(of: RoomSystemSearch.shared.pending, initial: true) {
            guard let request = RoomSystemSearch.shared.take() else { return }
            accountOpen = false
            channel = nil
            savingVideo = nil
            featureOptions = false
            viewing.browseDuringPlayback()
            lastTile = nil
            choose(.search)
            systemSearch = request
        }
    }

    private var browse: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 20) {
                    if section != .home && section != .discover {
                        HStack(spacing: 20) {
                            if section == .search {
                                Button { menuOpen = true } label: { Image(systemName: "sidebar.left") }
                                .buttonStyle(RoomToolbarStyle()).focused($focus, equals: .menu)
                                .accessibilityLabel("Open navigation")
                            }
                            Text(section.title)
                                .font(.system(size: 48, weight: .bold))
                        }
                    }
                    Group {
                        switch section {
                        case .discover:
                            RoomDiscoverView(library: library, catalog: categoryCatalog, preferences: preferences, interestFeed: interestFeed,
                                             rows: discoverRows, musicHistory: discoverCategory == .music ? history.videos : [],
                                             settings: { choose(.settings) }, category: discoverCategory,
                                             reloadID: categoryReload, signedIn: account.isSignedIn, focus: $focus,
                                             select: { chosenCategory = $0; categoryReload = nil },
                                             refresh: refreshDiscover, openMenu: { menuOpen = true }, play: onPlay,
                                             findChannels: { choose(.search) }, signIn: { accountOpen = true })
                        case .settings: RoomDiscoverSettings(preferences: preferences, focus: $focus)
                        case .home: home
                        case .channels:
                            RoomSubscriptionsView(library: library, focus: $focus, play: onPlay, openChannel: { channel = $0 },
                                                  findChannels: { section = .search })
                        case .assistant:
                            RoomAskView(inSidebar: true)
                        case .playlists:
                            RoomPlaylistsView(focus: $focus, play: viewing.openPlaylist)
                        case .history:
                            RoomWatchHistoryView(store: history, focus: $focus, play: onPlay, browse: { choose(.home) })
                        case .dj:
                            RoomDJView(history: history.videos, preferences: preferences, music: categoryCatalog.music,
                                       interestFeed: interestFeed, focus: $focus, openMenu: { menuOpen = true })
                                .environment(\.fetchTileFacts, false)
                        case .search:
                            RoomSearchView(account: account, library: library, history: recentSearches, systemSearch: $systemSearch, focus: $focus, open: { channel = $0 },
                                           play: onPlay, playInDJ: { video in
                                viewing.djStation.playNow(video)
                                choose(.dj)
                            })
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.leading, section == .search ? 12 : 68)
                .disabled(menuOpen).accessibilityHidden(menuOpen)
                .onExitCommand { menuOpen = true }
                RoomBrowseRail(profile: library.profile, section: section, visible: section != .search && !menuOpen,
                               focus: $focus, lastTile: $lastTile, open: { menuOpen = true }, choose: choose)
                if menuOpen {
                    Color.black.opacity(0.62).ignoresSafeArea().accessibilityHidden(true)
                    drawer
                }
            }
            .environment(\.roomBrowseFocus, $focus)
            .environment(\.roomVideoFacts, library.videoFacts)
            .defaultFocus($focus, firstFocus(in: section))
            .onChange(of: viewing.presentation) { previous, current in
                if previous == .full, current != .full, !menuOpen {
                    closeMenu(to: returningFocus(in: section))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(RoomPalette.background.ignoresSafeArea())
            .navigationDestination(item: $channel) { selected in
                RoomChannelView(account: account, library: library, channel: selected, play: onPlay)
            }
        }
        .sheet(isPresented: $accountOpen) {
            ChannelAccountView(account: account, profile: library.profile, inventory: library.subscriptionInventory, startsSwitch: startsProfileSwitch)
                .onAppear { startsProfileSwitch = false }
        }
        .sheet(item: $savingVideo) { video in
            RoomAddToPlaylistView(video: video).environment(\.roomVideoFacts, library.videoFacts)
        }
        .confirmationDialog("Featured video", isPresented: $featureOptions) {
            if let feature = library.videos.first {
                Button("Add to playlist") { savingVideo = feature }
            }
            if let feature = library.videos.first, let owner = library.channels.first(where: { $0.id == feature.channelID }) {
                Button("View channel") { channel = owner }
            }
            Button("Refresh Home") { library.requestRefresh() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: library.refreshID) { await library.refresh(account: account) }
        .onChange(of: RoomWatchHistoryStore.Scope(signedIn: account.isSignedIn, profileID: library.profile?.id), initial: true) { _, scope in
            history.select(scope)
            recentSearches.select(scope)
            viewing.djStation.select(scope, sessionID: account.sessionID)
            viewing.onVideoStarted = { [weak history, weak account, id = account.sessionID] video in
                guard account?.sessionID == id else { return }
                history?.record(video)
            }
        }
        .onChange(of: history.videos, initial: true) {
            library.setDiscoverHistory(history.videos)
        }
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                closeMenu(to: .menu)
                accountOpen = true
            } label: {
                HStack(spacing: 18) {
                    RoomAvatar(channel: library.profile, symbol: "person.fill", size: 50)
                    Text(library.profile?.title ?? (account.isSignedIn ? "Account" : "Sign in")).lineLimit(1)
                }
            }
            .buttonStyle(RailButtonStyle(selected: false)).focused($focus, equals: .account)
            .accessibilityIdentifier("account").padding(.bottom, 18)
            ForEach(RoomSection.sidebarOrder, id: \.self) { item in
                Button { choose(item) } label: {
                    Label(item.title, systemImage: item.icon)
                }
                .buttonStyle(RailButtonStyle(selected: section == item)).focused($focus, equals: .navigation(item))
                .accessibilityIdentifier("nav-" + item.navigationID)
            }
            if viewing.presentation == .mini {
                Button {
                    menuOpen = false
                    viewing.expand()
                } label: { Label("Expand video", systemImage: "pip.exit") }
                .buttonStyle(RailButtonStyle(selected: false)).accessibilityIdentifier("drawer-mini-expand")
                Button {
                    viewing.close()
                    closeMenu(to: returningFocus(in: section))
                } label: { Label("Close video", systemImage: "xmark") }
                .buttonStyle(RailButtonStyle(selected: false)).accessibilityIdentifier("drawer-mini-close")
            }
            Divider().overlay(RoomPalette.muted.opacity(0.4)).padding(.vertical, 14)
            Button {
                if section == .discover {
                    refreshDiscover()
                    closeMenu(to: .discoverCategory(discoverCategory))
                } else {
                    library.requestRefresh()
                    choose(.home)
                }
            } label: { Label(section == .discover ? "Refresh Discover" : "Refresh Home", systemImage: "arrow.clockwise") }
            .buttonStyle(RailButtonStyle(selected: false))
            Spacer()
        }
        .padding(.leading, 18).padding(.trailing, 36).padding(.top, 4)
        .frame(width: 445)
        .background(alignment: .leading) {
            LinearGradient(stops: [.init(color: RoomPalette.background, location: 0.85),
                                   .init(color: RoomPalette.background.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .padding(.leading, -100).padding(.trailing, -100).ignoresSafeArea()
        }
        .offset(x: -55)
        .task { focus = .navigation(section) }
        .onMoveCommand { if $0 == .right { choose(section) } }
    }

    private func choose(_ item: RoomSection) {
        if item != section {
            lastTile = nil
            categoryReload = nil
        }
        section = item
        closeMenu(to: returningFocus(in: item))
    }

    private func firstFocus(in item: RoomSection) -> RoomBrowseFocus {
        switch item {
        case .discover: .discoverCategory(discoverCategory)
        case .home: library.videos.isEmpty ? .menu : .featured
        case .channels: .subscriptionFilter(nil)
        case .playlists: .newPlaylist
        case .history: history.firstFocus
        case .dj: .djSearch
        case .assistant: .assistantPrompt
        case .settings: .settingsFirst
        case .search: .searchQuery
        }
    }

    private func returningFocus(in item: RoomSection) -> RoomBrowseFocus {
        guard let lastTile else { return firstFocus(in: item) }
        if item == .discover, case .shelfVideo = lastTile {
            return RoomDiscoverView.availableFocus(lastTile, category: discoverCategory, rows: discoverRows)
        }
        return lastTile
    }

    private func refreshDiscover() {
        if discoverCategory == .forYou && preferences.rows.contains(where: { $0.enabled && $0.query.isEmpty }) {
            library.requestRefresh()
        }
        categoryReload = UUID()
    }

    private func closeMenu(to target: RoomBrowseFocus) {
        menuOpen = false
        Task { @MainActor in
            await Task.yield()
            guard !menuOpen, viewing.presentation != .full else { return }
            focus = target
        }
    }

    @ViewBuilder private var home: some View {
        if library.channels.isEmpty && !library.isLoading && library.warning == nil {
            VStack(alignment: .leading, spacing: 26) {
                Spacer()
                Image(systemName: "rectangle.stack.fill").font(.system(size: 64)).foregroundStyle(RoomPalette.accent)
                Text("Your subscriptions").font(.system(size: 72, weight: .bold))
                Text(account.isSignedIn
                     ? "Follow a channel to see its latest uploads here."
                     : "Bring your YouTube subscriptions here, or follow channels on this Apple TV.")
                    .font(.system(size: 33)).foregroundStyle(.secondary)
                    .frame(maxWidth: 850, alignment: .leading)
                HStack(spacing: 24) {
                    if !account.isSignedIn {
                        Button("Sign in to YouTube") { accountOpen = true }
                    }
                    Button("Find a channel") { section = .search }
                }
                .padding(.top, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RoomHomeShelves(library: library, focus: $focus, play: onPlay, discover: { onPlay($0, [$0]) },
                            options: { featureOptions = true }, openMenu: { menuOpen = true })
        }
    }
}

enum RoomPalette {
    static let accent = Color(red: 1.0, green: 0.51, blue: 0.36)
    static let background = Color(white: 0.060)
    static let surface = Color(white: 0.17)
    static let muted = Color(white: 0.72)
}

private struct RoomBrowseRail: View {
    let profile: RoomChannel?
    let section: RoomSection
    let visible: Bool
    let focus: FocusState<RoomBrowseFocus?>.Binding
    @Binding var lastTile: RoomBrowseFocus?
    let open: () -> Void
    let choose: (RoomSection) -> Void

    var body: some View {
        ZStack {
            if visible && !tileFocused { compactRail }
        }
        .onChange(of: focus.wrappedValue) { _, target in
            switch target {
            case .settingsFirst, .featured, .newPlaylist, .historyBrowse, .djSearch, .searchQuery, .video, .channel, .subscriptionFilter,
                 .discoverCategory, .discoverRefresh, .discoverFind, .discoverSignIn, .shelfVideo:
                lastTile = target
            default: break
            }
        }
    }

    private var tileFocused: Bool {
        if case .video = focus.wrappedValue { return true }
        if case .shelfVideo = focus.wrappedValue { return true }
        if case .channel = focus.wrappedValue { return true }
        return false
    }

    private var compactRail: some View {
        VStack(spacing: 8) {
            Button(action: open) {
                RoomAvatar(channel: profile, symbol: "person.fill", size: 50)
            }
            .focused(focus, equals: .menu)
            .accessibilityLabel("Open navigation").accessibilityIdentifier("show-menu")
            .padding(.bottom, 14)
            ForEach(RoomSection.sidebarOrder, id: \.self) { item in
                Button { choose(item) } label: {
                    Image(systemName: item.icon).font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(item == section ? .white : RoomPalette.muted)
                }
                .focused(focus, equals: .navigation(item))
                .accessibilityLabel(item.title).accessibilityIdentifier("compact-" + item.navigationID)
            }
            Spacer()
        }
        .buttonStyle(CompactRailStyle())
        .focusSection()
        .offset(x: -30).onExitCommand(perform: open)
    }
}

private struct CompactRailStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 58, height: 62)
            .background {
                if focused {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white, lineWidth: 3)
                }
            }
    }
}

struct RoomShelfTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).font(.system(size: 33, weight: .bold)).tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: 22, weight: .medium)).foregroundStyle(RoomPalette.muted)
                    .lineLimit(1)
            }
        }
    }
}

struct RoomToolbarStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 23, weight: .semibold))
            .padding(.horizontal, 17).frame(minWidth: 54, minHeight: 48)
            .foregroundStyle(focused ? Color.black : .white)
            .background(focused ? Color.white : RoomPalette.surface, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct RailButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 30, weight: selected || focused ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 16)
            .foregroundStyle(focused ? Color.black : (selected ? .white : .gray))
            .background(focused ? Color.white : (selected ? RoomPalette.surface : .clear), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct RoomHeading: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 58, weight: .bold)).tracking(-1.5)
            if let subtitle { Text(subtitle).font(.system(size: 27)).foregroundStyle(.secondary) }
        }
    }
}

struct RoomLoading: View {
    let text: String
    var body: some View {
        HStack(spacing: 18) { ProgressView().controlSize(.small); Text(text).font(.system(size: 27)) }
            .foregroundStyle(.secondary)
    }
}

struct RoomNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 26)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct RoomTileGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        let column = GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 410 : 292),
                              spacing: 22, alignment: .topLeading)
        LazyVGrid(columns: [column], alignment: .leading, spacing: 24, content: content)
    }
}

struct RoomVideoGrid: View {
    let videos: [ChannelVideo]
    var numbered = false
    var durations: [String: Int] = [:]
    let action: (ChannelVideo) -> Void
    @Environment(\.roomBrowseFocus) private var suppliedFocus
    @FocusState private var localFocus: RoomBrowseFocus?

    var body: some View {
        RoomTileGrid {
            ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                RoomVideoTile(video: video, focus: suppliedFocus ?? $localFocus,
                              position: numbered ? index + 1 : nil, seconds: durations[video.id]) { action(video) }
            }
        }
    }
}

struct RoomChannelGrid: View {
    let channels: [RoomChannel]
    let open: (RoomChannel) -> Void
    @Environment(\.roomBrowseFocus) private var suppliedFocus
    @FocusState private var localFocus: RoomBrowseFocus?
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 285), spacing: 20)], alignment: .leading, spacing: 18) {
            ForEach(channels) { channel in
                Button { open(channel) } label: {
                    HStack(spacing: 18) {
                        RoomArtwork(url: channel.thumbnail, placeholder: "person.fill")
                            .frame(width: 60, height: 60).clipShape(Circle())
                        Text(channel.title).font(.system(size: 26, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.padding(12).background(RoomPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(RoomCardStyle())
                    .focused(suppliedFocus ?? $localFocus, equals: .channel(channel.id))
            }
        }
    }
}

struct RoomArtwork: View {
    let url: URL?
    let placeholder: String
    var body: some View {
        ZStack {
            RoomPalette.surface
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Image(systemName: placeholder).foregroundStyle(.secondary).font(.system(size: 30)) }
            }
        }.clipped().accessibilityHidden(true)
    }
}

private struct RoomCardStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(5)
            .background(focused ? RoomPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Color.white : .clear, lineWidth: 3) }
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.99 : (focused ? 1.025 : 1)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: focused)
    }
}
