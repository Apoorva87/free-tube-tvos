import Foundation
import Observation

@MainActor @Observable
final class RoomInterestFeed {
    private(set) var shelves = [RoomDiscoverShelf]()
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private struct Page {
        let videos: [ChannelVideo]
        let expires: Date
    }

    @ObservationIgnored private var cache = [String: Page]()
    @ObservationIgnored private var currentRequest = UUID()
    private let fetch: @Sendable (String) async throws -> [ChannelVideo]

    init() {
        let catalog = ChannelCatalog()
        fetch = { try await catalog.publicSearch($0).videos }
    }

    init(fetch: @escaping @Sendable (String) async throws -> [ChannelVideo]) {
        self.fetch = fetch
    }

    func load(rows: [RoomInterestRow], force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        currentRequest = request
        let topics = rows.compactMap { row -> (id: String, title: String, query: String)? in
            let query = row.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard row.enabled, !query.isEmpty else { return nil }
            return (row.id, row.title, query)
        }
        let now = Date()
        var seenQueries = Set<String>()
        let pending = topics.map(\.query).filter { query in
            seenQueries.insert(query).inserted && (force || (cache[query]?.expires ?? .distantPast) <= now)
        }
        // Keep previously loaded shelves visible while refreshing, including if the refresh fails.
        func publish() {
            var seen = Set<String>()
            shelves = topics.compactMap { topic in
                guard let page = cache[topic.query] else { return nil }
                var videos = [ChannelVideo]()
                for video in page.videos where seen.insert(video.id).inserted {
                    videos.append(video)
                    if videos.count == 10 { break }
                }
                return videos.isEmpty ? nil : RoomDiscoverShelf(id: topic.id, title: topic.title, videos: videos)
            }
        }

        publish()
        errorMessage = nil
        isLoading = !pending.isEmpty
        guard isLoading else { return }
        var failures = Set<String>()
        await withTaskGroup(of: (String, Result<[ChannelVideo], Error>).self) { group in
            var queries = pending.makeIterator()
            func enqueueNext() {
                guard let query = queries.next() else { return }
                group.addTask { [fetch] in
                    do { return (query, .success(try await fetch(query))) }
                    catch { return (query, .failure(error)) }
                }
            }
            for _ in 0..<min(3, pending.count) { enqueueNext() }
            for await (query, result) in group {
                guard currentRequest == request, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .success(let videos):
                    cache[query] = Page(videos: videos, expires: Date().addingTimeInterval(900))
                    publish()
                case .failure:
                    failures.insert(query)
                    if let prior = cache[query] {
                        cache[query] = Page(videos: prior.videos, expires: .distantPast)
                    }
                }
                enqueueNext()
            }
        }
        guard currentRequest == request else { return }
        isLoading = false
        if !Task.isCancelled, !failures.isEmpty {
            let titles = topics.filter { failures.contains($0.query) }.map(\.title)
            errorMessage = "Couldn’t load " + titles.joined(separator: ", ") + "."
        }
    }
}
