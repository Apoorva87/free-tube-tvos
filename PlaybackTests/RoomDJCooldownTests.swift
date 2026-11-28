import Foundation
import XCTest
@testable import freeTube

final class RoomDJCooldownTests: XCTestCase {
    func testDelayUsesServerSecondsOrHTTPDateAndHasAnOfflineDefault() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RoomDJCooldown.retryDate("120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(RoomDJCooldown.retryDate("Tue, 14 Nov 2023 22:15:20 GMT", now: now),
                       now.addingTimeInterval(120))
        XCTAssertEqual(RoomDJCooldown.retryDate(nil, now: now), now.addingTimeInterval(900))
        XCTAssertEqual(RoomDJCooldown.retryDate("oops", now: now), now.addingTimeInterval(900))
    }
}
