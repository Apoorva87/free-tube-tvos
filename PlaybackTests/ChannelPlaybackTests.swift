import AVFoundation
import XCTest
@testable import freeTube

@MainActor
final class ChannelPlaybackTests: XCTestCase {
    func testPublicVideoAdvancesWithAPicture() async throws {
        let video = ChannelVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny",
                                 channelID: "UCSMOQeBJ2RAnuFungnQOxLg", channelTitle: "Blender", thumbnail: nil)
        let playback = ChannelPlayback()
        playback.player.isMuted = true
        let loading = Task { await playback.play(video) }
        defer {
            loading.cancel()
            playback.stop()
        }
        let deadline = ContinuousClock.now + .seconds(35)
        while ContinuousClock.now < deadline {
            if case let .failed(reason) = playback.phase {
                XCTFail("Playback failed: \(reason)")
                return
            }
            let seconds = playback.player.currentTime().seconds
            let size = playback.player.currentItem?.presentationSize ?? .zero
            if seconds >= 5 && size.width > 0 && size.height > 0 {
                let result = XCTAttachment(string: "\(video.title) played for \(seconds) seconds at \(size).")
                result.name = "Native playback on the test device"
                result.lifetime = .keepAlways
                add(result)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("The selected video never advanced five seconds with a picture.")
    }
}

extension ChannelPlaybackTests {
    func testMiniPlayerKeepsTheSameItemAndSpeed() async throws {
        let session = RoomViewingSession()
        let video = ChannelVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny",
                                 channelID: "UCSMOQeBJ2RAnuFungnQOxLg", channelTitle: "Blender", thumbnail: nil)
        session.playback.player.isMuted = true
        var startedIDs: [String] = []
        session.onVideoStarted = { startedIDs.append($0.id) }
        session.open(video, in: [video])
        defer { session.close() }
        let deadline = ContinuousClock.now + .seconds(30)
        let player = session.playback.player
        while ContinuousClock.now < deadline {
            if player.timeControlStatus == .playing, player.currentTime().seconds >= 1 { break }
            if case let .failed(reason) = session.playback.phase { return XCTFail(reason) }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard player.timeControlStatus == .playing, player.currentTime().seconds >= 1 else {
            return XCTFail("Playback did not advance before testing the mini-player and its speed.")
        }
        let item = try XCTUnwrap(player.currentItem)
        session.setSpeed(1.5)
        XCTAssertEqual(player.defaultRate, 1.5)
        XCTAssertEqual(player.rate, 1.5)
        session.minimize()
        XCTAssertEqual(session.presentation, .mini)
        session.setSpeed(2)
        let start = player.currentTime().seconds
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(player.currentTime().seconds - start, 2.8)
        session.expand()
        XCTAssertTrue(item === player.currentItem)
        XCTAssertEqual(player.rate, 2)
        player.pause()
        session.setSpeed(1)
        XCTAssertEqual(player.rate, 0)
        session.close()
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(startedIDs, [video.id])
    }
}
