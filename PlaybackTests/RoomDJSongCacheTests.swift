import XCTest
import os
@testable import freeTube

final class RoomDJSongCacheTests: XCTestCase {
    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "songs.json")
    }

    func testRelaunchRestoresPartialMetadataAndDistinguishesNegativeFromMiss() throws {
        let file = temporaryFile()
        do {
            let cache = RoomDJSongCache(fileURL: file)
            cache.store(RoomDJCatalog.Metadata(descriptors: ["jazz"], bpm: 120), for: "abcdefghijk")
            cache.store(nil, for: "lmnopqrstuv")
        }

        let reopened = RoomDJSongCache(fileURL: file)
        let facts = try XCTUnwrap(reopened.entry(for: "abcdefghijk")?.metadata)
        XCTAssertEqual(facts.descriptors, ["jazz"])
        XCTAssertEqual(facts.bpm, 120)
        XCTAssertNil(facts.language)
        XCTAssertNil(facts.views)
        XCTAssertNil(try XCTUnwrap(reopened.entry(for: "lmnopqrstuv")).metadata)
        XCTAssertNil(reopened.entry(for: "01234567890"))
    }

    func testNegativeExpiresAtSixHoursAndPositiveAtSevenDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let cache = RoomDJSongCache(fileURL: nil, capacity: 10, now: { clock.withLock { $0 } })
        cache.store(RoomDJCatalog.Metadata(music: false), for: "abcdefghijk")
        cache.store(nil, for: "lmnopqrstuv")

        clock.withLock { $0 = start.addingTimeInterval(6 * 3600 - 1) }
        XCTAssertNotNil(cache.entry(for: "lmnopqrstuv"))
        clock.withLock { $0 = start.addingTimeInterval(6 * 3600) }
        XCTAssertNil(cache.entry(for: "lmnopqrstuv"))
        clock.withLock { $0 = start.addingTimeInterval(7 * 86400 - 1) }
        XCTAssertEqual(cache.entry(for: "abcdefghijk")?.metadata?.music, false)
        clock.withLock { $0 = start.addingTimeInterval(7 * 86400) }
        XCTAssertNil(cache.entry(for: "abcdefghijk"))
    }

    func testEvictsOldestWithDeterministicTiesAndPreservesRefreshedEntry() {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let cache = RoomDJSongCache(fileURL: nil, capacity: 2, now: { clock.withLock { $0 } })
        cache.store(nil, for: "bbbbbbbbbbb")
        cache.store(nil, for: "aaaaaaaaaaa")
        clock.withLock { $0.addTimeInterval(1) }
        cache.store(nil, for: "ccccccccccc")
        XCTAssertNil(cache.entry(for: "aaaaaaaaaaa"))
        XCTAssertNotNil(cache.entry(for: "bbbbbbbbbbb"))
        clock.withLock { $0.addTimeInterval(1) }
        cache.store(RoomDJCatalog.Metadata(language: "Hindi"), for: "bbbbbbbbbbb")
        cache.store(nil, for: "ddddddddddd")
        XCTAssertEqual(cache.entry(for: "bbbbbbbbbbb")?.metadata?.language, "Hindi")
        XCTAssertNil(cache.entry(for: "ccccccccccc"))
        XCTAssertNotNil(cache.entry(for: "ddddddddddd"))
    }

    func testConcurrentWritersPreserveAllRecordsOnDisk() {
        let file = temporaryFile()
        do {
            let stores = [RoomDJSongCache(fileURL: file), RoomDJSongCache(fileURL: file)]
            DispatchQueue.concurrentPerform(iterations: 24) { index in
                stores[index % 2].store(RoomDJCatalog.Metadata(views: Double(index)),
                                        for: String(format: "%011d", index))
            }
        }
        let reopened = RoomDJSongCache(fileURL: file)
        for index in 0..<24 {
            XCTAssertEqual(reopened.entry(for: String(format: "%011d", index))?.metadata?.views, Double(index))
        }
    }

    func testCorruptFileRecoversOnNextWriteAndURLIsRejectedAsKey() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: file)
        do {
            let cache = RoomDJSongCache(fileURL: file)
            XCTAssertNil(cache.entry(for: "abcdefghijk"))
            cache.store(nil, for: "https://example.com/?token=secret")
            XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
            cache.store(RoomDJCatalog.Metadata(artist: "artist"), for: "abcdefghijk")
        }
        XCTAssertEqual(RoomDJSongCache(fileURL: file).entry(for: "abcdefghijk")?.metadata?.artist, "artist")
    }

    func testInvalidViewCountDoesNotPreventOtherFactsFromBeingSaved() throws {
        let file = temporaryFile()
        do {
            let cache = RoomDJSongCache(fileURL: file)
            cache.store(RoomDJCatalog.Metadata(language: "English", views: .infinity), for: "abcdefghijk")
            cache.store(nil, for: "lmnopqrstuv")
        }
        let reopened = RoomDJSongCache(fileURL: file)
        let facts = try XCTUnwrap(reopened.entry(for: "abcdefghijk")?.metadata)
        XCTAssertEqual(facts.language, "English")
        XCTAssertNil(facts.views)
        XCTAssertNotNil(reopened.entry(for: "lmnopqrstuv"))
    }

    func testDefaultInstancesHaveIsolatedMemory() {
        let first = RoomDJSongCache()
        first.store(nil, for: "abcdefghijk")
        XCTAssertNotNil(first.entry(for: "abcdefghijk"))
        XCTAssertNil(RoomDJSongCache().entry(for: "abcdefghijk"))
    }
}
