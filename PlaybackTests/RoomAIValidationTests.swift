import XCTest
@testable import ChannelRoom

final class RoomAIValidationTests: XCTestCase {
    private let a = ChannelVideo(id: "11111111111", title: "Visual explanation", channelID: "one", channelTitle: "Teacher", thumbnail: nil)
    private let b = ChannelVideo(id: "22222222222", title: "Cache design", channelID: "two", channelTitle: "Engineer", thumbnail: nil)
    private let c = ChannelVideo(id: "33333333333", title: "A worked example", channelID: "three", channelTitle: "Lab", thumbnail: nil)

    func testOnlyReturnedSearchResultsCanEnterThePlaylist() throws {
        XCTAssertEqual(try RoomAIValidation.resolve([], in: [a,b]), [])
        XCTAssertEqual(try RoomAIValidation.resolve([a.id, a.id, b.id], in: [a,b]), [a,b])
        XCTAssertThrowsError(try RoomAIValidation.resolve([a.id,c.id], in: [a,b]))
        XCTAssertThrowsError(try RoomAIValidation.resolve([a.id], in: [a,b], excluding: a.id))
        XCTAssertThrowsError(try RoomAIValidation.resolve(["https://foo"], in: [a,b]))
    }

    func testTimedDraftUsesVerifiedDurationsAndTeachingOrder() {
        let target = RoomAIValidation.targetSeconds(in: "Build a 45-minute playlist that teaches KV cache with visual explainers and no repeats.")
        XCTAssertEqual(target, 2700)
        XCTAssertEqual(RoomAIValidation.fitting([a,b,c], durations: [a.id:1500,b.id:1800,c.id:900], target: target), [b,c])
        XCTAssertEqual(RoomAIValidation.fitting([a,b,c], durations: [b.id:3000], target: target), [])
    }

    func testUnsentOrOutOfVideoCaptionReferencesCannotBeUsed() throws {
        let cue = AICue(index: 7, start: 30, end: 34, text: "Memory bandwidth limits decoding.")
        let outside = AICue(index: 8, start: 310, end: 311, text: "Different interval.")
        let track = try RoomAIValidation.validTrack([cue, outside], duration: 60)
        XCTAssertEqual(track, [cue])
        XCTAssertThrowsError(try RoomAIValidation.summary(.init(points: [.init(text: "A claim", cueIndex: 8)]), in: track))
        XCTAssertThrowsError(try RoomAIValidation.evidence(-1, in: track))
        XCTAssertThrowsError(try RoomAIValidation.validTrack([cue, cue], duration: 60))
        XCTAssertEqual(try RoomAIValidation.evidence(7, in: track).start, 30)
    }

    func testLongTracksKeepQueryHitsWithinTheScopedBudget() throws {
        var cues: [AICue] = []
        for i in 0..<700 {
            let caption = i == 421 ? "Memory bandwidth" : "Other caption"
            cues.append(AICue(index: i, start: Double(i), end: Double(i + 1), text: caption))
        }
        let slice = RoomAIValidation.excerpts(cues, question: "where is memory bandwidth explained?", forJump: true)
        XCTAssertTrue(slice.contains(cues[421]))
        XCTAssertLessThanOrEqual(slice.count,256)
        XCTAssertEqual(Set(slice.map(\.index)).count, slice.count)
        XCTAssertLessThanOrEqual(slice.reduce(0) { $0 + $1.text.utf8.count }, 60_000)
    }
}
