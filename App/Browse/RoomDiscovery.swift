import Foundation
import CryptoKit

struct RoomTopicShelf: Identifiable {
    let id: String
    let videos: [ChannelVideo]
}

struct RoomDiscoveryCache {
    struct Page: Codable {
        let date: Date
        let videos: [ChannelVideo]

        init(date: Date, videos: [ChannelVideo]) {
            self.date = date
            self.videos = Array(videos.prefix(50))
        }

        func isFresh(at now: Date) -> Bool {
            (0..<(6 * 3600)).contains(now.timeIntervalSince(date))
        }
    }

    struct Snapshot: Codable {
        let membership: String
        let topics: [String]
        let fallback: String
        var pages: [String: Page]
    }

    enum Scope: Equatable {
        case local
        case profile(String)

        init?(signedIn: Bool, profileID: String?) {
            if signedIn {
                guard let profileID, ChannelAddress.isID(profileID) else { return nil }
                self = .profile(profileID)
            } else { self = .local }
        }

        fileprivate var filename: String {
            switch self {
            case .local: "local.json"
            case .profile(let id): "profile-" + id + ".json"
            }
        }
    }

    let directory: URL

    static func membership(of followed: Set<String>) -> String {
        let ids = followed.sorted().joined(separator: "\n")
        return Data(SHA256.hash(data: Data(ids.utf8))).base64EncodedString()
    }

    func read(_ scope: Scope?, now: Date) -> Snapshot? {
        guard let scope else { return nil }
        let file = directory.appending(path: scope.filename)
        guard let data = try? Data(contentsOf: file),
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        snapshot.pages = snapshot.pages.filter { $0.value.isFresh(at: now) }
        if snapshot.pages.isEmpty { try? FileManager.default.removeItem(at: file); return nil }
        return snapshot
    }

    func write(_ snapshot: Snapshot, for scope: Scope?) {
        guard let scope, !snapshot.pages.isEmpty, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: scope.filename), options: .atomic)
    }
}

enum RoomDiscovery {
    static func topicName(_ url: String) -> String? {
        guard let path = URL(string: url)?.lastPathComponent.removingPercentEncoding else { return nil }
        let text = path.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "Lifestyle (sociology)" { return "Lifestyle" }
        return text.isEmpty ? nil : text
    }

    static func interests(in channels: [RoomChannel]) -> [String] {
        var owners = [String: Set<String>]()
        for channel in channels {
            for topic in channel.topics ?? [] { owners[topic, default: []].insert(channel.id) }
        }
        let limit = channels.count > 8 ? 5 : 2
        guard !owners.isEmpty else {
            var seen = Set<String>()
            return Array(channels.map(\.title).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit))
        }
        let broad: Set<String> = ["Entertainment", "Knowledge", "Lifestyle", "Society", "Music", "Sport"]
        var chosen = [String]()
        var covered = Set<String>()
        while chosen.count < limit && !owners.isEmpty {
            let ranked = owners.keys.sorted { lhs, rhs in
                let left = owners[lhs, default: []], right = owners[rhs, default: []]
                let leftNew = left.subtracting(covered).count, rightNew = right.subtracting(covered).count
                if (leftNew > 0) != (rightNew > 0) { return leftNew > 0 }
                if broad.contains(lhs) != broad.contains(rhs) { return !broad.contains(lhs) }
                if leftNew != rightNew { return leftNew > rightNew }
                if left.count != right.count { return left.count > right.count }
                return lhs < rhs
            }
            guard let next = ranked.first else { break }
            chosen.append(next)
            covered.formUnion(owners.removeValue(forKey: next) ?? [])
        }
        return chosen
    }

    static func picks(from pages: [[ChannelVideo]], excluding follows: Set<String>, limit: Int = 10) -> [ChannelVideo] {
        var ids = Set<String>()
        var creators = Set<String>()
        var picks = [ChannelVideo]()
        for rank in 0..<(pages.map(\.count).max() ?? 0) {
            for page in pages where rank < page.count {
                let video = page[rank]
                guard !follows.contains(video.channelID), !ids.contains(video.id),
                      creators.insert(video.channelID).inserted else { continue }
                ids.insert(video.id)
                picks.append(video)
                if picks.count == limit { return picks }
            }
        }
        return picks
    }

    static func recommendations(from pages: [[ChannelVideo]], excluding follows: Set<String>)
        -> (recommended: [ChannelVideo], explore: [ChannelVideo]) {
        let ranked = picks(from: pages, excluding: follows, limit: .max)
        // Reserve distinct creators for both shelves even when only two match.
        let firstCount = min(10, (ranked.count + 1) / 2)
        let recommended = Array(ranked.prefix(firstCount))
        // Swift's stable sort preserves search relevance when publication dates are unavailable or equal.
        let recent = ranked.dropFirst(firstCount).sorted { $0.publishedAt > $1.publishedAt }
        return (recommended, Array(recent.prefix(10)))
    }

    static func shelves(topics: [String], pages: [String: [ChannelVideo]], featured: [ChannelVideo],
                        excluding follows: Set<String>) -> [RoomTopicShelf] {
        var shown = Set(featured.map(\.id))
        var shelves = [RoomTopicShelf]()
        for topic in topics {
            let candidates = (pages[topic] ?? []).filter { !shown.contains($0.id) }
            let videos = picks(from: [candidates], excluding: follows)
            guard videos.count >= 3 else { continue }
            shown.formUnion(videos.map(\.id))
            shelves.append(RoomTopicShelf(id: topic, videos: videos))
        }
        return shelves
    }
}
