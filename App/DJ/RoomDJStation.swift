import Foundation
import Observation

enum RoomDJMode: String, CaseIterable, Sendable {
    case flow = "Flow"
    case popularShuffle = "Popular Shuffle"
}

enum RoomDJFeedback: String, Codable, Sendable {
    case like, dislike
}

protocol RoomDJSource: Sendable {
    func detectedLanguage(for video: ChannelVideo) -> String?
    func search(_ query: String) async throws -> [ChannelVideo]
    func station(seed: ChannelVideo, language: String?, mode: RoomDJMode, excluding: Set<String>,
                 liked: [ChannelVideo], disliked: [ChannelVideo], topic: String?) async throws -> [ChannelVideo]
    func rank(_ videos: [ChannelVideo], seed: ChannelVideo, language: String?, mode: RoomDJMode,
              excluding: Set<String>, liked: [ChannelVideo], disliked: [ChannelVideo], topic: String?) -> [ChannelVideo]
}

extension RoomDJSource {
    func detectedLanguage(for video: ChannelVideo) -> String? { RoomDJCatalog.inferredLanguage(for: video) }
}

extension RoomDJCatalog: RoomDJSource {}

@MainActor @Observable
final class RoomDJStation {
    private struct Vote: Codable {
        let owner: String
        let video: ChannelVideo
        let feedback: RoomDJFeedback
    }

    private struct FeedbackArchive: Codable {
        var votes: [Vote] = []
        // Keep only IDs indefinitely. The richer song metadata has a separate size limit.
        var disliked: [String: Set<String>] = [:]
    }

    @ObservationIgnored weak var session: RoomViewingSession?
    @ObservationIgnored private let source: any RoomDJSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    private var searchID = UUID()
    private var batchID = UUID()
    private var scope: RoomDiscoveryCache.Scope?
    private var accountSession: UUID?
    private var votes: [Vote] = []
    private var dislikedIDs = Set<String>()
    private var removedIDs = Set<String>()
    private var candidates: [ChannelVideo] = []
    private static let lowWaterMark = 1
    private static let refillSize = 2
    private static let candidateLimit = 24
    // A track can generate several transport callbacks, including one at its natural end.
    private var lastRefillTrackID: String?
    private static let voteKey = "room.dj.feedback.v1"

    private(set) var isActive = false
    private(set) var direction = ""
    private(set) var choices: [ChannelVideo] = []
    private(set) var mode = RoomDJMode.flow
    private(set) var language: String?
    private var searchIssue: String?
    private var stationIssue: String?
    private var refillFailure: String?
    var canRetryRefill: Bool { refillFailure != nil }
    @ObservationIgnored private let providerDeadline: () -> Date?
    private(set) var retryAfter: Date?
    private var retryPrompt: String?
    private var deferredChoice: (video: ChannelVideo, prompt: String, typed: Bool)?
    var songAwaitingRetry: ChannelVideo? { deferredChoice?.video }
    var message: String? {
        if let retryAfter { return CatalogError.rateLimited(until: retryAfter).localizedDescription }
        return searchIssue ?? refillFailure ?? stationIssue
    }
    private(set) var isSearching = false
    private var isFetching = false
    private var pendingPrompt = ""
    private var seed: ChannelVideo?
    private var topic: String?
    private var promptLanguage: String?
    private var seedLanguage: String?
    // A chosen steering track gets one guaranteed place before generated recommendations.
    private(set) var requestedNext: ChannelVideo?

    convenience init(defaults: UserDefaults = .standard) {
        self.init(source: RoomDJCatalog(), defaults: defaults, providerDeadline: { RoomDJCooldown.deadline })
    }

    init(source: any RoomDJSource, defaults: UserDefaults = .standard, providerDeadline: @escaping () -> Date? = { nil }) {
        self.source = source
        self.defaults = defaults
        self.providerDeadline = providerDeadline
        retryAfter = providerDeadline()
    }

    func hold(until deadline: Date) {
        retryAfter = max(deadline, retryAfter ?? deadline)
        if isSearching { retryPrompt = pendingPrompt }
        searchID = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        cancelBatch()
        session?.holdDJQueue()
    }

    func requestsAllowed(userInitiated: Bool = false) -> Bool {
        if let deadline = providerDeadline(), deadline > (retryAfter ?? .distantPast) { hold(until: deadline) }
        if userInitiated, let retryAfter, retryAfter <= Date() { self.retryAfter = nil }
        return retryAfter == nil
    }

    func retry() {
        let resumingAfterCooldown = retryAfter != nil
        guard requestsAllowed(userInitiated: true) else { return }
        if let prompt = retryPrompt {
            submit(prompt)
        } else if let choice = deferredChoice {
            use(choice.video, prompt: choice.prompt, typed: choice.typed, immediately: true)
        } else if let session, isActive, resumingAfterCooldown || canRetryRefill {
            refillFailure = nil
            lastRefillTrackID = nil
            if case .failed = session.playback.phase { session.load() }
            else {
                session.resumeDJQueue()
                fillIfLow()
            }
        }
    }

    var isLoading: Bool { isSearching || isFetching }
    var upcoming: [ChannelVideo] { isActive ? session?.upcoming ?? [] : [] }
    var effectiveLanguage: String? { promptLanguage ?? language ?? (topic == nil ? seedLanguage : nil) }
    var likedSongs: [ChannelVideo] { votes.filter { $0.feedback == .like }.map(\.video) }
    private var dislikedSongs: [ChannelVideo] { votes.filter { $0.feedback == .dislike }.map(\.video) }
    func feedback(for video: ChannelVideo) -> RoomDJFeedback? {
        if dislikedIDs.contains(video.id) { return .dislike }
        return votes.first { $0.video.id == video.id }?.feedback
    }

    func submit(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard requestsAllowed(userInitiated: true) else {
            deferredChoice = nil
            retryPrompt = prompt
            return
        }
        clearSearch()
        cancelBatch()
        pendingPrompt = prompt
        isSearching = true
        if isActive { session?.suspendDJQueue() }
        stationIssue = nil
        let generation = searchID
        searchTask = Task {
            do {
                let lookup: String
                if let language, RoomDJCatalog.topic(for: prompt) != nil, RoomDJCatalog.language(in: prompt) == nil {
                    lookup = language + " " + prompt
                } else { lookup = prompt }
                let matches = try await source.search(lookup)
                guard generation == searchID, !Task.isCancelled, requestsAllowed() else { return }
                isSearching = false
                var seen = Set<String>()
                let unique = matches.filter { !dislikedIDs.contains($0.id) && seen.insert($0.id).inserted }
                let match = RoomDJCatalog.resolvedSeed(for: prompt, from: unique)
                if let exact = match ?? (RoomDJCatalog.topic(for: prompt) == nil ? nil : unique.first) {
                    use(exact, prompt: prompt, typed: true, immediately: !isActive)
                } else if unique.isEmpty {
                    searchIssue = "No songs found for “" + prompt + "”. Try a song and artist."
                    resumePreviousDirection()
                } else {
                    choices = Array(unique.prefix(8))
                    resumePreviousDirection()
                }
            } catch {
                guard generation == searchID, !Task.isCancelled else { return }
                if case CatalogError.rateLimited(let until) = error { hold(until: until); return }
                isSearching = false
                searchIssue = error.localizedDescription
                resumePreviousDirection()
            }
        }
    }

    private func resumePreviousDirection() {
        guard isActive else { return }
        session?.resumeDJQueue()
        fillIfLow()
    }

    func cancelChoices() {
        clearSearch()
        resumePreviousDirection()
    }

    private func clearSearch() {
        searchID = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        choices = []
        pendingPrompt = ""
        retryPrompt = nil
        deferredChoice = nil
        searchIssue = nil
    }

    func choose(_ video: ChannelVideo) {
        guard choices.contains(where: { $0.id == video.id }) else { return }
        use(video, prompt: pendingPrompt, typed: true, immediately: !isActive)
    }

    func playNow(_ video: ChannelVideo) {
        let isChoice = choices.contains { $0.id == video.id }
        use(video, prompt: isChoice ? pendingPrompt : video.title, typed: isChoice, immediately: true)
    }

    func steer(toward video: ChannelVideo) {
        use(video, prompt: video.title, typed: false, immediately: !isActive)
    }

    private func use(_ video: ChannelVideo, prompt: String, typed: Bool, immediately: Bool) {
        guard let session else { return }
        guard requestsAllowed(userInitiated: true) else {
            if !isActive {
                retryPrompt = nil
                deferredChoice = (video, prompt, typed)
            }
            return
        }
        clearSearch()
        cancelBatch()
        stationIssue = nil
        candidates.removeAll()
        lastRefillTrackID = nil
        direction = prompt
        topic = typed ? RoomDJCatalog.topic(for: prompt) : nil
        promptLanguage = typed ? RoomDJCatalog.language(in: prompt) : nil
        seedLanguage = source.detectedLanguage(for: video)
        seed = video
        let startingStation = !isActive
        isActive = true
        if immediately {
            requestedNext = nil
            session.startDJ(video, resetHistory: startingStation)
        } else {
            requestedNext = session.video?.id == video.id ? nil : video
            session.replaceDJUpcoming(requestedNext.map { [$0] } ?? [])
        }
        fillIfLow()
    }

    func setMode(_ newMode: RoomDJMode) {
        guard newMode != mode, requestsAllowed(userInitiated: true) else { return }
        mode = newMode
        rebuild()
    }

    func setLanguage(_ newLanguage: String?) {
        guard newLanguage != language || promptLanguage != nil, requestsAllowed(userInitiated: true) else { return }
        language = newLanguage
        promptLanguage = newLanguage == nil ? topic.flatMap(RoomDJCatalog.language(in:)) : nil
        if let requestedNext, let explicit = newLanguage,
           source.detectedLanguage(for: requestedNext)?.caseInsensitiveCompare(explicit) != .orderedSame {
            self.requestedNext = nil
        }
        rebuild()
    }

    private func rebuild() {
        guard isActive else { return }
        cancelBatch()
        candidates.removeAll()
        lastRefillTrackID = nil
        session?.replaceDJUpcoming(requestedNext.map { [$0] } ?? [])
        fillIfLow()
    }

    func currentChanged(to video: ChannelVideo) {
        if requestedNext?.id == video.id { requestedNext = nil }
    }

    private func cancelBatch() {
        if isFetching || canRetryRefill { lastRefillTrackID = nil }
        refillFailure = nil
        batchID = UUID()
        batchTask?.cancel()
        batchTask = nil
        isFetching = false
    }

    func pauseRefill() {
        if isFetching { cancelBatch() }
    }

    func removeUpcoming(_ video: ChannelVideo) {
        guard isActive, let session, session.upcoming.contains(where: { $0.id == video.id }) else { return }
        removedIDs.insert(video.id)
        candidates.removeAll { $0.id == video.id }
        if requestedNext?.id == video.id { requestedNext = nil }
        session.removeDJUpcoming(id: video.id)
        if session.upcoming.isEmpty { lastRefillTrackID = nil }
    }

    private func exclusions(in session: RoomViewingSession) -> Set<String> {
        session.attemptedIDs.union(session.upcoming.map(\.id)).union(dislikedIDs).union(removedIDs)
    }

    private func appendCandidates(to session: RoomViewingSession) {
        guard session.canFillDJQueue, session.upcoming.count <= Self.lowWaterMark, !candidates.isEmpty else { return }
        let next = Array(candidates.prefix(Self.refillSize))
        candidates.removeFirst(next.count)
        lastRefillTrackID = session.video?.id
        stationIssue = nil
        session.appendDJUpcoming(next)
    }

    func fillIfLow() {
        guard isActive, !isFetching, !isSearching, let seed, let session, session.canFillDJQueue,
              upcoming.count <= Self.lowWaterMark, let current = session.video, current.id != lastRefillTrackID,
              requestsAllowed() else { return }
        let excluded = exclusions(in: session)
        candidates.removeAll { excluded.contains($0.id) }
        if !candidates.isEmpty {
            appendCandidates(to: session)
            return
        }
        lastRefillTrackID = current.id
        let generation = batchID
        let disliked = dislikedSongs
        let liked = likedSongs
        let language = promptLanguage ?? language, mode = mode, topic = topic
        refillFailure = nil
        isFetching = true
        batchTask = Task {
            do {
                let tracks = try await source.station(seed: seed, language: language, mode: mode, excluding: excluded,
                                                      liked: liked, disliked: disliked, topic: topic)
                guard generation == batchID, !Task.isCancelled, requestsAllowed() else { return }
                isFetching = false
                seedLanguage = source.detectedLanguage(for: seed)
                // Edits, quick picks and handoffs can all happen during a lookup.
                var seen = excluded.union(exclusions(in: session))
                for track in tracks where seen.insert(track.id).inserted {
                    candidates.append(track)
                    if candidates.count == Self.candidateLimit { break }
                }
                if candidates.isEmpty {
                    lastRefillTrackID = session.video?.id
                    if upcoming.isEmpty { stationIssue = "No more matching songs found. Try another direction." }
                } else {
                    // Keep a completed batch available if a quick pick or handoff deferred its first append.
                    lastRefillTrackID = nil
                    appendCandidates(to: session)
                }
            } catch {
                guard generation == batchID, !Task.isCancelled else { return }
                if case CatalogError.rateLimited(let until) = error { hold(until: until); return }
                isFetching = false
                lastRefillTrackID = session.video?.id
                refillFailure = "Couldn’t load more DJ songs. " + error.localizedDescription
            }
        }
    }

    func end() {
        clearSearch()
        cancelBatch()
        removedIDs.removeAll()
        candidates.removeAll()
        lastRefillTrackID = nil
        isActive = false
        seed = nil
        seedLanguage = nil
        promptLanguage = nil
        requestedNext = nil
        direction = ""
        topic = nil
        stationIssue = nil
    }

    func select(_ newScope: RoomDiscoveryCache.Scope?, sessionID: UUID? = nil) {
        let changedAccount = sessionID != nil && accountSession != nil && sessionID != accountSession
        if let sessionID { accountSession = sessionID }
        guard newScope != scope || changedAccount else { return }
        let buffered = scope == nil && !changedAccount ? votes : []
        let bufferedIDs = scope == nil && !changedAccount ? dislikedIDs : []
        if scope != nil || changedAccount {
            if isActive { session?.close() } else { end() }
            mode = .flow
            language = nil
        }
        scope = newScope
        votes = []
        dislikedIDs = []
        guard let owner else { return }
        do {
            var archive = try readFeedback()
            if case .profile = newScope, !buffered.isEmpty || !bufferedIDs.isEmpty {
                let ids = Set(buffered.map { $0.video.id })
                archive.votes.removeAll { $0.owner == owner && ids.contains($0.video.id) }
                archive.votes.insert(contentsOf: buffered.map { Vote(owner: owner, video: $0.video, feedback: $0.feedback) }, at: 0)
                archive.disliked[owner, default: []].subtract(ids)
                archive.disliked[owner, default: []].formUnion(bufferedIDs)
                try saveFeedback(&archive)
            }
            votes = archive.votes.filter { $0.owner == owner }
            dislikedIDs = archive.disliked[owner] ?? []
            if isActive { rerank() }
        } catch {
            stationIssue = "Couldn’t read DJ feedback on this Apple TV."
        }
    }

    func like(_ video: ChannelVideo) { rate(video, .like) }
    func dislike(_ video: ChannelVideo) { rate(video, .dislike) }

    private var owner: String? {
        switch scope {
        case .local: "guest"
        case let .profile(id): "profile-" + id
        case nil: nil
        }
    }

    private func rate(_ video: ChannelVideo, _ feedback: RoomDJFeedback) {
        do {
            let key = owner ?? ""
            var archive = try owner == nil ? FeedbackArchive(votes: votes, disliked: [key: dislikedIDs]) : readFeedback()
            var excluded = archive.disliked[key] ?? []
            let matches: (Vote) -> Bool = { $0.owner == key && $0.video.id == video.id }
            let previous: RoomDJFeedback? = excluded.contains(video.id) ? .dislike : archive.votes.first(where: matches)?.feedback
            archive.votes.removeAll(where: matches)
            if previous != feedback {
                archive.votes.insert(Vote(owner: key, video: video, feedback: feedback), at: 0)
            }
            if feedback == .dislike && previous != .dislike { excluded.insert(video.id) }
            else { excluded.remove(video.id) }
            archive.disliked[key] = excluded
            if owner != nil { try saveFeedback(&archive) }
            dislikedIDs = excluded
            votes = Array(archive.votes.filter { $0.owner == key }.prefix(300))
            if isActive { rerank() }
        } catch {
            stationIssue = "Couldn’t save DJ feedback on this Apple TV."
        }
    }

    private func readFeedback() throws -> FeedbackArchive {
        guard let stored = defaults.object(forKey: Self.voteKey) else { return FeedbackArchive() }
        guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try PropertyListDecoder().decode(FeedbackArchive.self, from: data)
    }

    private func saveFeedback(_ archive: inout FeedbackArchive) throws {
        archive.votes = Array(archive.votes.prefix(300))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        while try encoder.encode(archive.votes).count > 96 * 1024 {
            guard archive.votes.count > 1 else { throw CocoaError(.fileWriteOutOfSpace) }
            archive.votes.removeLast(max(1, archive.votes.count / 8))
        }
        defaults.set(try encoder.encode(archive), forKey: Self.voteKey)
    }

    private func rerank() {
        guard let seed, let session else { return }
        cancelBatch()
        let disliked = dislikedSongs
        let excluded = session.attemptedIDs.union(dislikedIDs).union(removedIDs)
        if let requestedNext, excluded.contains(requestedNext.id) { self.requestedNext = nil }
        let preferred = requestedNext.map { [$0] } ?? []
        let rest = upcoming.filter { $0.id != requestedNext?.id && !excluded.contains($0.id) }
        let ranked = source.rank(rest, seed: seed, language: promptLanguage ?? language, mode: mode, excluding: excluded,
                                 liked: likedSongs, disliked: disliked, topic: topic)
        candidates = source.rank(candidates, seed: seed, language: promptLanguage ?? language, mode: mode,
                                 excluding: excluded.union(upcoming.map(\.id)), liked: likedSongs, disliked: disliked, topic: topic)
        lastRefillTrackID = nil
        session.replaceDJUpcoming(preferred + ranked)
        fillIfLow()
    }
}
