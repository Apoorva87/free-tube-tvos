import Foundation
import Observation

@MainActor @Observable
final class RoomWatchHistoryStore {
    typealias Scope = RoomDiscoveryCache.Scope

    private struct Entry: Codable {
        let owner: String
        let video: ChannelVideo
    }

    private let defaults: UserDefaults
    private var scope: Scope?
    private(set) var videos: [ChannelVideo] = []
    private(set) var issue: String?

    private static let archiveKey = "room.watch-history.v1"
    // tvOS limits the entire app's defaults domain. Bound the archive across all profiles.
    private static let byteLimit = 128 * 1024
    private static let entryLimit = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func select(_ newScope: Scope?) {
        guard newScope != scope else { return }
        // The shell owns one store per sign-in session. While a signed-in profile is
        // resolving, buffer its watches in memory and merge them only into that profile.
        let buffered: [ChannelVideo]
        if scope == nil, case .profile = newScope { buffered = videos }
        else { buffered = [] }
        scope = newScope
        videos = []
        issue = nil
        if let newScope { update(newScope, with: buffered) }
    }

    func record(_ video: ChannelVideo) {
        if let scope {
            update(scope, with: [video])
        } else {
            videos.removeAll { $0.id == video.id }
            videos.insert(video, at: 0)
            videos = Array(videos.prefix(Self.entryLimit))
        }
    }

    private func update(_ scope: Scope, with watched: [ChannelVideo]) {
        let owner: String = switch scope {
        case .local: "guest"
        case .profile(let id): id
        }
        do {
            // Reread before writing so another store's recent watches survive a replay.
            var entries: [Entry] = []
            if let stored = defaults.object(forKey: Self.archiveKey) {
                guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
                entries = try PropertyListDecoder().decode([Entry].self, from: data)
            }
            if !watched.isEmpty {
                let ids = Set(watched.map(\.id))
                entries.removeAll { $0.owner == owner && ids.contains($0.video.id) }
                entries.insert(contentsOf: watched.map { Entry(owner: owner, video: $0) }, at: 0)
                entries = Array(entries.prefix(Self.entryLimit))

                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                var data = try encoder.encode(entries)
                while data.count > Self.byteLimit {
                    guard entries.count > 1 else { throw CocoaError(.fileWriteOutOfSpace) }
                    let retained = max(1, entries.count * Self.byteLimit / data.count)
                    entries.removeLast(entries.count - retained)
                    data = try encoder.encode(entries)
                }
                defaults.set(data, forKey: Self.archiveKey)
            }
            videos = entries.compactMap { $0.owner == owner ? $0.video : nil }
            issue = nil
        } catch {
            issue = "Free Tube couldn’t access watch history on this Apple TV."
        }
    }
}
