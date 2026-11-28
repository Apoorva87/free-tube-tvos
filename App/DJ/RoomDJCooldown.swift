import Foundation
import os

/// DJ respects requests to wait across playback, catalog work, and app launches.
enum RoomDJCooldown {
    private static let key = "room.dj.cooldownUntil"
    private static let lock = OSAllocatedUnfairLock()
    static let defaultDelay: TimeInterval = 15 * 60

    static var deadline: Date? {
        guard let saved = UserDefaults.standard.object(forKey: key) as? Date, saved > Date() else { return nil }
        return saved
    }

    static func check() throws {
        if let deadline { throw CatalogError.rateLimited(until: deadline) }
    }

    @discardableResult
    static func record(until requested: Date) -> Date {
        lock.withLock {
            let until = max(requested, deadline ?? requested)
            UserDefaults.standard.set(until, forKey: key)
            return until
        }
    }

    static func retryDate(_ header: String?, now: Date = Date()) -> Date {
        if let text = header?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if text.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = UInt(text) {
                return now.addingTimeInterval(TimeInterval(seconds))
            }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
            if let date = format.date(from: text) { return max(now, date) }
        }
        return now.addingTimeInterval(defaultDelay)
    }

    static func error(for response: HTTPURLResponse) -> CatalogError {
        let until = record(until: retryDate(response.value(forHTTPHeaderField: "Retry-After")))
        return .rateLimited(until: until)
    }
}
