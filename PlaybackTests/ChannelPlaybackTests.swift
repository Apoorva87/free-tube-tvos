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
    func testStandaloneAutoplaysRelatedAndPlaylistKeepsItsOrder() async throws {
        let seed = ChannelVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny",
                                channelID: "UCSMOQeBJ2RAnuFungnQOxLg", channelTitle: "Blender", thumbnail: nil)
        let similar = ChannelVideo(id: "eRsGyueVLvQ", title: "Sintel",
                                   channelID: seed.channelID, channelTitle: seed.channelTitle, thumbnail: nil)
        let neighbor = ChannelVideo(id: "otherVideo1", title: "Another search result",
                                    channelID: seed.channelID, channelTitle: seed.channelTitle, thumbnail: nil)
        let session = RoomViewingSession(recommendations: { _ in [seed, similar, similar] })
        defer { session.close() }
        session.playback.player.isMuted = true
        session.openPlaylist(seed, in: [seed, neighbor])
        XCTAssertEqual(session.next?.id, neighbor.id)
        session.open(seed, in: [seed, neighbor])
        let deadline = ContinuousClock.now + .seconds(30)
        while !session.playback.hasPreparedNext, ContinuousClock.now < deadline {
            if case let .failed(reason) = session.playback.phase { return XCTFail(reason) }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(session.next?.id, similar.id)
        let player = session.playback.player
        let item = try XCTUnwrap(player.currentItem)
        let warm = try XCTUnwrap(player.items().dropFirst().first)
        item.forwardPlaybackEndTime = player.currentTime() + CMTime(seconds: 1.5, preferredTimescale: 600)
        var sawFade = false
        let end = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < end {
            sawFade = sawFade || session.playback.fadeFraction > 0
            if player.currentItem === warm, player.currentTime().seconds > 0.1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawFade, "The outgoing video should fade during its final frames")
        XCTAssertTrue(player.currentItem === warm, "Promote the buffered item without resolving it again")
        XCTAssertGreaterThan(player.currentTime().seconds, 0.1)
        XCTAssertEqual(session.playback.fadeFraction, 0)
        XCTAssertEqual(session.video?.id, similar.id)
        XCTAssertEqual(session.presentation, .full)
    }

    func testMiniPlayerKeepsTheSameItemAndSpeed() async throws {
        let recommendation = ChannelVideo(id: "WhWc3b3KhnY", title: "Spring",
                                          channelID: "UCz75RVbH8q2jdBJ4SnwuZZQ", channelTitle: "Blender Studio", thumbnail: nil)
        let session = RoomViewingSession(recommendations: { _ in [recommendation] })
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
        let suite = "quick-playlist-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomPlaylistStore(defaults: defaults)
        let pick = ChannelVideo(id: "eRsGyueVLvQ", title: "Sintel", channelID: video.channelID, channelTitle: "Blender", thumbnail: nil)
        for _ in 0..<100 where !session.playback.hasPreparedNext { try await Task.sleep(for: .milliseconds(100)) }
        let oldNext = try XCTUnwrap(player.items().dropFirst().first)
        session.addToQuickPlaylist(pick, seconds: nil, store: store)
        XCTAssertFalse(player.items().contains(oldNext))
        XCTAssertTrue(player.currentItem === item)
        session.addToQuickPlaylist(pick, seconds: nil, store: store)
        for _ in 0..<100 where !session.playback.hasPreparedNext { try await Task.sleep(for: .milliseconds(100)) }
        let preparedPick = try XCTUnwrap(player.items().dropFirst().first)
        XCTAssertEqual(session.next?.id, pick.id)
        XCTAssertEqual(RoomPlaylistStore(defaults: defaults).playlists.first?.videos.map(\.id), [pick.id])
        session.expand()
        XCTAssertTrue(item === player.currentItem)
        XCTAssertEqual(player.rate, 2)
        player.pause()
        session.setSpeed(1)
        XCTAssertEqual(player.rate, 0)
        let second = ChannelVideo(id: "secondPick1", title: "Second pick", channelID: video.channelID, channelTitle: "Blender", thumbnail: nil)
        session.minimize()
        session.addToQuickPlaylist(second, seconds: nil, store: store)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        for _ in 0..<30 where session.video?.id != pick.id { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(session.presentation, .mini)
        XCTAssertEqual(session.video?.id, pick.id)
        XCTAssertEqual(session.next?.id, second.id)
        for _ in 0..<30 where player.currentItem !== preparedPick { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(player.currentItem === preparedPick)
        session.close()
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(startedIDs, [video.id])
    }
}
