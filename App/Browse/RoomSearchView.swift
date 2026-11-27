import SwiftUI

struct RoomSearchView: View {
    let account: ChannelAccount
    let library: ChannelLibrary
    let open: (RoomChannel) -> Void
    let play: (ChannelVideo, [ChannelVideo]) -> Void
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
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .submitLabel(.search).onSubmit { submit() }
                    Button("Search") { submit() }.disabled(trimmed.isEmpty)
                    Button { showAsk = true } label: { Label("Ask AI", systemImage: "sparkles") }
                        .accessibilityIdentifier("search-ask-ai")
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
        .task(id: revision) { if !submitted.isEmpty { await search() } }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        submitted = trimmed
        attempted = false
        channels = []
        videos = []
        error = nil
        next = nil
        revision = UUID()
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
                RoomShelfTitle(title: "Recent uploads")
                if isLoading { RoomLoading(text: "Loading uploads…").accessibilityIdentifier("player-panel-loading") }
                if let error {
                    RoomNotice(message: error).accessibilityIdentifier("player-panel-error")
                    Button("Try again") { revision = UUID() }.accessibilityIdentifier("player-panel-retry")
                }
                if !isLoading && videos.isEmpty && error == nil {
                    Text("This channel has no recent public uploads.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("player-panel-empty")
                }
                RoomVideoGrid(videos: videos) { video in
                    play(video, videos)
                }
                if next != nil && !isLoading && error == nil {
                    Button("More uploads") { revision = UUID() }
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
                guard returnToPlayer != nil, next == nil else { throw error }
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
