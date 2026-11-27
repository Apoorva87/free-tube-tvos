import SwiftUI

struct RoomPlaylistsView: View {
    let focus: FocusState<RoomBrowseFocus?>.Binding
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    @Environment(RoomPlaylistStore.self) private var store
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let error = store.loadError {
                    RoomNotice(message: error)
                } else {
                    Button { creating = true } label: { Label("New playlist", systemImage: "plus") }
                        .focused(focus, equals: .newPlaylist)
                        .accessibilityIdentifier("playlist-new")
                    if store.playlists.isEmpty {
                        Text("Create a playlist, then hold Select on a video and choose Add to playlist.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.playlists) { playlist in
                        NavigationLink {
                            RoomPlaylistDetail(id: playlist.id, play: play)
                        } label: {
                            HStack(spacing: 23) {
                                Image(systemName: "list.and.film").frame(width: 65)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.title).font(.headline).lineLimit(1)
                                    Text(playlist.summary).font(.caption)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(8)
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .sheet(isPresented: $creating) { RoomPlaylistDraftView(title: "", videos: []) }
    }
}

private struct RoomPlaylistDetail: View {
    let id: UUID
    let play: (ChannelVideo, [ChannelVideo]) -> Void
    @Environment(RoomPlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editor: RoomPlaylist?
    @State private var confirmingDelete = false
    @State private var issue: String?

    var body: some View {
        if let playlist = store.playlists.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    RoomHeading(title: playlist.title, subtitle: playlist.summary)
                    HStack(spacing: 22) {
                        if let first = playlist.videos.first {
                            Button { play(first, playlist.videos) } label: { Label("Play all", systemImage: "play.fill") }
                        }
                        Button("Edit playlist") { editor = playlist }
                        Button("Delete playlist", role: .destructive) { confirmingDelete = true }
                    }
                    if let issue { RoomNotice(message: issue) }
                    if playlist.videos.isEmpty {
                        Text("Hold Select on a video while browsing and choose Add to playlist.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(playlist.videos.enumerated()), id: \.element.id) { index, video in
                        Button { play(video, playlist.videos) } label: {
                            PlaylistVideoRow(video: video, position: index + 1, seconds: video.durationSeconds)
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar(.hidden, for: .navigationBar)
            .scrollClipDisabled()
            .sheet(item: $editor) { RoomPlaylistDraftView(playlist: $0) }
            .alert("Delete “\(playlist.title)”?", isPresented: $confirmingDelete) {
                Button("Delete playlist", role: .destructive) {
                    do {
                        try store.delete(playlist)
                        dismiss()
                    } catch { issue = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct RoomAddToPlaylistView: View {
    let video: ChannelVideo
    var durationSeconds: Int? = nil
    @Environment(RoomPlaylistStore.self) private var store
    @Environment(\.roomVideoFacts) private var facts
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var issue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RoomHeading(title: "Add to playlist", subtitle: video.title)
                if let error = store.loadError {
                    RoomNotice(message: error)
                } else {
                    if let issue { RoomNotice(message: issue) }
                    if creating || store.playlists.isEmpty {
                        TextField("Playlist name", text: $name)
                        Button("Create playlist and add video") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button { creating = true } label: { Label("New playlist", systemImage: "plus") }
                    }
                    ForEach(store.playlists) { playlist in
                        let saved = playlist.videos.contains { $0.id == video.id }
                        Button {
                            do {
                                try store.add(video, to: playlist.id, seconds: seconds)
                                dismiss()
                            } catch { issue = error.localizedDescription }
                        } label: {
                            Label(playlist.title, systemImage: saved ? "checkmark" : "text.badge.plus")
                        }
                        .disabled(saved)
                        .accessibilityValue(saved ? "Already added" : "")
                    }
                }
                Button("Cancel", role: .cancel) { dismiss() }
            }.padding(48).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var seconds: Int? { durationSeconds ?? RoomVideoFacts.seconds(from: facts[video.id]?.duration) }

    private func create() {
        var playlist = RoomPlaylist(title: name)
        playlist.append(video, seconds: seconds)
        do {
            try store.save(playlist)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

struct RoomPlaylistDraftView: View {
    private enum Mode {
        case create, edit(RoomPlaylist), append(RoomPlaylist)

        var original: RoomPlaylist? {
            switch self {
            case .create: nil
            case .edit(let playlist), .append(let playlist): playlist
            }
        }
    }

    private let mode: Mode
    private let candidates: [ChannelVideo]
    private let durations: [String: Int]
    @Environment(RoomPlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoomPlaylist
    @State private var issue: String?
    @State private var showingSaved = false

    init(title: String, videos: [ChannelVideo], candidates: [ChannelVideo] = [], durations: [String: Int] = [:]) {
        self.init(mode: .create, draft: RoomPlaylist(title: title, videos: videos, durations: durations),
                  candidates: videos + candidates, durations: durations)
    }

    init(appendingTo original: RoomPlaylist, videos: [ChannelVideo], candidates: [ChannelVideo] = [], durations: [String: Int] = [:]) {
        self.init(mode: .append(original), draft: original.appending(videos, durations: durations),
                  candidates: videos + candidates, durations: durations)
    }

    fileprivate init(playlist: RoomPlaylist) {
        self.init(mode: .edit(playlist), draft: playlist, candidates: playlist.videos, durations: playlist.durations)
    }

    private init(mode: Mode, draft: RoomPlaylist, candidates: [ChannelVideo], durations: [String: Int]) {
        self.mode = mode
        var seen = Set<String>()
        self.candidates = candidates.filter { seen.insert($0.id).inserted }
        self.durations = durations
        _draft = State(initialValue: draft)
    }

    private var appendTarget: RoomPlaylist? {
        if case .append(let playlist) = mode { return playlist }
        return nil
    }

    private var heading: String {
        switch mode {
        case .create: candidates.isEmpty ? "New playlist" : "Review playlist"
        case .edit: "Edit playlist"
        case .append(let playlist): "Add to “\(playlist.title)”"
        }
    }

    var body: some View {
        let selected = Set(draft.videos.map(\.id))
        let remaining = candidates.filter { !selected.contains($0.id) }
        let savedCount = appendTarget?.videos.count ?? 0
        let editable = draft.videos.dropFirst(savedCount)
        let needsAdditions = appendTarget != nil && editable.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RoomHeading(title: heading, subtitle: appendTarget == nil ? draft.summary : "After saving · " + draft.summary)
                if let target = appendTarget {
                    if !target.videos.isEmpty {
                        Button {
                            showingSaved.toggle()
                        } label: {
                            Label("Already in playlist (\(savedCount))", systemImage: showingSaved ? "chevron.up" : "chevron.down")
                        }
                        if showingSaved {
                            ForEach(Array(target.videos.enumerated()), id: \.element.id) { index, video in
                                PlaylistVideoRow(video: video, position: index + 1, seconds: video.durationSeconds)
                                    .focusable()
                            }
                        }
                    }
                } else {
                    TextField("Playlist name", text: $draft.title)
                        .accessibilityIdentifier("playlist-name")
                }
                if let issue = store.loadError ?? issue { RoomNotice(message: issue) }
                HStack(spacing: 22) {
                    Button(appendTarget == nil ? "Save playlist" : "Add selected videos") {
                        do {
                            try store.save(draft, replacing: mode.original)
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }
                    .disabled(store.loadError != nil || needsAdditions || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("playlist-save")
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if !editable.isEmpty {
                    RoomShelfTitle(title: appendTarget == nil ? "Play order" : "Proposed additions")
                } else if needsAdditions {
                    Text(remaining.isEmpty ? "There are no new videos to add." : "Choose a video below to add to this playlist.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(editable.enumerated()), id: \.element.id) { index, video in
                    HStack(spacing: 16) {
                        PlaylistVideoRow(video: video, position: savedCount + index + 1, seconds: video.durationSeconds)
                        Button { draft.move(video, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).accessibilityLabel("Move \(video.title) up")
                        Button { draft.move(video, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == editable.count - 1).accessibilityLabel("Move \(video.title) down")
                        Button { draft.remove(video) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove \(video.title)")
                    }
                }
                if !remaining.isEmpty {
                    RoomShelfTitle(title: "Available videos")
                    ForEach(remaining) { video in
                        Button {
                            draft.append(video, seconds: durations[video.id])
                        } label: {
                            HStack {
                                Image(systemName: "plus")
                                PlaylistVideoRow(video: video, seconds: durations[video.id] ?? video.durationSeconds)
                            }
                        }
                        .accessibilityLabel("Add \(video.title)")
                    }
                }
            }.padding(48).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PlaylistVideoRow: View {
    let video: ChannelVideo
    var position: Int?
    let seconds: Int?

    var body: some View {
        HStack(spacing: 18) {
            if let position { Text("\(position)").font(.headline.monospacedDigit()).frame(minWidth: 42) }
            VStack(alignment: .leading, spacing: 5) {
                Text(video.title).font(.headline).lineLimit(2)
                Text(video.channelTitle).font(.caption).lineLimit(1)
            }
            Spacer()
            if let seconds { Text(RoomPlaylist.clock(seconds)).font(.caption.monospacedDigit()) }
        }
        .padding(.vertical, 8)
        .multilineTextAlignment(.leading)
    }
}
