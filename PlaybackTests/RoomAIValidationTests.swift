import XCTest
@testable import ChannelRoom

final class RoomAIValidationTests: XCTestCase {
    private let a = ChannelVideo(id: "11111111111", title: "Visual explanation", channelID: "one", channelTitle: "Teacher", thumbnail: nil)
    private let b = ChannelVideo(id: "22222222222", title: "Cache design", channelID: "two", channelTitle: "Engineer", thumbnail: nil)
    private let c = ChannelVideo(id: "33333333333", title: "A worked example", channelID: "three", channelTitle: "Lab", thumbnail: nil)

    func testWebResearchSerializationContainsOnlyTheApprovedTopic() throws {
        let ref = AIPlaylistReference(id: UUID().uuidString, title: "Private playlist")
        let privateCue = AICue(index: 1, start: 0, end: 2, text: "Private captions")
        let candidate = AICandidate(id: a.id, title: a.title, channel: a.channelTitle, durationSeconds: 15)
        let request = AIRequest(kind: .research, prompt: "lunar science", videoID: a.id,
                                candidates: [candidate], cues: [privateCue], playlists: [ref])
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["kind": "research", "prompt": "lunar science"])
        XCTAssertEqual(try JSONDecoder().decode(AIRequest.self, from: data).cues.count, 0)
        let assist = AIRequest(kind: .assist, prompt: "Add videos", videoID: a.id, candidates: [candidate], cues: [privateCue], playlists: [ref])
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(assist)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["kind", "prompt", "playlists"])
        let sent = try XCTUnwrap((fields["playlists"] as? [[String: String]])?.first)
        XCTAssertEqual(sent, ["id": ref.id, "title": ref.title])
    }

    func testAssistantCanOnlySelectTargetsFromThisRequest() throws {
        let ref = AIPlaylistReference(id: UUID().uuidString, title: "Physics")
        let valid = AIProposal(action: "append", queries: ["gravitational waves"], targetID: ref.id, research: true)
        let plan = try RoomAIValidation.assist(valid, references: [ref])
        XCTAssertEqual(plan.targetID, UUID(uuidString: ref.id))
        XCTAssertTrue(plan.research)
        XCTAssertThrowsError(try RoomAIValidation.assist(valid, references: []))
        XCTAssertNil(try RoomAIValidation.assist(.init(action: "append", queries: ["space"]), references: [ref]).targetID)
        XCTAssertThrowsError(try RoomAIValidation.assist(.init(action: "find", queries: ["space"], targetID: ref.id), references: [ref]))
        XCTAssertThrowsError(try RoomAIValidation.assist(.init(action: "find", queries: ["Mars", "mars"]), references: []))
        XCTAssertThrowsError(try RoomAIValidation.assist(.init(action: "answer", message: "Mars", research: true), references: []))
        XCTAssertEqual(try RoomAIValidation.assist(.init(action: "answer", message: "First.\nSecond."), references: []).message,
                       "First.\nSecond.")
    }

    func testPublicTopicAndResearchSourcesAreValidated() throws {
        let topic = try RoomAIValidation.publicTopic(from: ["lunar geology", "lunar ice"])
        XCTAssertEqual(topic, "lunar geology\nlunar ice")
        XCTAssertThrowsError(try RoomAIValidation.publicTopic(from: [UUID().uuidString]))
        XCTAssertThrowsError(try RoomAIValidation.publicTopic(from: ["me@example.com"]))
        let result = AIProposal(message: "Lunar ice is concentrated near the poles.", queries: ["polar ice"],
                                sources: ["https://science.nasa.gov/moon/"])
        XCTAssertEqual(try RoomAIValidation.findings(result, topic: topic).sources.first?.host, "science.nasa.gov")
        for invalid in ["http://science.nasa.gov/", "https://user:secret@example.org/", "https://127.0.0.1/", "file:///tmp/file"] {
            var changed = result
            changed.sources = [invalid]
            XCTAssertThrowsError(try RoomAIValidation.findings(changed, topic: topic))
        }
    }

    func testMultiQueryCandidatesAreDeduplicatedBeforeRankingAndExcludeSavedVideos() {
        let first = RoomAskMatches(videos: [a, b], durations: [a.id: 8, b.id: 12])
        let second = RoomAskMatches(videos: [a, c], durations: [c.id: 32])
        let combined = RoomAskMatches.combined([first, second], excluding: [b.id], limit: 2)
        XCTAssertEqual(combined.candidates.map(\.id), [a.id, c.id])
        XCTAssertEqual(combined.durations, [a.id: 8, c.id: 32])
    }

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
