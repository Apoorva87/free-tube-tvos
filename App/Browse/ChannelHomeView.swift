import SwiftUI

enum RoomSection: String, CaseIterable {
    case home = "Home", channels = "Channels", search = "Search"
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .channels: "rectangle.stack.fill"
        case .search: "magnifyingglass"
        }
    }
}

enum RoomBrowseFocus: Hashable {
    case menu, featured, navigation(RoomSection), subscriptionFilter(String?), account, video(String), channel(String)
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
    @State private var section = RoomSection.home
    @Binding var accountOpen: Bool
    @Binding var startsProfileSwitch: Bool
    @State private var channel: RoomChannel?
    @State private var pendingVideo: ChannelVideo?
    @State private var refresh = UUID()
    @State private var menuOpen = false
    @State private var lastTile: RoomBrowseFocus?
    @State private var featureOptions = false
    @FocusState private var focus: RoomBrowseFocus?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 20) {
                    if section != .home {
                        HStack(spacing: 20) {
                            if section == .search {
                                Button { menuOpen = true } label: { Image(systemName: "sidebar.left") }
                                .buttonStyle(RoomToolbarStyle()).focused($focus, equals: .menu)
                                .accessibilityLabel("Open navigation")
                            }
                            Text(section == .channels ? "Subscriptions" : section.rawValue)
                                .font(.system(size: 48, weight: .bold))
                        }
                    }
                    Group {
                        switch section {
                        case .home: home
                        case .channels:
                            RoomSubscriptionsView(library: library, focus: $focus, play: play, openChannel: { channel = $0 },
                                                  findChannels: { section = .search })
                        case .search:
                            RoomSearchView(account: account, library: library, open: { channel = $0 }, play: play)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.leading, section == .search ? 12 : 68)
                .disabled(menuOpen).accessibilityHidden(menuOpen)
                .onExitCommand { menuOpen = true }
                RoomBrowseRail(profile: library.profile, section: section, visible: section != .search && !menuOpen,
                               focus: $focus, lastTile: $lastTile, open: { menuOpen = true })
                if menuOpen {
                    Color.black.opacity(0.62).ignoresSafeArea().accessibilityHidden(true)
                    drawer
                }
            }
            .environment(\.roomBrowseFocus, $focus)
            .environment(\.roomVideoFacts, library.videoFacts)
            .defaultFocus($focus, .featured)
            .onChange(of: viewing.presentation) { previous, current in
                if previous == .full, current != .full, !menuOpen {
                    let first: RoomBrowseFocus = section == .home ? .featured : (section == .channels ? .subscriptionFilter(nil) : .menu)
                    closeMenu(to: lastTile ?? first)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(RoomPalette.background.ignoresSafeArea())
            .navigationDestination(item: $channel) { selected in
                RoomChannelView(account: account, library: library, channel: selected, play: play)
            }
        }
        .alert("Follow this channel to watch?", isPresented: Binding(
            get: { pendingVideo != nil },
            set: { if !$0 { pendingVideo = nil } }
        ), presenting: pendingVideo) { video in
            Button("Follow and play") {
                let owner = RoomChannel(id: video.channelID, title: video.channelTitle)
                if !library.followed.contains(owner.id) { library.toggle(owner, preview: []) }
                refresh = UUID()
                play(video, library.videos)
            }
            Button("Cancel", role: .cancel) {}
        } message: { video in
            Text("\(video.channelTitle) will appear in Home on this Apple TV.")
        }
        .sheet(isPresented: $accountOpen) {
            ChannelAccountView(account: account, profile: library.profile, inventory: library.subscriptionInventory, startsSwitch: startsProfileSwitch)
                .onAppear { startsProfileSwitch = false }
        }
        .confirmationDialog("Featured video", isPresented: $featureOptions) {
            if let feature = library.videos.first, let owner = library.channels.first(where: { $0.id == feature.channelID }) {
                Button("View channel") { channel = owner }
            }
            Button("Refresh Home") { refresh = UUID() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: refresh) { await library.refresh(account: account) }
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
            ForEach([RoomSection.search, .home, .channels], id: \.self) { item in
                Button { choose(item) } label: {
                    Label(item == .channels ? "Subscriptions" : item.rawValue, systemImage: item.icon)
                }
                .buttonStyle(RailButtonStyle(selected: section == item)).focused($focus, equals: .navigation(item))
                .accessibilityIdentifier("nav-" + item.rawValue.lowercased())
            }
            if viewing.presentation == .mini {
                Button {
                    menuOpen = false
                    viewing.expand()
                } label: { Label("Expand video", systemImage: "pip.exit") }
                .buttonStyle(RailButtonStyle(selected: false)).accessibilityIdentifier("drawer-mini-expand")
                Button {
                    viewing.close()
                    closeMenu(to: lastTile ?? .menu)
                } label: { Label("Close video", systemImage: "xmark") }
                .buttonStyle(RailButtonStyle(selected: false)).accessibilityIdentifier("drawer-mini-close")
            }
            Divider().overlay(RoomPalette.muted.opacity(0.4)).padding(.vertical, 14)
            Button {
                refresh = UUID()
                choose(.home)
            } label: { Label("Refresh Home", systemImage: "arrow.clockwise") }
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
        let retained = item == section ? lastTile : nil
        if item != section { lastTile = nil }
        section = item
        let first: RoomBrowseFocus? = switch item {
        case .home: library.videos.isEmpty ? nil : .featured
        case .channels: .subscriptionFilter(nil)
        case .search: nil
        }
        closeMenu(to: retained ?? first ?? .menu)
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
            RoomHomeShelves(library: library, focus: $focus, play: play, discover: { onPlay($0, [$0]) },
                            options: { featureOptions = true }, openMenu: { menuOpen = true })
        }
    }

    private func play(_ video: ChannelVideo, _ context: [ChannelVideo]) {
        let followed = library.followed
        guard followed.contains(video.channelID) else {
            pendingVideo = video
            return
        }
        // Public search reports approximate dates. Start that selection immediately and
        // continue with dated uploads from the user's followed feed.
        if video.publishedAt == .distantPast {
            let following = ChannelVideo.chronological(context.filter { $0.id != video.id }, followed: followed)
            onPlay(video, [video] + following)
        } else {
            let queue = ChannelVideo.chronological([video] + context, followed: followed)
            onPlay(video, queue)
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

    var body: some View {
        ZStack {
            if visible && !tileFocused { compactRail }
        }
        .onChange(of: focus.wrappedValue) { _, target in
            switch target {
            case .featured, .video, .channel, .subscriptionFilter: lastTile = target
            default: break
            }
        }
    }

    private var tileFocused: Bool {
        if case .video = focus.wrappedValue { return true }
        if case .channel = focus.wrappedValue { return true }
        return false
    }

    private var compactRail: some View {
        Button(action: open) {
            VStack(spacing: 39) {
                RoomAvatar(channel: profile, symbol: "person.fill", size: 50)
                    .padding(.bottom, 22)
                ForEach([RoomSection.search, .home, .channels], id: \.self) { item in
                    Image(systemName: item.icon).font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(item == section ? .white : RoomPalette.muted)
                }
                Spacer()
            }.padding(.top, 10).frame(width: 58)
        }
        .buttonStyle(CompactRailStyle()).focused(focus, equals: .menu)
        .accessibilityLabel("Open navigation").accessibilityIdentifier("show-menu")
        .offset(x: -30).onExitCommand(perform: open)
    }
}

private struct CompactRailStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(alignment: .top) {
                if focused {
                    RoundedRectangle(cornerRadius: 30).strokeBorder(Color.white, lineWidth: 3).frame(height: 74)
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

struct RoomVideoGrid: View {
    let videos: [ChannelVideo]
    let action: (ChannelVideo) -> Void
    @Environment(\.roomBrowseFocus) private var suppliedFocus
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var localFocus: RoomBrowseFocus?

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .topLeading),
                            count: typeSize.isAccessibilitySize ? 3 : 5)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(videos) { video in
                RoomVideoTile(video: video, focus: suppliedFocus ?? $localFocus) { action(video) }
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
