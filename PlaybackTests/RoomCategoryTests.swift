import XCTest
@testable import freeTube

final class RoomCategoryTests: XCTestCase {
    private let owner = "UC0000000000000000000000"
    private typealias Object = [String: Any]

    private func document(_ content: Object) throws -> Data {
        let root = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": content]]]]]]
        let json = try JSONSerialization.data(withJSONObject: root)
        return Data(("<script>var ytInitialData = " + String(decoding: json, as: UTF8.self) + ";</script>").utf8)
    }

    private func renderer(_ id: String, status: String = "DEFAULT") -> Object {
        ["videoId": id, "title": ["simpleText": "Video " + id],
         "bylineText": ["runs": [["text": "Creator", "navigationEndpoint": ["browseEndpoint": ["browseId": owner]]]]],
         "thumbnailOverlays": [["thumbnailOverlayTimeStatusRenderer": ["style": status]]]]
    }

    private func richGrid(_ cards: [Object]) -> Object {
        let shelf: Object = ["title": ["simpleText": "Featured"], "contents": cards.map { ["richItemRenderer": ["content": $0]] }]
        return ["richGridRenderer": ["contents": [["richSectionRenderer": ["content": ["richShelfRenderer": shelf]]]]]]
    }

    func testLiveRequiresCurrentBroadcastBadgeAndDeduplicates() throws {
        let live = ["videoRenderer": renderer("stream00001", status: "LIVE")]
        let cards = [live, live, ["videoRenderer": renderer("replay00001")],
                     ["videoRenderer": renderer("future00001", status: "UPCOMING")]]
        let rows = try RoomCategoryFeed.parse(document(richGrid(cards)), category: .live)
        XCTAssertEqual(rows.map(\.title), ["Featured"])
        XCTAssertEqual(rows.flatMap(\.videos).map(\.id), ["stream00001"])
        XCTAssertThrowsError(try RoomCategoryFeed.parse(document(richGrid([cards[2]])), category: .live))
    }

    func testGamingReadsHorizontalVideoCardsAndIgnoresGameLinks() throws {
        let header = ["richListHeaderRenderer": ["title": ["runs": [["text": "GTA VI"], ["text": " highlights"]]]]]
        let cards = [["gameCardRenderer": renderer("other000001")], ["videoCardRenderer": renderer("gaming00001")]]
        let list: Object = ["header": header, "cards": cards]
        let content = ["sectionListRenderer": ["contents": [["itemSectionRenderer": ["contents": [["horizontalCardListRenderer": list]]]]]]]
        let rows = try RoomCategoryFeed.parse(document(content), category: .gaming)
        XCTAssertEqual(rows.map(\.title), ["GTA VI highlights"])
        XCTAssertEqual(rows.first?.videos.map(\.channelID), [owner])
        XCTAssertEqual(rows.first?.videos.map(\.id), ["gaming00001"])
    }

    func testMusicKeepsPlayableVideoLockupsWithCreatorIdentity() throws {
        let tap = ["innertubeCommand": ["browseEndpoint": ["browseId": owner]]]
        let creator: Object = ["content": "Artist", "commandRuns": [["onTap": tap]]]
        let metadata: Object = ["title": ["content": "Song"], "metadata": ["contentMetadataViewModel":
            ["metadataRows": [["metadataParts": [["text": creator]]]]]]]
        let badge = ["thumbnailBadgeViewModel": ["text": "3:17"]]
        let thumbnail: Object = ["image": ["sources": [["url": "https://i.ytimg.com/example.jpg"]]],
                                 "overlays": [["thumbnailOverlayBadgeViewModel": ["thumbnailBadges": [badge]]]]]
        var lockup: Object = ["contentType": "LOCKUP_CONTENT_TYPE_VIDEO", "contentId": "music000001",
                              "metadata": ["lockupMetadataViewModel": metadata], "contentImage": ["thumbnailViewModel": thumbnail]]
        let card = ["lockupViewModel": lockup]
        lockup["contentType"] = "LOCKUP_CONTENT_TYPE_STATION"
        lockup["contentId"] = "station"
        let rows = try RoomCategoryFeed.parse(document(richGrid([["lockupViewModel": lockup], card])), category: .music)
        XCTAssertEqual(rows.flatMap(\.videos).map(\.id), ["music000001"])
        XCTAssertEqual(rows.first?.videos.first?.channelTitle, "Artist")
        XCTAssertEqual(rows.first?.videos.first?.durationSeconds, 197)
        XCTAssertEqual(rows.first?.videos.first?.thumbnail?.scheme, "https")
    }

    @MainActor
    func testLateResponseCannotReplaceNewSelection() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let catalog = RoomCategoryCatalog { category in
            if category == .music {
                started.continuation.yield()
                for await _ in release.stream { break }
            }
            return [Self.shelf(category)]
        }
        let slowLoad = Task { await catalog.load(.music) }
        for await _ in started.stream { break }
        XCTAssertTrue(catalog.isLoading)
        await catalog.load(.gaming)
        release.continuation.yield()
        await slowLoad.value
        XCTAssertEqual(catalog.category, .gaming)
        XCTAssertEqual(catalog.shelves.map(\.id), ["gaming"])
        XCTAssertFalse(catalog.isLoading)
        await catalog.load(.forYou)
        XCTAssertTrue(catalog.shelves.isEmpty)
    }

    @MainActor
    func testExploreSharesDestinationCacheAndRetriesFailedCategory() async {
        actor Requests {
            var count = [RoomDiscoverCategory: Int]()
            func fetch(_ category: RoomDiscoverCategory) throws -> [RoomDiscoverShelf] {
                count[category, default: 0] += 1
                if category == .news, count[category] == 1 { throw CatalogError.unavailable("News unavailable") }
                return [RoomCategoryTests.shelf(category)]
            }
        }
        let requests = Requests()
        let catalog = RoomCategoryCatalog { try await requests.fetch($0) }
        await catalog.load(.explore)
        XCTAssertEqual(catalog.shelves.map(\.id), ["live", "sports", "gaming", "music"])
        await catalog.load(.music)
        await catalog.load(.news)
        XCTAssertEqual(catalog.shelves.map(\.id), ["news"])
        XCTAssertNil(catalog.errorMessage)
        let counts = await requests.count
        XCTAssertEqual(counts[.music], 1)
        XCTAssertEqual(counts[.news], 2)
        await catalog.load(.music, force: true)
        let refreshed = await requests.count[.music]
        XCTAssertEqual(refreshed, 2)
    }

    private static func shelf(_ category: RoomDiscoverCategory) -> RoomDiscoverShelf {
        let video = ChannelVideo(id: category.id, title: category.title, channelID: "creator", channelTitle: "Creator", thumbnail: nil)
        return RoomDiscoverShelf(id: category.id, title: category.title, videos: [video])
    }
}

extension RoomCategoryTests {
    @MainActor
    func testDiscoverRowPreferencesPersistOrderVisibilityAndCustomTopics() throws {
        let suite = "RoomCategoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = RoomDiscoverPreferences(defaults: defaults)
        XCTAssertEqual(preferences.rows.filter(\.enabled).map(\.title),
                       ["Education", "Economics", "Health", "Trending Hindi songs", "Trending English songs"])
        XCTAssertEqual(preferences.rows.filter { !$0.enabled }.map(\.id), ["personal", "channels"])

        preferences.toggle("health")
        preferences.move("health", by: -1)
        preferences.move("education", by: -1)
        preferences.remove("economics")
        preferences.toggle("personal")
        preferences.addTopic("  Space telescopes  ")
        let custom = try XCTUnwrap(preferences.rows.last)
        XCTAssertTrue(custom.isCustom)
        XCTAssertTrue(custom.enabled)
        XCTAssertEqual(custom.query, "Space telescopes")
        XCTAssertEqual(Array(preferences.rows.prefix(3).map(\.id)), ["education", "health", "economics"])
        XCTAssertFalse(try XCTUnwrap(preferences.rows.first { $0.id == "health" }).enabled)
        XCTAssertTrue(try XCTUnwrap(preferences.rows.first { $0.id == "personal" }).enabled)
        let restored = RoomDiscoverPreferences(defaults: defaults)
        XCTAssertEqual(restored.rows, preferences.rows)
        restored.remove(custom.id)
        restored.addTopic("   ")
        XCTAssertEqual(RoomDiscoverPreferences(defaults: defaults).rows, Array(preferences.rows.dropLast()))
    }
}

extension RoomCategoryTests {
    func testCreatorPopularPlaylistRequiresExactPlaylistAndOwnerAndPreservesRank() throws {
        func entry(_ id: String, creator: String) -> Object {
            let byline = ["runs": [["text": "Creator", "navigationEndpoint": ["browseEndpoint": ["browseId": creator]]]]]
            return ["playlistVideoRenderer": ["videoId": id, "title": ["simpleText": id], "shortBylineText": byline,
                                              "lengthText": ["simpleText": "24:05"]]]
        }
        let first = entry("popular0001", creator: owner)
        let second = entry("popular0002", creator: owner)
        let foreign = entry("foreign0001", creator: "UC1111111111111111111111")
        let playlist = ["playlistVideoListRenderer": ["contents": [second, foreign, second, first]]]
        let sections = [["itemSectionRenderer": ["contents": [playlist]]]]
        let tab: Object = ["selected": true, "content": ["sectionListRenderer": ["contents": sections]]]
        func page(playlistID: String, creator: String) throws -> Data {
            let header: Object = ["playlistId": playlistID, "ownerEndpoint": ["browseEndpoint": ["browseId": creator]]]
            let json = try JSONSerialization.data(withJSONObject: [
                "header": ["playlistHeaderRenderer": header],
                "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": tab]]]]
            ])
            return Data(("<script>var ytInitialData = " + String(decoding: json, as: UTF8.self) + ";</script>").utf8)
        }
        let id = "UULP" + owner.dropFirst(2)
        let ranked = try ChannelCatalog.publicMostViewed(from: page(playlistID: id, creator: owner), channelID: owner)
        XCTAssertEqual(ranked.map(\.id), ["popular0002", "popular0001"])
        XCTAssertEqual(ranked.first?.durationSeconds, 1445)
        XCTAssertThrowsError(try ChannelCatalog.publicMostViewed(from: page(playlistID: "UU" + owner.dropFirst(2), creator: owner), channelID: owner))
        XCTAssertThrowsError(try ChannelCatalog.publicMostViewed(from: page(playlistID: id, creator: "another"), channelID: owner))
    }

    func testCreatorRuntimeRowsKeepOnlyMatchingVideosAndUseRicherDuplicateMetadata() {
        func video(_ id: String, _ duration: Int? = nil, creator: String? = nil) -> ChannelVideo {
            ChannelVideo(id: id, title: id, channelID: creator ?? owner, channelTitle: "Creator", thumbnail: nil,
                         durationSeconds: duration)
        }
        let recent = [video("latest"), video("quick"), video("mid", 600), video("unknown"), video("foreign", 15, creator: "other")]
        let ranked = [video("favorite"), video("long", 1200), video("quick", 599), video("quick", 599), video("midrange", 1199)]
        let rows = RoomCreatorShelf.rows(for: owner, recent: recent, popular: ranked, facts: [:])
        XCTAssertEqual(rows.map(\.kind), [.recent, .popular, .quick, .long])
        XCTAssertEqual(rows[0].videos.map(\.id), ["latest", "quick", "mid", "unknown"])
        XCTAssertEqual(rows[1].videos.map(\.id), ["favorite", "long", "quick", "midrange"])
        XCTAssertEqual(rows[2].videos.map(\.id), ["quick"])
        XCTAssertEqual(rows[3].videos.map(\.id), ["long"])
        let songs = (0..<24).map { video("song-\($0)", 180 + $0) }
        let songRows = RoomCreatorShelf.rows(for: owner, recent: songs, popular: songs.reversed(), facts: [:])
        XCTAssertEqual(songRows.map(\.kind), [.recent, .popular, .shorter, .longer])
        let shortIDs = Set(songRows[2].videos.map(\.id))
        let longIDs = Set(songRows[3].videos.map(\.id))
        XCTAssertTrue(shortIDs.isDisjoint(with: longIDs))
        XCTAssertTrue(shortIDs.union(longIDs).isDisjoint(with: Set(songs.prefix(5).map(\.id) + songs.suffix(5).map(\.id))))
        let series = songs.enumerated().map { index, video in
            var episode = video
            episode.durationSeconds = 1800
            episode.publishedAt = Date(timeIntervalSince1970: Double(index))
            return episode
        }
        let seriesRows = RoomCreatorShelf.rows(for: owner, recent: series.reversed(), popular: series, facts: [:])
        XCTAssertEqual(seriesRows.map(\.kind), [.recent, .popular, .earlier, .more])
        XCTAssertTrue(Set(seriesRows[2].videos.map(\.id)).isDisjoint(with: seriesRows[3].videos.map(\.id)))
        XCTAssertEqual(RoomCreatorShelf.rows(for: owner, recent: [video("unknown")], popular: [], facts: [:]).map(\.kind), [.recent])
    }
}

private final class EmptyCreatorRanking: URLProtocol, @unchecked Sendable {
    static let channelID = "UC0000000000000000000000"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let body: String
        let status: Int
        if url.host == "www.youtube.com", url.path == "/playlist", authorization == nil,
           query.contains(URLQueryItem(name: "list", value: "UULP0000000000000000000000")) {
            body = #"<script>var ytInitialData = {"header":{"playlistHeaderRenderer":{"playlistId":"UULP0000000000000000000000","ownerEndpoint":{"browseEndpoint":{"browseId":"UC0000000000000000000000"}}}},"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"selected":true,"content":{"sectionListRenderer":{"contents":[]}}}}]}}};</script>"#
            status = 200
        } else if url.host == "www.googleapis.com", url.path == "/youtube/v3/search", authorization == "Bearer fixture",
                  query.contains(URLQueryItem(name: "channelId", value: Self.channelID)),
                  query.contains(URLQueryItem(name: "order", value: "viewCount")), query.contains(URLQueryItem(name: "type", value: "video")) {
            body = #"{"items":[{"id":{"videoId":"popular0001"},"snippet":{"title":"Favorite","channelTitle":"Creator","channelId":"UC0000000000000000000000"}}]}"#
            status = 200
        } else {
            body = ""
            status = 503
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension RoomCategoryTests {
    @MainActor
    func testEmptyPublicRankingUsesChannelWideSignedSortWhenAvailable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmptyCreatorRanking.self]
        let catalog = ChannelCatalog(session: URLSession(configuration: config))
        let channel = RoomChannel(id: EmptyCreatorRanking.channelID, title: "Creator")
        let guest = try await catalog.mostViewed(channel, token: nil)
        XCTAssertTrue(guest.isEmpty)
        let signed = try await catalog.mostViewed(channel, token: "fixture")
        XCTAssertEqual(signed.map(\.id), ["popular0001"])
    }
}
