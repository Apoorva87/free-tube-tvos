import XCTest
@testable import ChannelRoom

final class RoomDiscoveryTests: XCTestCase {
    private func video(_ id: String, by creator: String, day: Int = 0) -> ChannelVideo {
        ChannelVideo(id: id, title: id, channelID: creator, channelTitle: creator, thumbnail: nil,
                     publishedAt: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    func testRowsMixInterestsThenSurfaceRecentDistinctCreators() {
        let science = [video("sub", by: "subscribed"), video("a1", by: "A"), video("a2", by: "A"),
                       video("c", by: "C"), video("d", by: "D", day: 2)]
        let music = [video("b", by: "B"), video("a1", by: "A"), video("e", by: "E", day: 4)]
        let rows = RoomDiscovery.recommendations(from: [science, music], excluding: ["subscribed"])
        XCTAssertEqual(rows.recommended.map(\.id), ["b", "a1", "e"])
        XCTAssertEqual(rows.explore.map(\.id), ["d", "c"])
        XCTAssertEqual(Set((rows.recommended + rows.explore).map(\.channelID)).count, 5)
    }

    func testSparsePagesReserveOneRealCreatorForEachRow() {
        let first = video("1", by: "A")
        let second = video("2", by: "B")
        let pair = RoomDiscovery.recommendations(from: [[first, first, second]], excluding: [])
        XCTAssertEqual(pair.recommended, [first])
        XCTAssertEqual(pair.explore, [second])
        let single = RoomDiscovery.recommendations(from: [[first, second]], excluding: ["A"])
        XCTAssertEqual(single.recommended, [second])
        XCTAssertTrue(single.explore.isEmpty)
        let empty = RoomDiscovery.recommendations(from: [[first]], excluding: ["A"])
        XCTAssertTrue(empty.recommended.isEmpty && empty.explore.isEmpty)
    }

    func testTopicRowsKeepUnusedVideosAndSkipBothDiscoveryRows() {
        let page = (0..<32).map { video(String($0), by: "creator-\($0)") }
        let rows = RoomDiscovery.recommendations(from: [page], excluding: [])
        let featured = rows.recommended + rows.explore
        let topics = RoomDiscovery.shelves(topics: ["Music", "Jazz"], pages: ["Music": page, "Jazz": page],
                                          featured: featured, excluding: [])
        XCTAssertEqual(rows.recommended.count, 10)
        XCTAssertEqual(rows.explore.count, 10)
        XCTAssertEqual(topics.map(\.id), ["Music"])
        XCTAssertEqual(topics.first?.videos.count, 10)
        let all = featured + topics.flatMap(\.videos)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    func testDiscoverOrdersEveryChannelByItsLatestUploadAndKeepsTenPerChannel() {
        let channels = (0..<13).map { RoomChannel(id: "c" + String($0), title: "Channel " + String($0)) }
        var uploads = (0..<12).map { video("v" + String($0), by: channels[$0].id, day: $0) }
        uploads += (1..<15).map { video("new" + String($0), by: "c0", day: 20 + $0) }
        let feed = ChannelVideo.chronological(uploads + uploads, followed: Set(channels.map(\.id)))
        let rows = RoomDiscovery.channelShelves(chronological: feed, channels: channels)
        XCTAssertEqual(rows.count, 12)
        XCTAssertEqual(rows.prefix(3).map(\.id), ["channel-c0", "channel-c11", "channel-c10"])
        XCTAssertEqual(rows[0].title, "Channel 0")
        XCTAssertEqual(rows[0].videos.map(\.id), (5...14).reversed().map { "new" + String($0) })
    }

    func testDiscoverInterleavesEachSeedListAndExcludesSeenLikedAndSubscriptionVideos() {
        let channels = [RoomChannel(id: "one", title: "One"), RoomChannel(id: "two", title: "Two")]
        let uploads = [video("seed1", by: "one", day: 2), video("seed2", by: "two", day: 1)]
        let channelRows = RoomDiscovery.channelShelves(chronological: uploads, channels: channels)
        func page(_ ids: [String]) -> RoomDiscoveryCache.Page {
            RoomDiscoveryCache.Page(date: Date(), videos: ids.map { video($0, by: "creator-" + $0) })
        }
        let related = RoomDiscoveryCache.Related(likedIDs: ["like1", "like2"], likesUpdated: Date(), pages: [
            "like1": page(["like2", "a", "c", "seen"]), "like2": page(["b", "seed1", "d"]),
            "seed1": page(["a", "f", "h"]), "seed2": page(["g", "i", "seen"])
        ])
        let rows = RoomDiscovery.discoverShelves(channelShelves: channelRows, related: related, follows: ["one", "two"],
                                                watched: ["seen"], topicPicks: [], creatorPicks: [])
        XCTAssertEqual(rows.map(\.id), ["for-you", "from-subscriptions", "channel-one", "channel-two"])
        XCTAssertEqual(rows[0].videos.map(\.id), ["b", "a", "c", "d"])
        XCTAssertEqual(rows[1].videos.map(\.id), ["g", "f", "i", "h"])
    }

    func testGuestUsesTopicResultsAndCanFillBothRowsFromASingleSuccessfulUploadSeed() {
        let seed = video("upload", by: "local")
        let row = RoomDiscoverShelf(id: "channel-local", title: "Local", videos: [seed])
        let videos = (0..<5).map { video(String($0), by: "other") }
        let related = RoomDiscoveryCache.Related(pages: [seed.id: .init(date: Date(), videos: videos)])
        let rows = RoomDiscovery.discoverShelves(channelShelves: [row], related: related, follows: ["local"],
                                                watched: ["1"], topicPicks: [], creatorPicks: [])
        XCTAssertEqual(rows.map(\.id), ["for-you", "from-subscriptions", "channel-local"])
        XCTAssertEqual(rows[0].videos.map(\.id), ["0", "2"])
        XCTAssertEqual(rows[1].videos.map(\.id), ["3", "4"])

        let guest = RoomDiscovery.discoverShelves(channelShelves: [row], related: .init(), follows: ["local"],
                                                 watched: ["1"], topicPicks: [seed, videos[0], videos[1]], creatorPicks: videos)
        XCTAssertEqual(guest[0].videos.map(\.id), ["0"])
        XCTAssertEqual(guest[1].videos.map(\.id), ["2", "3", "4"])

        let likesOnly = RoomDiscoveryCache.Related(likedIDs: ["like"], likesUpdated: Date(),
                                                  pages: ["like": .init(date: Date(), videos: videos)])
        let personal = RoomDiscovery.discoverShelves(channelShelves: [], related: likesOnly, follows: [],
                                                    watched: [], topicPicks: [], creatorPicks: [])
        XCTAssertEqual(personal.map(\.id), ["for-you"])
        let overlap = RoomDiscoveryCache.Related(likedIDs: [seed.id], likesUpdated: Date(),
                                               pages: [seed.id: .init(date: Date(), videos: videos)])
        let shared = RoomDiscovery.discoverShelves(channelShelves: [row], related: overlap, follows: ["local"],
                                                 watched: [], topicPicks: [], creatorPicks: [])
        XCTAssertEqual(shared.map(\.id), ["for-you", "from-subscriptions", "channel-local"])
        XCTAssertEqual(shared[0].videos + shared[1].videos, videos)
    }

    func testRelatedPagesAndLikesAreIsolatedByProfileAndExpireIndividually() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomDiscoveryCache(directory: directory)
        let now = Date()
        let fresh = RoomDiscoveryCache.Page(date: now, videos: [video("r", by: "c")])
        let expired = RoomDiscoveryCache.Page(date: now.addingTimeInterval(-21_600), videos: [video("x", by: "c")])
        let related = RoomDiscoveryCache.Related(likedIDs: ["one"], likesUpdated: expired.date, pages: ["one": fresh, "two": expired])
        let scope = RoomDiscoveryCache.Scope.profile("UC0000000000000000000000")
        store.writeRelated(related, for: scope)
        XCTAssertEqual(store.readRelated(scope, now: now).pages["one"]?.videos, fresh.videos)
        XCTAssertNil(store.readRelated(scope, now: now).pages["two"])
        XCTAssertTrue(store.readRelated(scope, now: now).likedIDs.isEmpty)
        XCTAssertTrue(store.readRelated(.local, now: now).pages.isEmpty)
        XCTAssertTrue(store.readRelated(.profile("UC1111111111111111111111"), now: now).pages.isEmpty)
        XCTAssertTrue(store.readRelated(nil, now: now).pages.isEmpty)
    }

    func testDiskCacheSeparatesProfilesAndLocalFollowsAndRequiresSignedInIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomDiscoveryCache(directory: directory)
        let one = RoomDiscoveryCache.Scope(signedIn: true, profileID: "UC0000000000000000000000")
        let two = RoomDiscoveryCache.Scope(signedIn: true, profileID: "UC1111111111111111111111")
        let unknown = RoomDiscoveryCache.Scope(signedIn: true, profileID: nil)
        XCTAssertNil(unknown)
        XCTAssertNil(RoomDiscoveryCache.Scope(signedIn: true, profileID: "../account"))
        let local = RoomDiscoveryCache.Scope(signedIn: false, profileID: nil)
        let now = Date()
        let page = RoomDiscoveryCache.Page(date: now, videos: [video("1", by: "A")])
        let member = RoomDiscoveryCache.membership(of: ["first", "second"])
        XCTAssertNotEqual(member, RoomDiscoveryCache.membership(of: ["first"]))
        let snapshot = RoomDiscoveryCache.Snapshot(membership: member, topics: ["Jazz"], fallback: "Jazz documentary", pages: ["Jazz": page])
        store.write(snapshot, for: unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        store.write(snapshot, for: one)
        let reopened = RoomDiscoveryCache(directory: directory)
        XCTAssertEqual(reopened.read(one, now: now)?.pages["Jazz"]?.videos, page.videos)
        XCTAssertNil(reopened.read(two, now: now))
        XCTAssertNil(reopened.read(local, now: now))
        store.write(snapshot, for: local)
        XCTAssertEqual(reopened.read(local, now: now)?.membership, member)
        XCTAssertNil(reopened.read(unknown, now: now))
    }

    func testCacheExpiresEachSearchAfterSixHours() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomDiscoveryCache(directory: directory)
        let now = Date(timeIntervalSince1970: 100_000)
        let expired = RoomDiscoveryCache.Page(date: now.addingTimeInterval(-21_600), videos: [video("1", by: "A")])
        let fresh = RoomDiscoveryCache.Page(date: now.addingTimeInterval(-21_599), videos: [video("2", by: "B")])
        let snapshot = RoomDiscoveryCache.Snapshot(membership: "test", topics: ["Music", "Sport"], fallback: "Music documentary",
                                                   pages: ["Music": expired, "Sport": fresh])
        store.write(snapshot, for: .local)
        XCTAssertEqual(store.read(.local, now: now)?.pages.count, 1)
        XCTAssertEqual(store.read(.local, now: now)?.pages["Sport"]?.videos, fresh.videos)
        XCTAssertNil(store.read(.local, now: now.addingTimeInterval(1)))
    }

    func testMobilePublicSearchReadsEscapedJSONAndCreatorIdentity() throws {
        let id = "UC0000000000000000000000"
        let entry: [String: Any] = ["videoWithContextRenderer": [
            "videoId": "one", "headline": ["simpleText": "Ada's \"machines\""],
            "shortBylineText": ["runs": [["text": "Ada", "navigationEndpoint": ["browseEndpoint": ["browseId": id]]]]]
        ]]
        let root = ["contents": ["sectionListRenderer": ["contents": [["itemSectionRenderer": ["contents": [entry]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let js = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: #"\x22"#)
            .replacingOccurrences(of: "'", with: #"\x27"#)
        let html = "<script>var ytInitialData = '" + js + "';</script>"
        let result = try ChannelCatalog.publicResults(from: Data(html.utf8)).videos
        XCTAssertEqual(result.map(\.channelID), [id])
        XCTAssertEqual(result.first?.title, "Ada's \"machines\"")
    }

    @MainActor func testGuestAndFailedUploadsPlaylistFallBackToTheVerifiedPublicVideosTab() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PublicUploadsFixture.self]
        let catalog = ChannelCatalog(session: URLSession(configuration: config))
        let id = PublicUploadsFixture.channelID
        let channel = RoomChannel(id: id, title: "Fixture", uploadsID: "uploads")
        for token in [nil, "test-token"] {
            let page = try await catalog.uploads(channel, token: token)
            XCTAssertEqual(page.videos.map(\.id), ["upload00001"])
            let first = try XCTUnwrap(page.videos.first)
            XCTAssertEqual(first.channelID, id)
            XCTAssertEqual(first.channelTitle, "Fixture")
            XCTAssertEqual(first.thumbnail?.scheme, "https")
            XCTAssertEqual(first.publishedAt.timeIntervalSinceNow, -172_800, accuracy: 65)
        }
        XCTAssertThrowsError(try ChannelCatalog.publicUploads(from: PublicUploadsFixture.html(), channelID: "UC1111111111111111111111"))
    }

    func testWatchRelatedOnlyAcceptsVideosWithAnIdentifiableCreator() throws {
        let id = "UC1111111111111111111111"
        let avatar = ["rendererContext": ["commandContext": ["onTap": ["innertubeCommand": ["browseEndpoint": ["browseId": id]]]]]]
        let metadata: [String: Any] = ["title": ["content": "Gravity"], "image": ["decoratedAvatarViewModel": avatar],
            "metadata": ["contentMetadataViewModel": ["metadataRows": [["metadataParts": [["text": ["content": "Lab"]]]]]]]]
        var video: [String: Any] = ["contentType": "LOCKUP_CONTENT_TYPE_VIDEO", "contentId": "related",
                                    "metadata": ["lockupMetadataViewModel": metadata]]
        let good = ["lockupViewModel": video]
        video["contentType"] = "LOCKUP_CONTENT_TYPE_PLAYLIST"
        let playlist = ["lockupViewModel": video]
        let items = [["itemSectionRenderer": ["contents": [good, playlist]]]]
        let root = ["contents": ["twoColumnWatchNextResults": ["secondaryResults": ["secondaryResults": ["results": items]]]]]
        let json = try JSONSerialization.data(withJSONObject: root)
        let html = "<script>var ytInitialData = " + String(decoding: json, as: UTF8.self) + ";</script>"
        let result = try ChannelCatalog.publicRelated(from: Data(html.utf8))
        XCTAssertEqual(result.map(\.id), ["related"])
        XCTAssertEqual(result.first?.channelID, id)
    }
}

private final class PublicUploadsFixture: URLProtocol, @unchecked Sendable {
    static let channelID = "UC0000000000000000000000"

    static func html() throws -> Data {
        typealias Object = [String: Any]
        let parts = [["accessibilityLabel": "2 days ago"]]
        let text: Object = ["title": ["content": "Upload"], "metadata": ["contentMetadataViewModel": ["metadataRows": [["metadataParts": parts]]]]]
        let image = ["thumbnailViewModel": ["image": ["sources": [["url": "https://example.org/poster.jpg"]]]]]
        var card: Object = ["contentId": "upload00001", "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                            "metadata": ["lockupMetadataViewModel": text], "contentImage": image]
        func item(_ card: Object) -> Object { ["richItemRenderer": ["content": ["lockupViewModel": card]]] }
        let first = item(card)
        card["contentId"] = "foreign0001"
        var other = text
        other["image"] = ["decoratedAvatarViewModel": ["rendererContext": ["commandContext": ["onTap": [
            "innertubeCommand": ["browseEndpoint": ["browseId": "UC1111111111111111111111"]]]]]]]
        card["metadata"] = ["lockupMetadataViewModel": other]
        let grid = ["richGridRenderer": ["contents": [first, first, item(card)]]]
        let tab: Object = ["selected": true, "content": grid, "endpoint": ["browseEndpoint": ["browseId": channelID],
                           "commandMetadata": ["webCommandMetadata": ["url": "/@fixture/videos"]]]]
        let root: Object = ["metadata": ["channelMetadataRenderer": ["externalId": channelID, "title": "Fixture"]],
                            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": tab]]]]]
        let json = try JSONSerialization.data(withJSONObject: root)
        return Data(("<script>var ytInitialData = " + String(decoding: json, as: UTF8.self) + ";</script>").utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let status: Int
        let body: Data
        if url.path.hasSuffix("/videos"), url.host == "www.youtube.com", request.value(forHTTPHeaderField: "Authorization") == nil {
            status = 200
            body = (try? Self.html()) ?? Data()
        } else {
            // Both the signed-in uploads playlist and public Atom requests fail.
            status = 503
            body = Data()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
