import Foundation
import Observation

@MainActor @Observable
final class ChannelLibrary {
    let api: ChannelCatalog
    private let defaults: UserDefaults
    private static let localKey = "ChannelRoom.LocalFollows.1"
    private(set) var local: [RoomChannel]
    private(set) var profile: RoomChannel?
    private(set) var subscriptionInventory: SubscriptionInventory?
    private(set) var imported: [RoomChannel] = []
    @ObservationIgnored private var uploadsByChannel = [String: [ChannelVideo]]()
    private(set) var channels = [RoomChannel]()
    private(set) var followed = Set<String>()
    private(set) var videos = [ChannelVideo]()
    private(set) var isLoading = true
    private(set) var warning: String?
    private(set) var loadedCount = 0
    private(set) var discoveryTopics = [String]()
    private(set) var discoveries = [ChannelVideo]()
    private(set) var creatorsToExplore = [ChannelVideo]()
    private(set) var topicShelves = [RoomTopicShelf]()
    private(set) var discoveryLoading = false
    private(set) var discoveryFailed = false
    private(set) var videoFacts = [String: RoomVideoFacts]()
    @ObservationIgnored private let discoveryStore: RoomDiscoveryCache
    @ObservationIgnored private var discoveryScope: RoomDiscoveryCache.Scope?
    @ObservationIgnored private var discoverySession: UUID?
    @ObservationIgnored private var discoveryCache = [String: RoomDiscoveryCache.Page]()
    @ObservationIgnored private var discoveryFallback = ""
    private var generation = UUID()

    init(api: ChannelCatalog = ChannelCatalog(), defaults: UserDefaults = .standard,
         discoveryCacheDirectory: URL = URL.cachesDirectory.appending(path: "FreeTube-Discovery-v1")) {
        self.api = api
        self.defaults = defaults
        self.discoveryStore = RoomDiscoveryCache(directory: discoveryCacheDirectory)
        local = defaults.data(forKey: Self.localKey).flatMap { try? JSONDecoder().decode([RoomChannel].self, from: $0) } ?? []
        updateMembership()
    }

    private func updateMembership() {
        var seen = Set<String>()
        channels = (imported + local).filter { seen.insert($0.id).inserted }.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        followed = seen
        if seen.isEmpty {
            discoveryTopics = []; discoveries = []; creatorsToExplore = []; topicShelves = []
        } else {
            discoveries.removeAll { seen.contains($0.channelID) }
            creatorsToExplore.removeAll { seen.contains($0.channelID) }
            topicShelves = topicShelves.compactMap { shelf in
                let remaining = shelf.videos.filter { !seen.contains($0.channelID) }
                return remaining.isEmpty ? nil : RoomTopicShelf(id: shelf.id, videos: remaining)
            }
        }
        uploadsByChannel = uploadsByChannel.filter { seen.contains($0.key) }
        publishVideos()
    }

    private func publishVideos() {
        videos = ChannelVideo.chronological(uploadsByChannel.values.flatMap { $0 }, followed: followed)
    }

    func toggle(_ channel: RoomChannel, preview: [ChannelVideo]) {
        guard !imported.contains(where: { $0.id == channel.id }) else { return }
        if local.contains(where: { $0.id == channel.id }) {
            local.removeAll { $0.id == channel.id }
            uploadsByChannel[channel.id] = nil
        } else {
            local.append(channel)
            uploadsByChannel[channel.id] = preview.filter { $0.channelID == channel.id }
        }
        updateMembership()
        if let data = try? JSONEncoder().encode(local) { defaults.set(data, forKey: Self.localKey) }
    }

    func refresh(account: ChannelAccount) async {
        let run = UUID()
        generation = run
        if discoverySession != account.sessionID {
            discoverySession = account.sessionID
            discoveryScope = nil
            discoveryCache.removeAll()
            discoveryTopics = []; discoveries = []; creatorsToExplore = []; topicShelves = []
            profile = nil; imported = []; subscriptionInventory = nil
            updateMembership()
        }
        isLoading = true
        warning = nil
        loadedCount = 0
        defer { if generation == run { isLoading = false } }
        var problems = [String]()
        var token: String?
        var details = [String: RoomChannel]()
        var restored: RoomDiscoveryCache.Snapshot?
        if !account.isSignedIn { restored = restoreDiscovery(scope: .local) }
        if account.isSignedIn {
            do {
                let bearer = try await account.accessToken()
                token = bearer
                async let inventory = api.subscriptions(token: bearer)
                if profile == nil {
                    let active = try? await api.profile(token: bearer)
                    guard generation == run, !Task.isCancelled else { return }
                    profile = active
                }
                let subs = try await inventory
                guard generation == run, !Task.isCancelled else { return }
                subscriptionInventory = subs
                imported = subs.channels
                if let total = subs.reportedTotal, total > subs.channels.count {
                    problems.append("YouTube returned \(subs.channels.count) of \(total) subscriptions. Refresh Home to sync again.")
                }
                updateMembership()
                restored = restoreDiscovery(scope: RoomDiscoveryCache.Scope(signedIn: true, profileID: profile?.id))
                // channels.list accepts at most 50 IDs per request. Fall back to public uploads feeds
                // for any batch whose playlist details are missing or temporarily inaccessible.
                let ids = channels.map(\.id)
                for first in stride(from: 0, to: ids.count, by: 50) {
                    try Task.checkCancellation()
                    let batch = Array(ids[first..<min(first + 50, ids.count)])
                    let records = try await api.channelDetails(ids: batch, token: bearer)
                    for channel in records { details[channel.id] = channel }
                }
            } catch {
                guard generation == run, !Task.isCancelled else { return }
                problems.append("Google sync: \(error.localizedDescription)")
            }
        }
        guard generation == run, !Task.isCancelled else { return }
        imported = imported.map { details[$0.id] ?? $0 }
        updateMembership()
        let current = channels.map { details[$0.id] ?? $0 }
        async let discovery: Void = loadDiscovery(channels: current, token: token, restored: restored, run: run)
        let api = self.api
        let bearer = token
        var failures = 0
        var lastFailure: String?
        var lastPublication = ContinuousClock.now
        // A sliding window keeps at most six requests in flight even for large libraries.
        await withTaskGroup(of: (String, [ChannelVideo]?, String?).self) { group in
            var remaining = current.makeIterator()
            func enqueue(_ channel: RoomChannel) {
                group.addTask {
                    do {
                        let result = try await api.uploads(channel, token: bearer, count: 15)
                        return (channel.id, result.videos, nil)
                    } catch {
                        return (channel.id, nil, error.localizedDescription)
                    }
                }
            }
            for _ in 0..<6 {
                if let channel = remaining.next() { enqueue(channel) }
            }
            while let (id, videos, failure) = await group.next() {
                guard generation == run, !Task.isCancelled else { group.cancelAll(); break }
                if let videos {
                    if followed.contains(id) { uploadsByChannel[id] = videos }
                } else { failures += 1; lastFailure = failure }
                loadedCount += 1
                if loadedCount == 1 || lastPublication.duration(to: .now) >= .milliseconds(600) {
                    publishVideos()
                    lastPublication = .now
                }
                if let channel = remaining.next() { enqueue(channel) }
            }
        }
        guard generation == run, !Task.isCancelled else { return }
        publishVideos()
        if failures > 0 {
            problems.append("Couldn’t refresh \(failures) of \(current.count) channels. \(lastFailure ?? "")")
        }
        warning = problems.isEmpty ? nil : problems.joined(separator: "\n")
        await discovery
        guard generation == run, !Task.isCancelled else { return }
        if creatorsToExplore.count < 3 && !videos.isEmpty { await loadRelatedUploads(run: run) }
        guard let token, generation == run, !Task.isCancelled else { return }
        let featuredRows = discoveries + creatorsToExplore + Array(videos.prefix(15))
        let ordered = featuredRows + topicShelves.flatMap(\.videos) + Array(videos.dropFirst(15))
        let available = Set(ordered.map(\.id))
        videoFacts = videoFacts.filter { available.contains($0.key) }
        var seen = Set(videoFacts.keys)
        let ids = ordered.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
        // Enrich the visible shelves in one batch, independent of the uploaded-video and search results.
        if !ids.isEmpty, let facts = try? await api.facts(for: Array(ids.prefix(50)), token: token),
           generation == run, !Task.isCancelled {
            videoFacts.merge(facts) { _, updated in updated }
        }
    }

    private func restoreDiscovery(scope: RoomDiscoveryCache.Scope?) -> RoomDiscoveryCache.Snapshot? {
        if discoveryScope != scope {
            discoveryScope = scope
            discoveryCache.removeAll()
            discoveryTopics = []; discoveries = []; creatorsToExplore = []; topicShelves = []
        }
        let now = Date()
        discoveryCache = discoveryCache.filter { $0.value.isFresh(at: now) }
        guard let snapshot = discoveryStore.read(scope, now: now) else { return nil }
        discoveryCache.merge(snapshot.pages) { old, new in old.date >= new.date ? old : new }
        guard !followed.isEmpty, snapshot.membership == RoomDiscoveryCache.membership(of: followed) else { return nil }
        discoveryTopics = snapshot.topics
        publishDiscovery(topics: snapshot.topics, fallback: snapshot.fallback)
        return snapshot
    }

    private func publishDiscovery(topics: [String], fallback: String) {
        guard !followed.isEmpty else { return }
        let pages = discoveryCache.mapValues(\.videos)
        var queries = topics
        if !topics.contains(fallback), needsMoreCreators(topics) { queries.append(fallback) }
        if needsMoreCreators(queries) { queries.append(relatedCacheKey) }
        let rows = RoomDiscovery.recommendations(from: queries.compactMap { pages[$0] }, excluding: followed)
        discoveries = rows.recommended
        creatorsToExplore = rows.explore
        topicShelves = RoomDiscovery.shelves(topics: topics, pages: pages, featured: discoveries + creatorsToExplore, excluding: followed)
    }

    private func needsMoreCreators(_ topics: [String]) -> Bool {
        let pages = topics.compactMap { discoveryCache[$0]?.videos }
        return RoomDiscovery.picks(from: pages, excluding: followed, limit: 6).count < 6
    }

    private var relatedCacheKey: String { "watch-related:" + RoomDiscoveryCache.membership(of: followed) }

    private func loadRelatedUploads(run: UUID) async {
        let key = relatedCacheKey
        guard !discoveryTopics.isEmpty, discoveryCache[key] == nil else { return }
        let seeds = RoomDiscovery.picks(from: [videos], excluding: [], limit: 2).map(\.id)
        let api = self.api
        var pages = [String: [ChannelVideo]]()
        await withTaskGroup(of: (String, [ChannelVideo]?).self) { group in
            for id in seeds { group.addTask { (id, try? await api.related(to: id)) } }
            for await (id, page) in group { pages[id] = page }
        }
        guard generation == run, !Task.isCancelled, relatedCacheKey == key else { return }
        let related = RoomDiscovery.picks(from: seeds.compactMap { pages[$0] }, excluding: followed, limit: 50)
        guard !related.isEmpty else { return }
        discoveryCache[key] = .init(date: Date(), videos: related)
        let snapshot = RoomDiscoveryCache.Snapshot(membership: RoomDiscoveryCache.membership(of: followed),
                                                   topics: discoveryTopics, fallback: discoveryFallback, pages: discoveryCache)
        discoveryStore.write(snapshot, for: discoveryScope)
        discoveryFailed = false
        publishDiscovery(topics: discoveryTopics, fallback: discoveryFallback)
    }

    private func loadDiscovery(channels: [RoomChannel], token: String?, restored: RoomDiscoveryCache.Snapshot?, run: UUID) async {
        guard generation == run, !Task.isCancelled else { return }
        // A failed channel-details request can leave only display names in a confirmed subscription inventory.
        let previous = channels.allSatisfy { ($0.topics ?? []).isEmpty } ? restored : nil
        let topics = previous?.topics ?? RoomDiscovery.interests(in: channels)
        if topics != discoveryTopics { discoveries = []; creatorsToExplore = []; topicShelves = [] }
        discoveryTopics = topics
        discoveryFailed = false
        discoveryLoading = !topics.isEmpty
        defer { if generation == run { discoveryLoading = false } }
        guard let firstTopic = topics.first else { return }
        let fromTopic = channels.contains { $0.topics?.contains(firstTopic) == true }
        let fallback = previous?.fallback ?? (firstTopic + (fromTopic ? " documentary" : " interview"))
        discoveryFallback = fallback
        let now = Date()
        let activeQueries = Set(topics + [fallback, relatedCacheKey])
        discoveryCache = discoveryCache.filter { $0.value.isFresh(at: now) && activeQueries.contains($0.key) }
        let missing = topics.filter { discoveryCache[$0] == nil }
        publishDiscovery(topics: topics, fallback: fallback)
        if restored != nil, discoveryCache[relatedCacheKey] != nil, !creatorsToExplore.isEmpty { return }
        let membership = RoomDiscoveryCache.membership(of: Set(channels.map(\.id)))
        func savePages() {
            let pages = discoveryCache.filter { !$0.value.videos.isEmpty }
            let snapshot = RoomDiscoveryCache.Snapshot(membership: membership, topics: topics, fallback: fallback, pages: pages)
            discoveryStore.write(snapshot, for: discoveryScope)
        }
        let api = self.api
        @Sendable func search(_ query: String, token: String?) async throws -> [ChannelVideo] {
            if let token { return try await api.search(query, token: token, videosOnly: true).videos }
            return try await api.publicSearch(query).videos
        }
        func fetchPages(_ queries: [String], token: String?) async {
            await withTaskGroup(of: (String, [ChannelVideo]?).self) { group in
                for query in queries { group.addTask { (query, try? await search(query, token: token)) } }
                for await (query, videos) in group {
                    guard generation == run, !Task.isCancelled else { group.cancelAll(); return }
                    if let videos {
                        discoveryCache[query] = .init(date: now, videos: videos)
                        if discoveries.isEmpty && !videos.isEmpty {
                            savePages()
                            publishDiscovery(topics: topics, fallback: fallback)
                        }
                    }
                }
            }
        }
        await fetchPages(missing, token: token)
        guard generation == run, !Task.isCancelled else { return }
        let failed = missing.filter { discoveryCache[$0] == nil }
        if token != nil && !failed.isEmpty {
            // Retry at most two failed interests, preserving the query and subscription relevance.
            await fetchPages(Array(failed.prefix(2)), token: nil)
            guard generation == run, !Task.isCancelled else { return }
        }
        discoveryFailed = topics.contains { discoveryCache[$0] == nil }
        if !topics.contains(fallback), needsMoreCreators(topics) {
            // One related search at most. Use public search if the API failed or already served five interests.
            if discoveryCache[fallback] == nil {
                let bearer = !failed.isEmpty || topics.count >= 5 ? nil : token
                let result = try? await search(fallback, token: bearer)
                guard generation == run, !Task.isCancelled else { return }
                if let result { discoveryCache[fallback] = .init(date: now, videos: result) }
                else { discoveryFailed = true }
            }
        }
        if restored == nil || !missing.isEmpty || discoveryCache[fallback]?.date == now { savePages() }
        publishDiscovery(topics: topics, fallback: fallback)
    }
}
