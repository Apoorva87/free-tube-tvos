import XCTest
@testable import freeTube

@MainActor
final class RoomWatchHistoryTests: XCTestCase {
    private let suite = "RoomWatchHistoryTests." + UUID().uuidString
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    private func video(_ id: String, title: String? = nil) -> ChannelVideo {
        ChannelVideo(id: id, title: title ?? id, channelID: "creator", channelTitle: "Creator", thumbnail: nil)
    }

    func testReplayMovesUpdatedVideoToFrontAndSurvivesRelaunch() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomWatchHistoryStore(defaults: defaults)
        store.select(.local)
        store.record(video("a"))
        store.record(video("b"))
        store.record(video("a", title: "Updated"))
        let expected = [video("a", title: "Updated"), video("b")]
        XCTAssertEqual(store.videos, expected)

        let reopened = RoomWatchHistoryStore(defaults: defaults)
        reopened.select(.local)
        XCTAssertEqual(reopened.videos, expected)
    }

    func testUnidentifiedWatchesMergeOnlyIntoResolvedProfileAndKeepRecency() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let prior = RoomWatchHistoryStore(defaults: defaults)
        prior.select(.local)
        prior.record(video("guest"))
        prior.select(.profile("first"))
        prior.record(video("old"))
        prior.record(video("a"))
        prior.select(.profile("second"))
        prior.record(video("other"))

        let current = RoomWatchHistoryStore(defaults: defaults)
        current.record(video("a", title: "Replayed"))
        current.record(video("b"))
        let unknownSession = RoomWatchHistoryStore(defaults: defaults)
        XCTAssertTrue(unknownSession.videos.isEmpty)
        current.select(.profile("first"))
        XCTAssertEqual(current.videos, [video("b"), video("a", title: "Replayed"), video("old")])
        current.select(.profile("second"))
        XCTAssertEqual(current.videos, [video("other")])
        current.select(.local)
        XCTAssertEqual(current.videos, [video("guest")])

        unknownSession.record(video("unresolved"))
        unknownSession.select(.local)
        XCTAssertEqual(unknownSession.videos, [video("guest")])
    }

    func testConcurrentStoresRetainWatchesAndOversizedInputPreservesArchive() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RoomWatchHistoryStore(defaults: defaults)
        let second = RoomWatchHistoryStore(defaults: defaults)
        first.select(.local)
        second.select(.local)
        first.record(video("a"))
        second.record(video("b"))
        XCTAssertEqual(second.videos, [video("b"), video("a")])
        first.record(video("large", title: String(repeating: "x", count: 200_000)))
        XCTAssertNotNil(first.issue)
        let reopened = RoomWatchHistoryStore(defaults: defaults)
        reopened.select(.local)
        XCTAssertEqual(reopened.videos, [video("b"), video("a")])
    }
}
