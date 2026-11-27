import AVFoundation
import UIKit
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
        session.playback.configureSoftFade(false, next: nil)
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

    func testSoftFadeOverlapsAudioAndPromotesTheRunningPlayer() async throws {
        let first = ChannelVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny", channelID: "UCSMOQeBJ2RAnuFungnQOxLg", channelTitle: "Blender", thumbnail: nil)
        let second = ChannelVideo(id: "eRsGyueVLvQ", title: "Sintel", channelID: first.channelID, channelTitle: first.channelTitle, thumbnail: nil)
        let session = RoomViewingSession()
        let playback = session.playback
        let outgoing = playback.player
        outgoing.isMuted = true
        session.openPlaylist(first, in: [first, second])
        defer { session.close() }
        let deadline = ContinuousClock.now + .seconds(35)
        while playback.incomingPlayer?.currentItem?.status != .readyToPlay, ContinuousClock.now < deadline {
            if case let .failed(reason) = playback.phase { return XCTFail(reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let incoming = try XCTUnwrap(playback.incomingPlayer)
        let outgoingItem = try XCTUnwrap(outgoing.currentItem)
        session.setSpeed(1.5)
        outgoingItem.forwardPlaybackEndTime = outgoing.currentTime() + CMTime(seconds: 2, preferredTimescale: 600)
        var overlap = false
        var checkedPause = false
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if outgoing.rate > 0, outgoing.volume > 0, outgoing.volume < 1,
               incoming.volume > 0, incoming.currentTime().seconds > 0.02 {
                overlap = true
                if !checkedPause {
                    outgoing.pause()
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertEqual(incoming.rate, 0, "Pausing the current video must also silence the next one")
                    checkedPause = true
                    outgoing.play()
                }
            }
            if playback.player === incoming, incoming.currentTime().seconds > 0.6 { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(overlap)
        XCTAssertTrue(playback.player === incoming)
        XCTAssertEqual(session.video?.id, second.id)
        XCTAssertEqual(incoming.volume, 1, accuracy: 0.01)
        XCTAssertTrue(incoming.isMuted)
        XCTAssertEqual(incoming.defaultRate, 1.5)
    }

    func testMiniPlayerKeepsTheSameItemAndSpeed() async throws {
        let recommendation = ChannelVideo(id: "WhWc3b3KhnY", title: "Spring",
                                          channelID: "UCz75RVbH8q2jdBJ4SnwuZZQ", channelTitle: "Blender Studio", thumbnail: nil)
        let session = RoomViewingSession(recommendations: { _ in [recommendation] })
        let video = ChannelVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny",
                                 channelID: "UCSMOQeBJ2RAnuFungnQOxLg", channelTitle: "Blender", thumbnail: nil)
        session.playback.configureSoftFade(false, next: nil)
        session.playback.player.isMuted = true
        var startedIDs: [String] = []
        session.onVideoStarted = { startedIDs.append($0.id) }
        // Give the HLS video a display surface during rate changes, as AVKit does on TV.
        let layer = AVPlayerLayer(player: session.playback.player)
        layer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow)
        window.layer.addSublayer(layer)
        defer { layer.removeFromSuperlayer() }
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
        let beforeChange = player.currentTime().seconds
        session.setSpeed(1.5)
        for _ in 0..<60 where player.currentTime().seconds < beforeChange + 0.3 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, beforeChange)
        XCTAssertEqual(player.defaultRate, 1.5)
        XCTAssertEqual(player.rate, 1.5)
        session.minimize()
        XCTAssertEqual(session.presentation, .mini)
        session.setSpeed(2)
        XCTAssertEqual(player.rate, 2)
        // A live HLS source can rebuffer as AVFoundation changes rate.
        // Measure two seconds of uninterrupted playing time.
        let speedDeadline = ContinuousClock.now + .seconds(15)
        var windowStart: ContinuousClock.Instant?
        var mediaStart = 0.0
        var mediaDelta = 0.0
        var previousTime = player.currentTime().seconds
        while ContinuousClock.now < speedDeadline {
            let seconds = player.currentTime().seconds
            if player.timeControlStatus != .playing || seconds <= previousTime {
                windowStart = nil
            } else if let windowStart {
                if ContinuousClock.now - windowStart >= .seconds(2) {
                    mediaDelta = seconds - mediaStart
                    break
                }
            } else {
                windowStart = .now
                mediaStart = seconds
            }
            previousTime = seconds
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(mediaDelta, 2.8, "mode=\(player.timeControlStatus.rawValue) rate=\(player.rate) time=\(player.currentTime().seconds) waiting=\(String(describing: player.reasonForWaitingToPlay)) ranges=\(item.loadedTimeRanges) phase=\(session.playback.phase)")
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
