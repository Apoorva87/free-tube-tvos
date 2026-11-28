import Foundation
import os

struct RoomDJSongCache: Sendable {
    struct Entry: Codable, Sendable {
        fileprivate let fetchedAt: Date
        let metadata: RoomDJCatalog.Metadata?

        fileprivate func isFresh(at date: Date) -> Bool {
            let lifetime: TimeInterval = metadata == nil ? 6 * 3600 : 7 * 86400
            return (0..<lifetime).contains(date.timeIntervalSince(fetchedAt))
        }
    }

    private typealias Records = [String: Entry]

    private final class Storage: Sendable {
        let records: OSAllocatedUnfairLock<Records>
        let writer = NSLock()

        init(_ records: Records = [:]) {
            self.records = OSAllocatedUnfairLock(initialState: records)
        }
    }

    private struct WeakStorage: Sendable {
        weak var value: Storage?
    }

    static let shared = RoomDJSongCache(fileURL: URL.cachesDirectory.appending(path: "FreeTube-DJ-songs-v1.json"))
    private static let openFiles = OSAllocatedUnfairLock(initialState: [URL: WeakStorage]())

    private let fileURL: URL?
    private let capacity: Int
    private let now: @Sendable () -> Date
    private let storage: Storage

    init(fileURL: URL? = nil) {
        self.init(fileURL: fileURL, capacity: 400, now: Date.init)
    }

    init(fileURL: URL?, capacity: Int, now: @escaping @Sendable () -> Date) {
        self.fileURL = fileURL?.standardizedFileURL
        self.capacity = max(1, capacity)
        self.now = now
        guard let url = self.fileURL else {
            storage = Storage()
            return
        }
        let limit = self.capacity
        storage = Self.openFiles.withLock { files in
            if let open = files[url]?.value { return open }
            let loaded = Storage(Self.read(url, capacity: limit, at: now()))
            files = files.filter { $0.value.value != nil }
            files[url] = WeakStorage(value: loaded)
            return loaded
        }
    }

    func entry(for id: String) -> Entry? {
        storage.records.withLock { records in
            guard let entry = records[id] else { return nil }
            guard entry.isFresh(at: now()) else {
                records.removeValue(forKey: id)
                return nil
            }
            return entry
        }
    }

    func store(_ metadata: RoomDJCatalog.Metadata?, for id: String) {
        guard RoomAIValidation.validID(id) else { return }
        // Serialize snapshots and writes together. Ranking can read memory during disk I/O.
        storage.writer.withLock {
            let snapshot = storage.records.withLock { records in
                let date = now()
                records = records.filter { $0.value.isFresh(at: date) }
                var facts = metadata
                if facts?.views?.isFinite == false { facts?.views = nil }
                records[id] = Entry(fetchedAt: date, metadata: facts)
                Self.trim(&records, to: capacity)
                return records
            }
            guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func read(_ file: URL, capacity: Int, at date: Date) -> Records {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(Records.self, from: data) else { return [:] }
        var records = decoded.filter { RoomAIValidation.validID($0.key) && $0.value.isFresh(at: date) }
        trim(&records, to: capacity)
        return records
    }

    private static func trim(_ records: inout Records, to capacity: Int) {
        guard records.count > capacity else { return }
        let oldest = records.sorted { lhs, rhs in
            if lhs.value.fetchedAt == rhs.value.fetchedAt { return lhs.key < rhs.key }
            return lhs.value.fetchedAt < rhs.value.fetchedAt
        }
        for item in oldest.prefix(records.count - capacity) { records.removeValue(forKey: item.key) }
    }
}
