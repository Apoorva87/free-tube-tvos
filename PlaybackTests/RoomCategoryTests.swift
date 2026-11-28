import XCTest
import os
@testable import freeTube

final class RoomCategoryTests: XCTestCase {
    func testTilePublicationShowsElapsedHoursAcrossMidnightAndKeepsOlderDates() {
        let now = Date(timeIntervalSince1970: 1_800_061_200)
        var video = ChannelVideo(id: "age", title: "", channelID: "", channelTitle: "", thumbnail: nil)
        for (seconds, label) in [(0, "Just now"), (60, "1 min ago"), (3599, "59 mins ago"),
                                 (3600, "1 hr ago"), (7199, "1 hr ago"), (7200, "2 hrs ago"), (86_399, "23 hrs ago")] {
            let published = now.addingTimeInterval(-Double(seconds))
            XCTAssertEqual(video.tilePublication(verified: published, now: now), label)
        }
        video.publishedAt = now.addingTimeInterval(-86_400)
        XCTAssertEqual(video.tilePublication(verified: nil, now: now), video.publishedAt.formatted(date: .abbreviated, time: .omitted))
        let reported = ChannelVideo(id: "reported", title: "", channelID: "", channelTitle: "", thumbnail: nil, publicationLabel: "Streamed 2 hours ago")
        XCTAssertEqual(reported.tilePublication(verified: nil), "2 hrs ago")
        XCTAssertEqual(reported.tilePublication(verified: nil, now: Date().addingTimeInterval(3600)), "3 hrs ago")
        XCTAssertNil(ChannelVideo(id: "missing", title: "", channelID: "", channelTitle: "", thumbnail: nil).tilePublication(verified: nil, now: now))
    }

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

extension RoomCategoryTests {
    private func djTrack(_ id: String, _ title: String, _ artist: String, views: String? = nil) -> ChannelVideo {
        ChannelVideo(id: id, title: title, channelID: artist, channelTitle: artist, thumbnail: nil,
                     durationSeconds: 220, viewLabel: views)
    }

    func testDJResolvesArtistUploadAcrossHashtagAndOriginalScript() async throws {
        let original = djTrack("B_6d3RBiEN0", "#GulabiSadi ( गुलाबी साडी ) | Official #video | Sanju Rathod | G-Spark | #marathi Song", "Sanju Rathod SR")
        let copy = djTrack("03fYR-z2m_w", "Gulabi Sadi official song #gulabisadi", "AMAN LO-FI MUSIC")
        let remake = djTrack("zAEA3h529ZU", "Dhamaal 4: SAREE MV | Sanju Rathod, Tanishk", "T-Series")
        let catalog = RoomDJCatalog(search: { _ in [copy, remake, original] }, mix: { _ in [] }, metadata: { _ in nil })
        let prompt = "Play songs like Gulabi Sadi"
        let results = try await catalog.search(prompt)
        XCTAssertEqual(results.first?.id, original.id)
        XCTAssertEqual(RoomDJCatalog.resolvedSeed(for: prompt, from: results)?.id, original.id)
        XCTAssertNil(RoomDJCatalog.topic(for: prompt))
        XCTAssertEqual(RoomDJCatalog.language(in: original.title), "Marathi")
        let alternatives = [djTrack("aaaaaaa0000", "Hello (Official Video)", "AdeleVEVO"),
                            djTrack("bbbbbbb0000", "Hello (Official Video)", "Lionel Richie - Topic")]
        XCTAssertNil(RoomDJCatalog.resolvedSeed(for: "Hello", from: alternatives))
    }

    func testDJExplicitLanguageOverridesMixAndSearchLanguageLeaks() async throws {
        let seed = djTrack("B_6d3RBiEN0", "Gulabi Sadi | Marathi Song", "Sanju Rathod")
        let marathi = djTrack("sUf2PtEZris", "Shaky | Marathi Song", "Sanju Rathod")
        let hindi = djTrack("VAdGW7QDJiU", "Chaleya (Hindi) | Official Song", "T-Series")
        let unknown = djTrack("f6vY6tYvKGA", "Mystery (Official Video)", "Artist")
        let catalog = RoomDJCatalog(search: { _ in [seed, marathi, hindi, unknown] },
                                    mix: { _ in [marathi, hindi, unknown] }, metadata: { _ in nil })
        let station = try await catalog.station(seed: seed, language: "Hindi", mode: .flow,
                                                excluding: [], liked: [], disliked: [])
        XCTAssertEqual(station.map(\.id), [hindi.id])
        let automatic = try await catalog.station(seed: seed, language: nil, mode: .flow,
                                                  excluding: [], liked: [], disliked: [])
        XCTAssertEqual(automatic.map(\.id), [marathi.id])
        XCTAssertEqual(RoomDJCatalog.language(in: "more Marathi wedding songs"), "Marathi")
        XCTAssertTrue(RoomDJCatalog.topic(for: "more Marathi wedding songs")?.contains("wedding") == true)
    }

    func testDJFlowUsesPublishedMoodTempoAndPopularShuffleUsesViews() {
        let seed = djTrack("seed0000001", "Night Rain | English chill 85 BPM", "Artist One")
        let fast = djTrack("fast0000001", "All Night | English dance 150 BPM", "Artist Two", views: "900M views")
        let calm = djTrack("calm0000001", "Home | English chill 83 BPM", "Artist Three", views: "200 views")
        let disliked = djTrack("gone0000001", "Gone | English chill", "Artist Four", views: "1B views")
        let catalog = RoomDJCatalog()
        let options = [fast, calm, calm, disliked, seed]
        let flow = catalog.rank(options, seed: seed, language: "English", mode: .flow,
                                excluding: [], liked: [], disliked: [disliked])
        XCTAssertEqual(flow.map(\.id), [calm.id, fast.id])
        let pop = catalog.rank(options, seed: seed, language: "English", mode: .popularShuffle,
                               excluding: [], liked: [], disliked: [disliked])
        XCTAssertEqual(pop.first?.id, fast.id)
    }
}

extension RoomCategoryTests {
    func testDJFeedbackMovesSimilarUnvotedSongsInOppositeDirections() {
        let catalog = RoomDJCatalog()
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let neutral = djTrack("neut0000001", "Track One | English Song", "First Artist")
        let related = djTrack("rela0000001", "Track Two | English acoustic", "Second Artist")
        let vote = djTrack("vote0000001", "Another Track | English acoustic", "Third Artist")
        func order(_ options: [ChannelVideo], liked: [ChannelVideo] = [], disliked: [ChannelVideo] = []) -> [String] {
            catalog.rank(options, seed: seed, language: nil, mode: .flow, excluding: [],
                         liked: liked, disliked: disliked).map(\.id)
        }
        XCTAssertEqual(order([neutral, related]).first, neutral.id)
        XCTAssertEqual(order([neutral, related], liked: [vote]).first, related.id)
        XCTAssertEqual(order([related, neutral]).first, related.id)
        XCTAssertEqual(order([related, neutral], disliked: [vote]).first, neutral.id)
    }

    func testDJBroadMoodStartsAndReranksWithinEnglishAndHindi() async throws {
        let english = djTrack("engl0000001", "English Song | Happy", "Singer One")
        let hindi = djTrack("hind0000001", "Hindi Song | Happy", "Singer Two")
        let tamil = djTrack("tami0000001", "Tamil Song | Happy", "Singer Three")
        let catalog = RoomDJCatalog(search: { _ in [tamil, english, hindi] }, mix: { _ in [tamil] }, metadata: { _ in nil })
        XCTAssertEqual(RoomDJCatalog.topic(for: "happy"), "happy")
        XCTAssertEqual(RoomDJCatalog.topic(for: "deep house"), "deep house")
        XCTAssertFalse(RoomDJCatalog.songSized(djTrack("quiz0000001", "Finish the Lyrics | Bollywood Quiz", "Quiz Host")))
        let choices = try await catalog.search("happy")
        XCTAssertEqual(Set(choices.map(\.id)), Set([english.id, hindi.id]))
        let station = try await catalog.station(seed: english, language: nil, mode: .flow, excluding: [],
                                                liked: [], disliked: [], topic: "happy")
        XCTAssertEqual(station.map(\.id), [hindi.id])
        let reranked = catalog.rank([hindi, tamil], seed: english, language: nil, mode: .flow,
                                    excluding: [], liked: [], disliked: [], topic: "happy")
        XCTAssertEqual(reranked.map(\.id), [hindi.id])
    }
}

extension RoomCategoryTests {
    func testDJUsesExplicitSongMetadataAndSpacesPerformersAcrossLabels() throws {
        let player: [String: Any] = [
            "videoDetails": ["videoId": "song0000001", "title": "A Day", "author": "Label",
                             "keywords": ["marathi dj songs", "marathi folk song", "dance"], "viewCount": "34000",
                             "shortDescription": "Singer: Artist One\nProducer: Artist Two"],
            "microformat": ["playerMicroformatRenderer": ["category": "Music"]]
        ]
        let data = try XCTUnwrap(RoomDJCatalog.metadata(from: player, id: "song0000001"))
        XCTAssertEqual(data.language, "Marathi")
        XCTAssertEqual(data.artist, "artist one")
        XCTAssertEqual(data.views, 34000)
        XCTAssertTrue(data.descriptors.contains("dance"))
        XCTAssertNil(data.bpm)
        XCTAssertNil(RoomDJCatalog.metadata(from: player, id: "wrong000001"))

        let seed = djTrack("seed0000001", "English chill | Singer: Artist One", "Label One")
        let sameArtist = djTrack("same0000001", "Another English chill song | Singer: Artist One", "Label Two")
        let anotherArtist = djTrack("next0000001", "Other English Song | Singer: Artist Two", "Label One")
        let catalog = RoomDJCatalog()
        let tracks = catalog.rank([sameArtist, anotherArtist], seed: seed, language: nil, mode: .flow,
                                  excluding: [], liked: [], disliked: [])
        XCTAssertEqual(tracks.map(\.id), [anotherArtist.id, sameArtist.id])
    }
}

extension RoomCategoryTests {
    func testDJThinCrossLanguageOverridePivotsIntoMatchingSongsRadio() async throws {
        let seed = djTrack("seed0000001", "Seed | Marathi song", "Seed Artist")
        let pivot = djTrack("pivt0000001", "A Hindi Song", "Singer One")
        let next = djTrack("more0000001", "Another Hindi Song", "Singer Two")
        let catalog = RoomDJCatalog(search: { _ in [pivot] },
                                    mix: { id in id == pivot.id ? [next, seed] : [] }, metadata: { _ in nil })
        let songs = try await catalog.station(seed: seed, language: "Hindi", mode: .flow,
                                              excluding: [], liked: [], disliked: [])
        XCTAssertEqual(Set(songs.map(\.id)), Set([pivot.id, next.id]))
    }
}

extension RoomCategoryTests {
    func testDJSkipsIdenticalCreditedReuploadsAcrossRefillsAndIgnoresSubtitleLanguage() {
        let seed = djTrack("seed0000001", "Seed | Marathi song", "Seed Artist")
        let title = "Wajle Ki Bara | Natarang | Amruta Khanvilkar | Ajay Atul | Marathi Song"
        let first = djTrack("song0000001", title, "First Label")
        let repost = djTrack("copy0000001", title + " | Bela Shende", "Second Label")
        let catalog = RoomDJCatalog()
        let options = catalog.rank([first, repost], seed: seed, language: nil, mode: .flow,
                                   excluding: [], liked: [], disliked: [])
        XCTAssertEqual(options.count, 1)
        let refill = catalog.rank([repost], seed: seed, language: nil, mode: .flow, excluding: [first.id], liked: [], disliked: [])
        XCTAssertTrue(refill.isEmpty)
        XCTAssertNil(RoomDJCatalog.inferredLanguage(for: djTrack("lang0000001", "Cupid (English Lyrics)", "Singer")))
    }
}

private actor DJRequestTrace {
    private(set) var requests: [String] = []
    private(set) var starts: [ContinuousClock.Instant] = []

    func record(_ request: String) {
        requests.append(request)
        starts.append(.now)
    }
}

extension RoomCategoryTests {
    func testDJReadyCardsAvoidDetailLookupsAndRefillsReuseRadio() async throws {
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let tracks = (0..<16).map { djTrack(String(format: "song%07d", $0), "Track \($0) | English Song", "Artist \($0)") }
        let trace = DJRequestTrace()
        let catalog = RoomDJCatalog(search: { _ in await trace.record("search"); return [] },
                                    mix: { _ in await trace.record("mix"); return tracks },
                                    metadata: { _ in await trace.record("detail"); return nil })
        let cold = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: [], liked: [], disliked: [])
        let played = Set(cold.prefix(3).map(\.id))
        let warm = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: played, liked: [], disliked: [])
        XCTAssertEqual(Set(cold.map(\.id)), Set(tracks.map(\.id)))
        XCTAssertEqual(Set(warm.map(\.id)), Set(tracks.map(\.id)).subtracting(played))
        let requests = await trace.requests
        XCTAssertEqual(requests, ["mix"])
    }

    func testDJSparseRadioUsesThreeDetailMissesAndReusesPositiveAndNegativeEntries() async throws {
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let tracks = (0..<16).map { djTrack(String(format: "song%07d", $0), "Track \($0)", "Artist \($0)") }
        let trace = DJRequestTrace()
        let cache = RoomDJSongCache()
        func catalog() -> RoomDJCatalog {
            RoomDJCatalog(search: { _ in await trace.record("search"); return [] },
                          mix: { _ in await trace.record("mix"); return tracks },
                          metadata: { id in
                              await trace.record(id)
                              return id == tracks[2].id ? .init(language: "English") : nil
                          }, cache: cache)
        }
        let first = catalog()
        let cold = try await first.station(seed: seed, language: nil, mode: .flow, excluding: [], liked: [], disliked: [])
        let coldRequests = await trace.requests
        XCTAssertEqual(cold.map(\.id), [tracks[2].id])
        XCTAssertEqual(coldRequests, ["mix", "search"] + tracks.prefix(3).map(\.id))
        let warm = try await first.station(seed: seed, language: nil, mode: .flow, excluding: [], liked: [], disliked: [])
        XCTAssertEqual(warm, cold)
        let warmRequests = await trace.requests
        XCTAssertEqual(warmRequests, coldRequests)
        let anotherCatalog = catalog()
        let next = try await anotherCatalog.station(seed: seed, language: nil, mode: .flow, excluding: [],
                                                    liked: [], disliked: [])
        XCTAssertEqual(next, cold)
        let allRequests = await trace.requests
        XCTAssertEqual(allRequests, coldRequests + ["mix"])
    }

    func testDJBroadStationUsesBothScopedLanguagesWhenTheyNeedSeparatePages() async throws {
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let english = djTrack("engl0000001", "Happy English Song", "Singer One")
        let hindi = djTrack("hind0000001", "Happy Hindi Song", "Singer Two")
        let trace = DJRequestTrace()
        let catalog = RoomDJCatalog(search: { query in
            await trace.record(query)
            return query.hasPrefix("Hindi") ? [hindi] : [english]
        }, mix: { _ in await trace.record("mix"); return [] }, metadata: { _ in await trace.record("detail"); return nil })
        let songs = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: [],
                                              liked: [], disliked: [], topic: "happy")
        XCTAssertEqual(Set(songs.map(\.id)), [english.id, hindi.id])
        let requests = await trace.requests
        XCTAssertEqual(requests, ["English happy hit official song", "Hindi happy hit official song"])
    }

    func testDJExhaustedRadioRefillPivotsThroughPlayedSong() async throws {
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let played = (0..<8).map { djTrack(String(format: "oldx%07d", $0), "Track \($0) | English Song", "Artist \($0)") }
        let next = djTrack("next0000001", "New | English Song", "Singer")
        let catalog = RoomDJCatalog(search: { _ in [] }, mix: { id in
            id == seed.id ? played : [next]
        }, metadata: { _ in nil })
        let songs = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: Set(played.map(\.id)),
                                              liked: [], disliked: [])
        XCTAssertEqual(songs.map(\.id), [next.id])
    }

    func testDJTransientDetailFailuresStayPacedAcrossRefillsAndYieldToOtherCards() async throws {
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let tracks = (0..<8).map { djTrack(String(format: "song%07d", $0), "Track \($0)", "Artist \($0)") }
        let trace = DJRequestTrace()
        let catalog = RoomDJCatalog(search: { _ in await trace.record("search"); return [] },
                                    mix: { _ in await trace.record("mix"); return tracks },
                                    metadata: { id in
            await trace.record(id)
            if id == tracks[3].id { return .init(language: "English") }
            throw CatalogError.unreadable
        }, requestInterval: .milliseconds(50))
        let first = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: [], liked: [], disliked: [])
        let second = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: [], liked: [], disliked: [])
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.map(\.id), [tracks[3].id])
        let requests = await trace.requests
        XCTAssertEqual(requests.filter { $0.hasPrefix("song") }, tracks.prefix(4).map(\.id))
        let starts = await trace.starts
        for (a, b) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.duration(to: b), .milliseconds(40))
        }
    }

    func testDJConcurrentSearchesCoalesceAndSpaceDistinctRequests() async throws {
        let sunrise = djTrack("sunr0000001", "Sunrise (Official Video)", "Artist")
        let night = djTrack("nght0000001", "Nightcall (Official Video)", "Artist")
        let trace = DJRequestTrace()
        let catalog = RoomDJCatalog(search: { query in
            await trace.record(query)
            try await Task.sleep(for: .milliseconds(25))
            return query.hasPrefix("Sunrise") ? [sunrise] : [night]
        }, mix: { _ in [] }, metadata: { _ in nil }, requestInterval: .milliseconds(120))
        async let a = catalog.search("Sunrise")
        async let b = catalog.search("Nightcall")
        async let c = catalog.search("Sunrise")
        let values = try await [a, b, c]
        XCTAssertEqual(values.map { $0.first?.id }, [sunrise.id, night.id, sunrise.id])
        let starts = await trace.starts
        XCTAssertEqual(starts.count, 2)
        if starts.count == 2 {
            XCTAssertGreaterThanOrEqual(starts[0].duration(to: starts[1]), .milliseconds(105))
        }
    }

    func testDJRateLimitStopsRadioSearchAndDetailFallbacks() async throws {
        let seed = djTrack("seed0000001", "Seed | English Song", "Seed Artist")
        let unknown = djTrack("song0000001", "Track", "Artist")
        let until = Date().addingTimeInterval(60)
        let requests = ["mix", "search", "details"]
        for (index, failure) in requests.enumerated() {
            let trace = DJRequestTrace()
            let catalog = RoomDJCatalog(search: { _ in
                await trace.record("search")
                if failure == "search" { throw CatalogError.rateLimited(until: until) }
                return []
            }, mix: { _ in
                await trace.record("mix")
                if failure == "mix" { throw CatalogError.rateLimited(until: until) }
                return [unknown]
            }, metadata: { _ in
                await trace.record("details")
                throw CatalogError.rateLimited(until: until)
            })
            do {
                _ = try await catalog.station(seed: seed, language: nil, mode: .flow, excluding: [], liked: [], disliked: [])
                XCTFail("A \(failure) rate limit should reach the station.")
            } catch CatalogError.rateLimited(let deadline) {
                XCTAssertEqual(deadline, until)
            }
            let observed = await trace.requests
            XCTAssertEqual(observed, Array(requests.prefix(index + 1)))
        }
    }

    func testDJObservesCooldownSetWhileWaitingToStartARequest() async throws {
        let blocked = OSAllocatedUnfairLock(initialState: false)
        let until = Date().addingTimeInterval(60)
        let song = djTrack("song0000001", "Sunrise (Official Video)", "Artist")
        let trace = DJRequestTrace()
        let enteredWait = expectation(description: "Second search checked before spacing")
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let catalog = RoomDJCatalog(search: { query in await trace.record(query); return [song] },
                                    mix: { _ in [] }, metadata: { _ in nil }, requestInterval: .milliseconds(150),
                                    checkCooldown: {
            let count = checks.withLock { state in state += 1; return state }
            if blocked.withLock({ $0 }) { throw CatalogError.rateLimited(until: until) }
            if count == 3 { enteredWait.fulfill() }
        })
        _ = try await catalog.search("Sunrise")
        let pending = Task { try await catalog.search("Sunset") }
        await fulfillment(of: [enteredWait], timeout: 1)
        blocked.withLock { $0 = true }
        do {
            _ = try await pending.value
            XCTFail("An upstream cooldown announced during spacing should prevent the request.")
        } catch CatalogError.rateLimited(let deadline) {
            XCTAssertEqual(deadline, until)
        }
        let requests = await trace.requests
        XCTAssertEqual(requests, ["Sunrise official music video"])
    }

    func testDJCancellingDuringRequestSpacingPreventsLookup() async throws {
        let song = djTrack("song0000001", "Sunrise (Official Video)", "Artist")
        let trace = DJRequestTrace()
        let catalog = RoomDJCatalog(search: { query in await trace.record(query); return [song] },
                                    mix: { _ in [] }, metadata: { _ in nil }, requestInterval: .seconds(2))
        _ = try await catalog.search("Sunrise")
        let pending = Task { try await catalog.search("Sunset") }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("A cancelled search should stop before the next network start.")
        } catch is CancellationError {}
        let requests = await trace.requests
        XCTAssertEqual(requests, ["Sunrise official music video"])
    }
}
