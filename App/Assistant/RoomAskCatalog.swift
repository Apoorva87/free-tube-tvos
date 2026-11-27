import Foundation

struct RoomAskMatches {
    let videos: [ChannelVideo]
    let durations: [String: Int]

    // Interleave results so a prolific first search cannot crowd out the other topics.
    static func combined(_ pages: [Self], excluding: Set<String>, limit: Int = 50) -> Self {
        var durations = [String: Int]()
        var videos: [ChannelVideo] = []
        var seen = excluding
        for index in 0..<(pages.map { $0.videos.count }.max() ?? 0) {
            for page in pages where page.videos.indices.contains(index) {
                let video = page.videos[index]
                if videos.count < limit && seen.insert(video.id).inserted { videos.append(video) }
                if let duration = page.durations[video.id] { durations[video.id] = duration }
            }
        }
        return Self(videos: videos, durations: durations.filter { seen.contains($0.key) && !excluding.contains($0.key) })
    }

    var candidates: [AICandidate] {
        videos.map { AICandidate(id: $0.id, title: RoomAIValidation.clipped($0.title, bytes: 512),
                                 channel: RoomAIValidation.clipped($0.channelTitle, bytes: 256),
                                 durationSeconds: durations[$0.id]) }
    }
}

@MainActor
enum RoomAskCatalog {
    static func search(_ terms: [String], account: ChannelAccount, excluding: Set<String>) async throws -> RoomAskMatches {
        var pages = [RoomAskMatches]()
        var lastError: Error = RoomAIError.noSearchResults
        for term in terms {
            try Task.checkCancellation()
            do { pages.append(try await search(term, account: account)) }
            catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        guard !pages.isEmpty else { throw lastError }
        return RoomAskMatches.combined(pages, excluding: excluding)
    }

    static func search(_ term: String, account: ChannelAccount, relatedTo current: ChannelVideo? = nil) async throws -> RoomAskMatches {
        let api = ChannelCatalog()
        let bearer = account.isSignedIn ? try? await account.accessToken() : nil
        let page: CatalogPage
        if let bearer, let found = try? await api.search(term, token: bearer, videosOnly: true), !found.videos.isEmpty {
            page = found
        } else {
            try Task.checkCancellation()
            do { page = try await api.publicSearch(term) }
            catch {
                try Task.checkCancellation()
                guard let current else { throw error }
                page = CatalogPage(videos: try await api.related(to: current.id))
            }
        }
        try Task.checkCancellation()
        var seen = Set<String>()
        var videos = page.videos.filter { video in
            RoomAIValidation.validID(video.id) && ChannelAddress.isID(video.channelID) && video.id != current?.id && seen.insert(video.id).inserted
        }
        if videos.isEmpty, let current {
            videos = try await api.related(to: current.id).filter {
                RoomAIValidation.validID($0.id) && ChannelAddress.isID($0.channelID) && $0.id != current.id && seen.insert($0.id).inserted
            }
        }
        let shortlist = Array(videos.prefix(35))
        guard !shortlist.isEmpty else { throw RoomAIError.noSearchResults }
        var durations = [String: Int]()
        for video in shortlist { durations[video.id] = video.durationSeconds }
        if let bearer, let facts = try? await api.facts(for: shortlist.map(\.id), token: bearer) {
            for (id, fact) in facts {
                if let seconds = RoomAIValidation.seconds(fact.duration), !fact.live { durations[id] = seconds }
                else if fact.live { durations.removeValue(forKey: id) }
            }
        }
        try Task.checkCancellation()
        return RoomAskMatches(videos: shortlist, durations: durations)
    }
}
