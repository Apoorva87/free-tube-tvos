import XCTest
@testable import ChannelRoom

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
