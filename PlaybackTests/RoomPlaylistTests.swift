import XCTest
@testable import freeTube

@MainActor
final class RoomPlaylistTests: XCTestCase {
    private let suite = "RoomPlaylistTests." + UUID().uuidString
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private func video(_ id: String, title: String? = nil) -> ChannelVideo {
        ChannelVideo(id: id, title: title ?? id, channelID: "creator-" + id, channelTitle: "Creator", thumbnail: nil)
    }

    func testCreateAddDeduplicateReorderRenameAndReopen() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomPlaylistStore(defaults: defaults)
        let first = video("first"), second = video("second"), third = video("third")
        let list = RoomPlaylist(title: " After dinner ", videos: [first, second, first], durations: ["first": 123, "second": 60])
        try store.save(list)
        try store.add(third, to: list.id, seconds: 20)
        try store.add(video("first", title: "Updated title"), to: list.id)
        let before = try XCTUnwrap(store.playlists.first)
        XCTAssertEqual(before.title, "After dinner")
        XCTAssertEqual(before.videos.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(before.summary, "3 videos · 3:23 total")

        var draft = before
        draft.title = "Supper"
        draft.move(third, by: -1)
        draft.remove(second)
        XCTAssertEqual(store.playlists.first, before)
        try store.save(draft, replacing: before)

        let reopened = RoomPlaylistStore(defaults: defaults)
        XCTAssertEqual(reopened.playlists, [draft])
        XCTAssertEqual(reopened.playlists.first?.videos.map(\.id), ["first", "third"])
        XCTAssertEqual(reopened.playlists.first?.durations, ["first": 123, "third": 20])
        try reopened.delete(draft)
        XCTAssertTrue(RoomPlaylistStore(defaults: defaults).playlists.isEmpty)
    }

    func testSeparatePlaylistsAndConcurrentDraftsPreserveLaterChanges() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomPlaylistStore(defaults: defaults)
        let a = RoomPlaylist(title: "A", videos: [video("one")])
        let b = RoomPlaylist(title: "B", videos: [video("two")])
        let otherWindow = RoomPlaylistStore(defaults: defaults)
        try store.save(a)
        try otherWindow.save(b)
        try store.add(video("three"), to: a.id)
        var stale = a
        stale.title = "Revised"
        XCTAssertThrowsError(try store.save(stale, replacing: a))
        XCTAssertThrowsError(try store.delete(a))
        XCTAssertEqual(store.playlists[0].videos.map(\.id), ["one", "three"])
        XCTAssertEqual(store.playlists[1], b)
    }

    func testReviewAppendsToSavedPlaylistOnlyAfterConfirmation() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomPlaylistStore(defaults: defaults)
        let original = RoomPlaylist(title: "Evening", videos: [video("a"), video("b")], durations: ["a": 150])
        let other = RoomPlaylist(title: "Later", videos: [video("c")])
        try store.save(original)
        try store.save(other)
        let archive = defaults.data(forKey: RoomPlaylistStore.storageKey)

        var review = original.appending(
            [video("b", title: "A different title"), video("c"), video("c"), video("d")],
            durations: ["a": 1, "b": 2, "c": 3, "d": 4]
        )
        XCTAssertEqual(review.id, original.id)
        XCTAssertEqual(review.title, original.title)
        XCTAssertEqual(review.videos.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(Array(review.videos.prefix(2)), original.videos)
        XCTAssertEqual(original.appending([video("a"), video("b")]), original)
        review.move(video("d"), by: -1)
        review.remove(video("c"))
        review.append(video("e"), seconds: 5)
        XCTAssertEqual(store.playlists, [original, other])
        XCTAssertEqual(defaults.data(forKey: RoomPlaylistStore.storageKey), archive)

        try store.save(review, replacing: original)
        let reopened = RoomPlaylistStore(defaults: defaults)
        XCTAssertEqual(reopened.playlists, [review, other])
        XCTAssertEqual(reopened.playlists[0].videos.map(\.id), ["a", "b", "d", "e"])
        XCTAssertEqual(reopened.playlists[0].durations, ["a": 150, "d": 4, "e": 5])
    }

    func testStaleAppendReviewPreservesAnInterveningChange() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomPlaylistStore(defaults: defaults)
        let original = RoomPlaylist(title: "Evening", videos: [video("first")])
        try store.save(original)
        let review = original.appending([video("proposed")])
        let otherWindow = RoomPlaylistStore(defaults: defaults)
        try otherWindow.add(video("manually-added"), to: original.id)
        XCTAssertThrowsError(try store.save(review, replacing: original))
        let current = try XCTUnwrap(RoomPlaylistStore(defaults: defaults).playlists.first)
        XCTAssertEqual(current.videos.map(\.id), ["first", "manually-added"])
        XCTAssertEqual(current.id, original.id)
    }

    func testCorruptDataAndOversizedEditsLeavePriorArchiveUntouched() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data([0, 1, 2])
        defaults.set(corrupt, forKey: RoomPlaylistStore.storageKey)
        let unreadable = RoomPlaylistStore(defaults: defaults)
        XCTAssertNotNil(unreadable.loadError)
        XCTAssertThrowsError(try unreadable.save(RoomPlaylist(title: "Empty")))
        XCTAssertEqual(defaults.data(forKey: RoomPlaylistStore.storageKey), corrupt)
        defaults.removeObject(forKey: RoomPlaylistStore.storageKey)

        let store = RoomPlaylistStore(defaults: defaults)
        let existing = RoomPlaylist(title: "Keep", videos: [video("keep")])
        try store.save(existing)
        let saved = defaults.data(forKey: RoomPlaylistStore.storageKey)
        let large = video("huge", title: String(repeating: "z", count: 250_000))
        XCTAssertThrowsError(try store.add(large, to: existing.id))
        XCTAssertEqual(store.playlists, [existing])
        XCTAssertEqual(defaults.data(forKey: RoomPlaylistStore.storageKey), saved)
        XCTAssertThrowsError(try store.save(RoomPlaylist(title: "Too long", videos: (0...100).map { video(String($0)) })))
        XCTAssertEqual(RoomPlaylistStore(defaults: defaults).playlists, [existing])
    }

    func testDraftTotalsFollowEditsWithKnownAndUnknownDurations() {
        let first = video("first"), unknown = video("unknown")
        var draft = RoomPlaylist(title: "Study", videos: [first, unknown], durations: ["first": 3700, "absent": 30])
        XCTAssertEqual(draft.summary, "2 videos · 1:01:40 known · 1 without a duration")
        draft.remove(first)
        XCTAssertEqual(draft.summary, "1 video · duration unknown")
        draft.append(first, seconds: 125)
        draft.remove(unknown)
        XCTAssertEqual(draft.summary, "1 video · 2:05 total")
        XCTAssertEqual(RoomVideoFacts.seconds(from: "1:02:03"), 3723)
        XCTAssertEqual(RoomVideoFacts.seconds(from: "3:42"), 222)
        XCTAssertNil(RoomVideoFacts.seconds(from: "LIVE"))
        XCTAssertNil(RoomVideoFacts.seconds(from: "0:60"))
    }
}
