import Foundation
import CryptoKit

struct RoomDiscoverShelf: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let videos: [ChannelVideo]
}

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

    struct Related: Codable {
        var likedIDs: [String] = []
        var likesUpdated: Date?
        var pages = [String: Page]()

        mutating func expire(at now: Date) {
            pages = pages.filter { $0.value.isFresh(at: now) }
            if let likesUpdated, !(0..<(6 * 3600)).contains(now.timeIntervalSince(likesUpdated)) {
                likedIDs = []
                self.likesUpdated = nil
            }
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

    func readRelated(_ scope: Scope?, now: Date) -> Related {
        guard let scope, let data = try? Data(contentsOf: directory.appending(path: "related-" + scope.filename)),
              var result = try? JSONDecoder().decode(Related.self, from: data) else { return Related() }
        result.expire(at: now)
        return result
    }

    func writeRelated(_ related: Related, for scope: Scope?) {
        guard let scope, let data = try? JSONEncoder().encode(related) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "related-" + scope.filename), options: .atomic)
    }

    func write(_ snapshot: Snapshot, for scope: Scope?) {
        guard let scope, !snapshot.pages.isEmpty, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: scope.filename), options: .atomic)
    }
}

enum RoomDiscovery {
    // The shared uploads feed is already deduplicated and sorted by publication date.
    static func channelShelves(chronological uploads: [ChannelVideo], channels: [RoomChannel]) -> [RoomDiscoverShelf] {
        let byChannel = Dictionary(grouping: uploads, by: \.channelID)
        return channels.compactMap { channel -> RoomDiscoverShelf? in
            guard let videos = byChannel[channel.id] else { return nil }
            return RoomDiscoverShelf(id: "channel-" + channel.id, title: channel.title, videos: Array(videos.prefix(10)))
        }.sorted {
            let lhs = $0.videos[0].publishedAt, rhs = $1.videos[0].publishedAt
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    static func discoverShelves(channelShelves: [RoomDiscoverShelf], related: RoomDiscoveryCache.Related,
                               follows: Set<String>, watched: Set<String>, topicPicks: [ChannelVideo],
                               creatorPicks: [ChannelVideo]) -> [RoomDiscoverShelf] {
        var shown = watched.union(related.likedIDs)
        for row in channelShelves { shown.formUnion(row.videos.map(\.id)) }

        func collect(_ pages: [[ChannelVideo]]) -> [ChannelVideo] {
            var videos = [ChannelVideo]()
            for rank in 0..<(pages.map(\.count).max() ?? 0) {
                for page in pages where rank < page.count {
                    let video = page[rank]
                    guard !follows.contains(video.channelID), shown.insert(video.id).inserted else { continue }
                    videos.append(video)
                    if videos.count == 20 { return videos }
                }
            }
            return videos
        }

        let likedPages = related.likedIDs.prefix(5).compactMap { related.pages[$0]?.videos }
        let uploadPages = channelShelves.prefix(6).compactMap { $0.videos.first }.compactMap { related.pages[$0.id]?.videos }
        var forYou = collect(likedPages)
        var fromSubscriptions = collect(uploadPages)
        // Reserve the seed-based recommendations before filling a missing shelf from topic searches.
        if forYou.isEmpty { forYou = collect([topicPicks]) }
        if fromSubscriptions.isEmpty { fromSubscriptions = collect([creatorPicks]) }
        if forYou.isEmpty, fromSubscriptions.count > 1 {
            let split = (fromSubscriptions.count + 1) / 2
            forYou = Array(fromSubscriptions.prefix(split))
            fromSubscriptions.removeFirst(split)
        }
        if fromSubscriptions.isEmpty, forYou.count > 1 {
            // A recent like can also be the newest upload. Keep both perspectives when their pages overlap.
            let eligible = Set((uploadPages.flatMap { $0 } + creatorPicks).map(\.id))
            fromSubscriptions = Array(forYou.filter { eligible.contains($0.id) }.suffix(forYou.count / 2))
            let moved = Set(fromSubscriptions.map(\.id))
            forYou.removeAll { moved.contains($0.id) }
        }
        var shelves = [RoomDiscoverShelf]()
        if !forYou.isEmpty {
            shelves.append(RoomDiscoverShelf(id: "for-you", title: "Recommended for you", videos: forYou))
        }
        if !fromSubscriptions.isEmpty {
            shelves.append(RoomDiscoverShelf(id: "from-subscriptions", title: "More like your subscriptions", videos: fromSubscriptions))
        }
        return shelves + channelShelves
    }

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
