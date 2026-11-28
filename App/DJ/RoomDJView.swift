import AVFoundation
import SwiftUI

extension EnvironmentValues {
    @Entry var removeFromDJQueue: (@MainActor (ChannelVideo) -> Void)? = nil
}

struct RoomDJView: View {
    @Environment(RoomViewingSession.self) private var viewing
    let history: [ChannelVideo]
    let preferences: RoomDiscoverPreferences
    let music: RoomMusicFeed
    let interestFeed: RoomInterestFeed
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let openMenu: () -> Void

    @State private var query = ""
    @State private var pick: ChannelVideo?
    @State private var removedPosition: Int?
    @State private var restoringFromContextMenu = false
    @State private var selectingMode = false
    @State private var selectingLanguage = false
    @State private var handoffFailed = false
    @State private var transportStatus = AVPlayer.TimeControlStatus.paused

    private var station: RoomDJStation { viewing.djStation }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var languageLabel: String { station.effectiveLanguage ?? "English + Hindi" }

    private var musicInterests: [RoomInterestRow] {
        preferences.rows.filter { row in
            row.enabled && !row.query.isEmpty &&
                (row.isCustom || RoomDJCatalog.topic(for: row.title) != nil || RoomDJCatalog.topic(for: row.query) != nil)
        }
    }

    private var musicHistory: [ChannelVideo] {
        var seen = Set<String>()
        return (station.likedSongs + history).filter { video in
            station.feedback(for: video) != .dislike && seen.insert(video.id).inserted
        }
    }

    private var recommendations: [RoomDiscoverShelf] {
        let ids = Set(musicInterests.map(\.id))
        let interests = interestFeed.shelves.filter { ids.contains($0.id) }.map { row in
            RoomDiscoverShelf(id: row.id, title: row.title, videos: row.videos.filter(RoomDJCatalog.hasMusicMetadata))
        }
        let recent = history.filter(RoomDJCatalog.hasMusicMetadata)
        let rows = music.shelves(history: musicHistory, publicRows: interests) + [
            RoomDiscoverShelf(id: "liked", title: "Songs you liked", videos: station.likedSongs),
            RoomDiscoverShelf(id: "recent", title: "Recently played songs", videos: recent)
        ]
        var seen = Set(station.upcoming.map(\.id))
        if station.isActive, let playing = viewing.video { seen.insert(playing.id) }
        return rows.compactMap { row in
            let songs = row.videos.filter { RoomDJCatalog.songSized($0) && station.feedback(for: $0) != .dislike && seen.insert($0.id).inserted }
            return songs.isEmpty ? nil : RoomDiscoverShelf(id: row.id, title: row.title, videos: Array(songs.prefix(10)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            requestBar
            stationControls
            if station.isLoading { RoomLoading(text: "Finding songs…").accessibilityIdentifier("dj-loading") }
            if let message = station.message {
                HStack(spacing: 16) {
                    Text(message).font(.system(size: 23)).foregroundStyle(RoomPalette.muted)
                        .accessibilityIdentifier(station.retryAfter != nil && station.isActive && playbackFailed ? "dj-playback-error" : "dj-message")
                    if let deadline = station.retryAfter {
                        TimelineView(.explicit([Date.distantPast, deadline])) { tick in
                            Button("Retry") { station.retry() }
                                .buttonStyle(RoomToolbarStyle()).disabled(tick.date < deadline)
                                .accessibilityIdentifier("dj-retry")
                        }
                    } else if station.canRetryRefill {
                        Button("Retry songs") { station.retry() }
                            .buttonStyle(RoomToolbarStyle())
                            .accessibilityIdentifier("dj-retry-refill")
                    }
                }
                if let song = station.songAwaitingRetry {
                    HStack(spacing: 16) {
                        Text(song.title).font(.headline).lineLimit(1)
                        youtubeButton(for: song)
                    }
                    .buttonStyle(RoomToolbarStyle())
                }
            }
            if handoffFailed {
                Text("YouTube didn’t open. Check that the YouTube app is installed on this Apple TV.")
                    .font(.system(size: 23)).foregroundStyle(RoomPalette.muted)
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 25) {
                    if !station.choices.isEmpty {
                        shelf("Choose a song", id: "choices", songs: station.choices) { video in
                            if station.isActive { pick = video }
                            else { station.choose(video) }
                        }
                    }
                    if station.isActive, let current = viewing.video {
                        playing(current)
                        if !station.upcoming.isEmpty {
                            shelf("Up next", id: "upcoming", songs: station.upcoming) { pick = $0 }
                        }
                    }
                    let rows = recommendations
                    if rows.isEmpty && !station.isActive && station.choices.isEmpty { starters }
                    ForEach(rows) { row in
                        shelf(row.title, id: row.id, songs: row.videos) { video in
                            if station.isActive { pick = video }
                            else { station.playNow(video) }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Leave the player and remote controls their own column while browsing songs.
            .padding(.trailing, viewing.presentation == .mini ? ChannelPlayerView.miniVideoWidth + 30 : 0)
        }
        // Discover owns the network refresh for these shelves. Listening and voting update the display locally.
        .onDisappear { if station.isSearching { station.cancelChoices() } }
        .onChange(of: viewing.video?.id) { handoffFailed = false }
        .onReceive(viewing.playback.player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)) {
            transportStatus = $0
        }
        .sheet(item: $pick, onDismiss: restoreQueueFocus) { video in songActions(video) }
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { update in
            // The tile hosting the context menu is gone. Restore focus once tvOS has
            // returned it to the app, after the menu's own dismissal animation.
            if restoringFromContextMenu, (update.object as? UIFocusSystem)?.focusedItem != nil {
                restoreQueueFocus()
            }
        }
        .sheet(isPresented: $selectingLanguage) {
            VStack(alignment: .leading, spacing: 22) {
                RoomShelfTitle(title: "Song language")
                languageChoice(nil)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                          alignment: .leading, spacing: 14) {
                    ForEach(RoomDJCatalog.supportedLanguages, id: \.self) { language in languageChoice(language) }
                }
            }
            .buttonStyle(RoomToolbarStyle())
            .padding(46).frame(width: 1160)
        }
    }

    private var requestBar: some View {
        HStack(spacing: 18) {
            TextField("Search for a song, artist or style", text: $query)
                .focused(focus, equals: .djSearch)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.search).onSubmit(submit)
                .accessibilityIdentifier("dj-query")
            Button(station.isActive ? "Steer queue" : "Start station", action: submit)
                .disabled(trimmed.isEmpty)
                .accessibilityIdentifier("dj-submit")
        }
        .focusSection().padding(.horizontal, 7)
    }

    private var stationControls: some View {
        HStack(spacing: 18) {
            Button { selectingMode = true } label: {
                Label(station.mode.rawValue, systemImage: station.mode == .flow ? "waveform" : "shuffle")
            }
            .accessibilityLabel("Station mode, " + station.mode.rawValue)
            .accessibilityIdentifier("dj-mode")
            .confirmationDialog("Station mode", isPresented: $selectingMode) {
                ForEach(RoomDJMode.allCases, id: \.self) { mode in
                    Button(mode.rawValue) { station.setMode(mode) }
                }
            }
            Button { selectingLanguage = true } label: {
                Label(languageLabel, systemImage: "globe")
            }
            .accessibilityLabel("Song language, " + languageLabel)
            .accessibilityIdentifier("dj-language")
            if station.isActive, !station.direction.isEmpty {
                Text(station.direction).font(.system(size: 23, weight: .medium))
                    .foregroundStyle(RoomPalette.muted).lineLimit(1)
                    .accessibilityIdentifier("dj-direction")
            }
        }
        .buttonStyle(RoomToolbarStyle()).focusSection().padding(.horizontal, 7)
    }

    private func playing(_ video: ChannelVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoomShelfTitle(title: playbackStatus)
                .accessibilityIdentifier("dj-playing-state")
            Text(video.title).font(.system(size: 34, weight: .semibold)).lineLimit(2)
                .accessibilityIdentifier("dj-now-" + video.id)
            Text(video.channelTitle).font(.system(size: 23)).foregroundStyle(RoomPalette.muted)
            if case .failed(let reason) = viewing.playback.phase, station.retryAfter == nil {
                Text(reason)
                    .font(.system(size: 23)).foregroundStyle(RoomPalette.muted).lineLimit(2)
                    .accessibilityIdentifier("dj-playback-error")
            }
            HStack(spacing: 14) {
                if case .failed = viewing.playback.phase, station.retryAfter == nil {
                    Button("Retry") { viewing.load() }.accessibilityIdentifier("dj-retry")
                }
                if station.retryAfter != nil || playbackFailed {
                    youtubeButton(for: video)
                }
                feedbackButtons(for: video)
                Button { viewing.advance() } label: { Label("Skip", systemImage: "forward.end") }
                    .accessibilityIdentifier("dj-skip").disabled(viewing.next == nil || station.retryAfter != nil)
            }
            .buttonStyle(RoomToolbarStyle()).focusSection()
        }
    }

    @ViewBuilder
    private func feedbackButtons(for video: ChannelVideo) -> some View {
        let vote = station.feedback(for: video)
        Button { station.like(video) } label: {
            Label("Like", systemImage: vote == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
        }
        .accessibilityAddTraits(vote == .like ? .isSelected : [])
        .accessibilityIdentifier("dj-like")
        Button { station.dislike(video) } label: {
            Label("Dislike", systemImage: vote == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        }
        .accessibilityAddTraits(vote == .dislike ? .isSelected : [])
        .accessibilityIdentifier("dj-dislike")
    }

    private func youtubeButton(for video: ChannelVideo) -> some View {
        Button("Open in YouTube") {
            Task {
                if await ChannelPlayerView.openYouTube(video) { viewing.close() }
                else { handoffFailed = true }
            }
        }
        .accessibilityIdentifier("dj-open-youtube")
    }

    private var playbackFailed: Bool {
        if case .failed = viewing.playback.phase { return true }
        return false
    }

    private var playbackStatus: String {
        switch viewing.playback.phase {
        case .loading: "Starting song…"
        case .playing:
            switch transportStatus {
            case .paused: "Paused"
            case .waitingToPlayAtSpecifiedRate: "Buffering…"
            case .playing: "Now playing"
            @unknown default: "Starting song…"
            }
        case .failed: "Playback unavailable"
        case .finished: "Song finished"
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 15) {
            RoomShelfTitle(title: "Try a station")
            HStack(spacing: 18) {
                ForEach(["Marathi dance songs", "Bollywood hits", "Acoustic pop"], id: \.self) { prompt in
                    Button(prompt) { station.submit(prompt) }
                }
            }
            .buttonStyle(RoomToolbarStyle()).focusSection()
        }
    }

    private func shelf(_ title: String, id: String, songs: [ChannelVideo],
                       select: @escaping (ChannelVideo) -> Void) -> some View {
        let remove: (@MainActor (ChannelVideo) -> Void)? = id == "upcoming" ? removeQueuedSong : nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
                RoomShelfTitle(title: title)
                if id == "upcoming", let requested = station.requestedNext {
                    Button("Play Now") {
                        if viewing.next?.id == requested.id { viewing.advance() }
                        else { station.playNow(requested) }
                    }
                    .buttonStyle(RoomToolbarStyle())
                    .accessibilityHint(requested.title)
                    .accessibilityIdentifier("dj-play-request")
                }
            }
            RoomVideoShelf(videos: songs, focus: focus, discoveryShelfID: "dj-" + id,
                           columns: viewing.presentation == .mini ? 3 : 5, openMenu: openMenu, action: select)
                .environment(\.removeFromDJQueue, remove)
        }
    }

    private func songActions(_ video: ChannelVideo) -> some View {
        let isQueued = station.upcoming.contains { $0.id == video.id }
        return VStack(alignment: .leading, spacing: 22) {
            RoomShelfTitle(title: video.title)
            Text(video.channelTitle).font(.headline).foregroundStyle(RoomPalette.muted)
            if !isQueued && !station.upcoming.isEmpty {
                Text("Current queue").font(.headline).foregroundStyle(RoomPalette.muted)
                ForEach(station.upcoming.prefix(2)) { song in
                    Label(song.title, systemImage: "music.note").font(.system(size: 22)).lineLimit(1)
                }
            }
            Button("Play Now") {
                pick = nil
                station.playNow(video)
            }
            .accessibilityIdentifier("dj-play-now")
            if isQueued {
                Button {
                    removeQueuedSong(video)
                } label: { Label("Remove from Up Next", systemImage: "minus.circle") }
                .accessibilityIdentifier("dj-remove-upcoming")
            }
            Button("Queue after current song") {
                pick = nil
                if station.choices.contains(where: { $0.id == video.id }) { station.choose(video) }
                else { station.steer(toward: video) }
            }
            .accessibilityIdentifier("dj-steer")
            HStack(spacing: 14) { feedbackButtons(for: video) }
                .buttonStyle(RoomToolbarStyle())
            Button("Done") { pick = nil }
        }
        .frame(maxWidth: 920, alignment: .leading).padding(46)
    }

    private func removeQueuedSong(_ video: ChannelVideo) {
        guard let index = station.upcoming.firstIndex(where: { $0.id == video.id }) else { return }
        removedPosition = index
        restoringFromContextMenu = pick == nil
        station.removeUpcoming(video)
        if pick != nil { pick = nil }
    }

    private func restoreQueueFocus() {
        guard let position = removedPosition else { return }
        removedPosition = nil
        restoringFromContextMenu = false
        Task { @MainActor in
            await Task.yield()
            let songs = station.upcoming
            focus.wrappedValue = songs.isEmpty ? .djSearch : .video(songs[min(position, songs.count - 1)].id, in: "dj-upcoming")
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        station.submit(trimmed)
        query = ""
    }

    private func languageChoice(_ language: String?) -> some View {
        let selected = station.language == language
        return Button {
            station.setLanguage(language)
            selectingLanguage = false
        } label: {
            HStack {
                Text(language ?? "Automatic · Follow the seed")
                if selected { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
