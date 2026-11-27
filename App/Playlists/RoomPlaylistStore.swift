import Foundation
import Observation

struct RoomPlaylist: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    private(set) var videos: [ChannelVideo]
    var durations: [String: Int] {
        videos.reduce(into: [:]) { result, video in
            if let seconds = video.durationSeconds, (1...604_800).contains(seconds) { result[video.id] = seconds }
        }
    }

    init(id: UUID = UUID(), title: String, videos: [ChannelVideo] = [], durations: [String: Int] = [:]) {
        self.id = id
        self.title = title
        self.videos = []
        for video in videos { append(video, seconds: durations[video.id]) }
    }

    mutating func append(_ video: ChannelVideo, seconds: Int? = nil) {
        guard !videos.contains(where: { $0.id == video.id }) else { return }
        var item = video
        if let duration = seconds ?? video.durationSeconds, (1...604_800).contains(duration) {
            item.durationSeconds = duration
        } else {
            item.durationSeconds = nil
        }
        videos.append(item)
    }

    func appending(_ additions: [ChannelVideo], durations: [String: Int] = [:]) -> RoomPlaylist {
        var draft = self
        for video in additions { draft.append(video, seconds: durations[video.id]) }
        return draft
    }

    mutating func remove(_ video: ChannelVideo) {
        videos.removeAll { $0.id == video.id }
    }

    mutating func move(_ video: ChannelVideo, by offset: Int) {
        guard [-1, 1].contains(offset), let index = videos.firstIndex(where: { $0.id == video.id }),
              videos.indices.contains(index + offset) else { return }
        videos.swapAt(index, index + offset)
    }

    var summary: String {
        let count = videos.count
        let videoCount = count == 1 ? "1 video" : "\(count) videos"
        guard count > 0 else { return videoCount }
        let durations = self.durations
        guard !durations.isEmpty else { return "\(videoCount) · duration unknown" }
        let total = Self.clock(durations.values.reduce(0, +))
        let unknown = count - durations.count
        if unknown == 0 { return "\(videoCount) · \(total) total" }
        return "\(videoCount) · \(total) known · \(unknown) without a duration"
    }

    static func clock(_ seconds: Int) -> String {
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

extension RoomVideoFacts {
    static func seconds(from clock: String?) -> Int? {
        guard let clock else { return nil }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard (1...3).contains(part.count), part.allSatisfy(\.isNumber), let value = Int(part),
                  index == 0 || value < 60 else { return nil }
            total = total * 60 + value
        }
        return (1...604_800).contains(total) ? total : nil
    }
}

enum RoomPlaylistError: LocalizedError {
    case unreadable, missingTitle, longTitle, tooManyPlaylists, tooManyVideos, tooLarge, changed

    var errorDescription: String? {
        switch self {
        case .unreadable: "Free Tube couldn’t read the saved playlists on this TV. Your saved data has been kept."
        case .missingTitle: "Enter a playlist name."
        case .longTitle: "Use a playlist name with 100 characters or fewer."
        case .tooManyPlaylists: "This TV has reached its limit of 40 playlists. Delete a playlist to create another."
        case .tooManyVideos: "A playlist can hold up to 100 videos."
        case .tooLarge: "Playlist storage on this TV is full. Remove some videos before saving."
        case .changed: "This playlist changed while you were editing. Reopen it to edit the latest version."
        }
    }
}

@MainActor @Observable
final class RoomPlaylistStore {
    static let storageKey = "room.playlists.v1"
    private struct Archive: Codable {
        let version: Int
        let playlists: [RoomPlaylist]
    }
    private let defaults: UserDefaults
    @ObservationIgnored private var archiveData: Data?
    private(set) var playlists: [RoomPlaylist] = []
    private(set) var loadError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do { try readLatest() } catch { loadError = error.localizedDescription }
    }

    private func readLatest() throws {
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            if archiveData != nil || loadError != nil {
                playlists = []
                archiveData = nil
                loadError = nil
            }
            return
        }
        if let data = stored as? Data, data == archiveData, loadError == nil { return }
        guard let data = stored as? Data,
              let archive = try? PropertyListDecoder().decode(Archive.self, from: data), archive.version == 1 else {
            loadError = RoomPlaylistError.unreadable.localizedDescription
            throw RoomPlaylistError.unreadable
        }
        playlists = archive.playlists
        archiveData = data
        loadError = nil
    }

    // Preserve edits to other lists and detect stale edits to this list.
    func save(_ draft: RoomPlaylist, replacing original: RoomPlaylist? = nil) throws {
        try readLatest()
        var proposed = draft
        proposed.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.title.isEmpty else { throw RoomPlaylistError.missingTitle }
        guard proposed.title.count <= 100 else { throw RoomPlaylistError.longTitle }
        guard proposed.videos.count <= 100 else { throw RoomPlaylistError.tooManyVideos }

        var result = playlists
        if let original {
            guard draft.id == original.id, let index = result.firstIndex(of: original) else { throw RoomPlaylistError.changed }
            result[index] = proposed
        } else {
            guard result.count < 40 else { throw RoomPlaylistError.tooManyPlaylists }
            guard !result.contains(where: { $0.id == draft.id }) else { throw RoomPlaylistError.changed }
            result.append(proposed)
        }
        try persist(result)
    }

    func add(_ video: ChannelVideo, to id: UUID, seconds: Int? = nil) throws {
        try readLatest()
        guard let original = playlists.first(where: { $0.id == id }) else { throw RoomPlaylistError.changed }
        var updated = original
        updated.append(video, seconds: seconds)
        if updated != original { try save(updated, replacing: original) }
    }

    func delete(_ original: RoomPlaylist) throws {
        try readLatest()
        guard playlists.contains(original) else { throw RoomPlaylistError.changed }
        try persist(playlists.filter { $0.id != original.id })
    }

    private func persist(_ result: [RoomPlaylist]) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Archive(version: 1, playlists: result))
        // Keep the playlist contribution well below the tvOS user-defaults size warning.
        guard data.count <= 240 * 1024 else { throw RoomPlaylistError.tooLarge }
        defaults.set(data, forKey: Self.storageKey)
        archiveData = data
        playlists = result
    }
}
