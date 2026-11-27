import SwiftUI

struct RoomSearchView: View {
    let account: ChannelAccount
    let library: ChannelLibrary
    let open: (RoomChannel) -> Void
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    @State private var query = ""
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
                }
                if isLoading { RoomLoading(text: "Searching…") }
                if let error { RoomNotice(message: error) }
                if !channels.isEmpty {
                    Text("Channels").font(.title2.bold())
                    RoomChannelGrid(channels: channels, open: open)
                }
                if !videos.isEmpty {
                    Text("Videos").font(.title2.bold())
                    RoomVideoGrid(videos: videos) { video in play(video, library.videos) }
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
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detailed: RoomChannel?
    @State private var pendingVideo: ChannelVideo?
    @State private var videos = [ChannelVideo]()
    @State private var next: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var revision = UUID()

    private var followed: Bool { library.followed.contains(channel.id) }
    private var imported: Bool { library.imported.contains { $0.id == channel.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                    Spacer()
                    if imported { Label("Subscribed on YouTube", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    else {
                        Button {
                            library.toggle(detailed ?? channel, preview: videos)
                        } label: {
                            Label(followed ? "Unfollow on this TV" : "Follow on this TV", systemImage: followed ? "checkmark" : "plus")
                        }
                    }
                }
                RoomHeading(title: detailed?.title ?? channel.title, subtitle: followed ? "Recent uploads" : "Follow this channel to play its uploads.")
                if isLoading { RoomLoading(text: "Loading uploads…") }
                if let error {
                    RoomNotice(message: error)
                    Button("Try again") { revision = UUID() }
                }
                if !isLoading && videos.isEmpty && error == nil {
                    Text("This channel has no recent public uploads.").foregroundStyle(.secondary)
                }
                RoomVideoGrid(videos: videos) { video in
                    if followed { play(video, videos) }
                    else { pendingVideo = video }
                }
                if next != nil && !isLoading && error == nil {
                    Button("More uploads") { revision = UUID() }
                }
            }.padding(16)
        }
        .scrollClipDisabled()
        .toolbar(.hidden, for: .navigationBar)
        .background(RoomPalette.background.ignoresSafeArea())
        .alert("Follow this channel to watch?", isPresented: Binding(
            get: { pendingVideo != nil },
            set: { if !$0 { pendingVideo = nil } }
        ), presenting: pendingVideo) { video in
            Button("Follow and play") {
                if !followed { library.toggle(detailed ?? channel, preview: videos) }
                play(video, videos)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(channel.title) will appear in Home on this Apple TV.")
        }
        .task(id: revision) { await load() }
    }

    @MainActor private func load() async {
        isLoading = true
        error = nil
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            let token = account.isSignedIn ? try await account.accessToken() : nil
            var resolved = detailed ?? channel
            if token != nil && resolved.uploadsID == nil {
                resolved = try await library.api.find(address: .id(channel.id), token: token)
            }
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
