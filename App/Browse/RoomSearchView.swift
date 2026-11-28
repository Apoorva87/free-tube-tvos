import SwiftUI

extension EnvironmentValues {
    @Entry var visitSearchCreator: ((RoomChannel) -> Void)? = nil
    @Entry var playSearchResultInDJ: ((ChannelVideo) -> Void)? = nil
}

@MainActor @Observable
final class RoomSearchHistory {
    private let defaults: UserDefaults
    private var key: String?
    private(set) var terms: [String] = []

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func select(_ scope: RoomDiscoveryCache.Scope?) {
        let owner: String
        switch scope {
        case .local: owner = "guest"
        case .profile(let id): owner = id
        case nil: return
        }
        let next = "room.recent-searches.v1." + owner
        guard key != next else { return }
        let pending = key == nil ? terms : []
        key = next
        terms = Array((defaults.stringArray(forKey: next) ?? []).prefix(6))
        for term in pending.reversed() { record(term) }
    }

    func record(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        terms.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        terms.insert(term, at: 0)
        terms = Array(terms.prefix(6))
        if let key { defaults.set(terms, forKey: key) }
    }

    func clear() {
        terms = []
        if let key { defaults.removeObject(forKey: key) }
    }
}

struct RoomSearchView: View {
    let account: ChannelAccount
    let library: ChannelLibrary
    let history: RoomSearchHistory
    @Binding var systemSearch: RoomSystemSearch.Request?
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let open: (RoomChannel) -> Void
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    let playInDJ: (ChannelVideo) -> Void
    @State private var query = ""
    @State private var showAsk = false
    @State private var submitted = ""
    @State private var revision = UUID()
    @State private var channels = [RoomChannel]()
    @State private var videos = [ChannelVideo]()
    @State private var next: String?
    @State private var isLoading = false
    @State private var attempted = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 20) {
                    TextField("Channel, video or @handle", text: $query)
                        .focused(focus, equals: .searchQuery)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .submitLabel(.search).onSubmit { submit() }
                    Button("Search") { submit() }.disabled(trimmed.isEmpty)
                    if !query.isEmpty || !submitted.isEmpty {
                        Button { clearSearch() } label: { Image(systemName: "xmark.circle") }
                            .accessibilityLabel("Clear search")
                    }
                    Button { showAsk = true } label: { Label("Ask AI", systemImage: "sparkles") }
                        .accessibilityIdentifier("search-ask-ai")
                }
                if !history.terms.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 20) {
                            Text("Recent searches").font(.headline)
                            Button("Clear history") { history.clear() }
                        }
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                ForEach(history.terms, id: \.self) { term in
                                    Button { query = term; submit() } label: {
                                        Text(term).lineLimit(1).frame(maxWidth: 360)
                                    }
                                    .accessibilityLabel(term)
                                }
                            }.padding(8)
                        }.scrollClipDisabled()
                    }
                    .buttonStyle(RoomToolbarStyle())
                }
                if isLoading { RoomLoading(text: "Searching…") }
                if let error { RoomNotice(message: error) }
                if !channels.isEmpty {
                    Text("Channels").font(.title2.bold())
                    RoomChannelGrid(channels: channels, open: open)
                }
                if !videos.isEmpty {
                    Text("Videos").font(.title2.bold())
                    RoomVideoGrid(videos: videos) { video in play(video, videos) }
                        .environment(\.visitSearchCreator, open)
                        .environment(\.playSearchResultInDJ, playInDJ)
                }
                if attempted && channels.isEmpty && videos.isEmpty && error == nil && !isLoading {
                    Text("No results for “\(submitted)”.")
                        .foregroundStyle(.secondary)
                }
                if next != nil && !isLoading {
                    Button("More results") { revision = UUID() }
                }
            }.padding(14)
        }
        .scrollClipDisabled()
        .sheet(isPresented: $showAsk) { RoomAskView(initialPrompt: trimmed) }
        .onChange(of: systemSearch, initial: true) {
            guard let request = systemSearch else { return }
            systemSearch = nil
            showAsk = false
            query = request.term
            submit()
        }
        .task(id: revision) { if !submitted.isEmpty { await search() } }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        history.record(trimmed)
        submitted = trimmed
        attempted = false
        channels = []
        videos = []
        error = nil
        next = nil
        revision = UUID()
    }

    private func clearSearch() {
        revision = UUID()
        query = ""
        submitted = ""
        channels = []
        videos = []
        next = nil
        attempted = false
        isLoading = false
        error = nil
    }

    @MainActor private func search() async {
        let active = revision
        let term = submitted
        isLoading = true
        error = nil
        defer {
            if active == revision && !Task.isCancelled { isLoading = false; attempted = true }
        }
        do {
            let token = account.isSignedIn ? try await account.accessToken() : nil
            let page: CatalogPage
            if let address = ChannelAddress(term) {
                let channel = try await library.api.find(address: address, token: token)
                page = CatalogPage(channels: [channel])
            } else if let token {
                page = try await library.api.search(term, token: token, page: next)
            } else {
                let localChannels = library.channels.filter { $0.title.localizedCaseInsensitiveContains(term) }
                let localVideos = library.videos.filter { $0.title.localizedCaseInsensitiveContains(term) || $0.channelTitle.localizedCaseInsensitiveContains(term) }
                do {
                    let publicPage = try await library.api.publicSearch(term)
                    page = CatalogPage(channels: localChannels + publicPage.channels, videos: localVideos + publicPage.videos)
                } catch {
                    guard active == revision, !Task.isCancelled else { return }
                    self.error = "Public search is unavailable. Try a channel URL or @handle. " + error.localizedDescription
                    page = CatalogPage(channels: localChannels, videos: localVideos)
                }
            }
            guard active == revision, !Task.isCancelled else { return }
            var channelIDs = Set(channels.map(\.id))
            var videoIDs = Set(videos.map(\.id))
            channels += page.channels.filter { channelIDs.insert($0.id).inserted }
            videos += page.videos.filter { videoIDs.insert($0.id).inserted }
            next = page.next
        } catch {
            guard active == revision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

struct RoomChannelView: View {
    let account: ChannelAccount
    let library: ChannelLibrary
    let channel: RoomChannel
    var returnToPlayer: (() -> Void)? = nil
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detailed: RoomChannel?
    @State private var showingSubscription = false
    @State private var videos = [ChannelVideo]()
    @State private var popular = [ChannelVideo]()
    @State private var isLoadingPopular = true
    @State private var popularError: String?
    @State private var popularRevision = UUID()
    @State private var next: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var revision = UUID()

    private var followed: Bool { library.followed.contains(channel.id) }
    private var imported: Bool { library.imported.contains { $0.id == channel.id } }
    private var subscriptionURL: URL? {
        guard ChannelAddress.isID(channel.id) else { return nil }
        return URL(string: "https://www.youtube.com/channel/" + channel.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Button(action: returnToPlayer ?? { dismiss() }) { Label("Back", systemImage: "chevron.left") }
                        .accessibilityIdentifier("player-panel-back")
                    Spacer()
                    if imported {
                        Label("Subscribed on YouTube", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary).accessibilityIdentifier("player-creator-subscribed")
                    } else if ChannelAddress.isID(channel.id) {
                        if returnToPlayer != nil {
                            Button { showingSubscription = true } label: {
                                Label("Subscribe on YouTube", systemImage: "qrcode")
                            }
                            .accessibilityIdentifier("player-creator-subscribe")
                        }
                        Button {
                            library.toggle(detailed ?? channel, preview: videos)
                            if returnToPlayer != nil { library.requestRefresh() }
                        } label: {
                            Label(followed ? "Unfollow on this TV" : "Follow on this TV", systemImage: followed ? "checkmark" : "plus")
                        }
                        .accessibilityIdentifier("player-creator-follow")
                    }
                }
                .buttonStyle(RoomToolbarStyle())
                HStack(spacing: 20) {
                    RoomAvatar(channel: detailed ?? channel, symbol: "person.fill", size: 74)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detailed?.title ?? channel.title).font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader).accessibilityIdentifier("player-creator-title")
                        if let handle = (detailed ?? channel).handle {
                            Text(handle).font(.headline).foregroundStyle(RoomPalette.muted)
                        }
                    }
                }
                if isLoading { RoomLoading(text: "Loading uploads…").accessibilityIdentifier("player-panel-loading") }
                if let error {
                    RoomNotice(message: error).accessibilityIdentifier("player-panel-error")
                    Button("Try again") { revision = UUID() }.accessibilityIdentifier("player-panel-retry")
                }
                ForEach(RoomCreatorShelf.rows(for: channel.id, recent: videos, popular: popular, facts: library.videoFacts)) { row in
                    CreatorVideoRow(row: row) { play($0, row.videos) }
                    if row.kind == .recent { moreUploads }
                }
                if videos.isEmpty { moreUploads }
                if isLoadingPopular {
                    RoomLoading(text: "Loading most viewed…")
                } else if let popularError {
                    RoomNotice(message: "Most viewed couldn’t load. " + popularError)
                    Button("Retry most viewed") { popularRevision = UUID() }
                }
                if !isLoading && !isLoadingPopular && videos.isEmpty && popular.isEmpty && error == nil && popularError == nil {
                    Text("This channel has no public uploads.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("player-panel-empty")
                }
            }.padding(returnToPlayer == nil ? 16 : 42)
        }
        .scrollClipDisabled()
        .toolbar(.hidden, for: .navigationBar)
        .background(RoomPalette.background.ignoresSafeArea())
        .onExitCommand(perform: showingSubscription ? nil : returnToPlayer)
        .sheet(isPresented: $showingSubscription, onDismiss: {
            if account.isSignedIn { library.requestRefresh() }
        }) {
            if let url = subscriptionURL {
                VStack(spacing: 24) {
                    Text(detailed?.title ?? channel.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    RoomQRCode(url: url, size: 300)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("YouTube channel QR code")
                        .accessibilityValue(url.absoluteString)
                        .accessibilityIdentifier("player-creator-subscribe-qr")
                    Text("Scan with your phone, then choose Subscribe on YouTube.")
                        .font(.headline).multilineTextAlignment(.center)
                    Button("Done") { showingSubscription = false }
                        .accessibilityIdentifier("player-creator-subscribe-done")
                }
                .padding(42)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoomPalette.background.ignoresSafeArea())
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player-creator-subscribe-sheet")
                .onExitCommand { showingSubscription = false }
            }
        }
        .task(id: revision) { await load() }
        .task(id: popularRevision) { await loadPopular() }
    }

    @ViewBuilder private var moreUploads: some View {
        if next != nil && !isLoading && error == nil {
            Button("More uploads") { revision = UUID() }
        }
    }

    @MainActor private func loadPopular() async {
        isLoadingPopular = true
        popularError = nil
        defer { if !Task.isCancelled { isLoadingPopular = false } }
        do {
            let token = account.isSignedIn ? try? await account.accessToken() : nil
            try Task.checkCancellation()
            let results = try await library.api.mostViewed(channel, token: token)
            try Task.checkCancellation()
            popular = results
        } catch {
            guard !Task.isCancelled else { return }
            popularError = error.localizedDescription
        }
    }

    @MainActor private func load() async {
        isLoading = true
        error = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            var token: String?
            var resolved = detailed ?? channel
            do {
                token = account.isSignedIn ? try await account.accessToken() : nil
                if token != nil && resolved.uploadsID == nil {
                    resolved = try await library.api.find(address: .id(channel.id), token: token)
                }
            } catch {
                try Task.checkCancellation()
                // The first page of a creator's uploads is also available publicly.
                guard next == nil else { throw error }
                token = nil
            }
            try Task.checkCancellation()
            let page = try await library.api.uploads(resolved, token: token, page: next)
            try Task.checkCancellation()
            detailed = resolved
            var seen = Set(videos.map(\.id))
            videos += page.videos.filter { seen.insert($0.id).inserted }
            next = page.next
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct CreatorVideoRow: View {
    let row: RoomCreatorShelf
    let play: (ChannelVideo) -> Void
    // A video can appear on multiple shelves. Each row tracks its own remote focus.
    @FocusState private var focus: RoomBrowseFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoomShelfTitle(title: row.kind.rawValue)
            RoomVideoShelf(videos: row.videos, focus: $focus, openMenu: {}, action: play)
        }
    }
}
