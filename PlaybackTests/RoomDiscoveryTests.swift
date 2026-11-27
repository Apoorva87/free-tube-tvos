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
