import AVFoundation
import MediaPlayer
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
        try await verifyTwoSecondOverlap(in: RoomViewingSession())
    }

    func testConfiguredAudioOverlapWithLocalMedia() async throws {
        let file = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: file) })
        try await verifyTwoSecondOverlap(in: RoomViewingSession(playback: playback))
    }

    private func verifyTwoSecondOverlap(in session: RoomViewingSession) async throws {
        let first = ChannelVideo(id: "aqz-KE-bpKQ", title: "Big Buck Bunny", channelID: "UCSMOQeBJ2RAnuFungnQOxLg", channelTitle: "Blender", thumbnail: nil)
        let second = ChannelVideo(id: "eRsGyueVLvQ", title: "Sintel", channelID: first.channelID, channelTitle: first.channelTitle, thumbnail: nil)
        let playback = session.playback
        playback.configureOverlap(seconds: 2)
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
        var heardBeforePictureFade = false
        var overlap = false
        var checkedPause = false
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if outgoing.rate > 0, outgoing.volume > 0, outgoing.volume < 1,
               incoming.volume > 0, incoming.currentTime().seconds > 0.02 {
                overlap = true
                if playback.fadeFraction == 0 { heardBeforePictureFade = true }
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
        XCTAssertTrue(heardBeforePictureFade, "Two-second audio overlap begins before the final picture fade")
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

private struct DJFixtureCatalog: RoomDJSource {
    let searchResults: @Sendable (String) async throws -> [ChannelVideo]
    let recommendations: @Sendable (ChannelVideo, Set<String>) async throws -> [ChannelVideo]

    func search(_ query: String) async throws -> [ChannelVideo] { try await searchResults(query) }

    func station(seed: ChannelVideo, language: String?, mode: RoomDJMode, excluding: Set<String>,
                 liked: [ChannelVideo], disliked: [ChannelVideo], topic: String?) async throws -> [ChannelVideo] {
        try await recommendations(seed, excluding)
    }

    func rank(_ videos: [ChannelVideo], seed: ChannelVideo, language: String?, mode: RoomDJMode,
              excluding: Set<String>, liked: [ChannelVideo], disliked: [ChannelVideo], topic: String?) -> [ChannelVideo] {
        RoomDJCatalog().rank(videos, seed: seed, language: language, mode: mode, excluding: excluding,
                             liked: liked, disliked: disliked, topic: topic)
    }
}

// Deliberately completes even after the awaiting request has been cancelled.
private actor DJRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func count() -> Int { calls += 1; return calls }
    var waiting: Bool { continuation != nil }
    func suspend() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

extension ChannelPlaybackTests {
    private func djSong(_ id: String, _ title: String, artist: String = "Sanju Rathod") -> ChannelVideo {
        ChannelVideo(id: id, title: title, channelID: artist, channelTitle: artist, thumbnail: nil, durationSeconds: 180)
    }

    private func djAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames: AVAudioFrameCount = 441_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(frames))
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func djWait(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                        until ready: @MainActor () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !(await ready()) {
            guard ContinuousClock.now < end else {
                XCTFail("Timed out waiting for " + description, file: file, line: line)
                throw CocoaError(.userCancelled)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDJRateLimitHoldsTheRecordingAndUpcomingQueue() async throws {
        let seed = djSong("B_6d3RBiEN0", "Gulabi Sadi | Marathi Song")
        let next = djSong("sUf2PtEZris", "Shaky | Marathi Song")
        let gate = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in XCTFail("Unexpected search"); return [] },
                                       recommendations: { _, _ in XCTFail("Unexpected refill"); return [] })
        let station = RoomDJStation(source: catalog)
        var attempts = 0
        let playback = ChannelPlayback(itemResolver: { _ in
            attempts += 1
            await gate.suspend()
            throw PublicPlayerError.badResponse(429)
        })
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("the seed resolver") { await gate.waiting }
        station.steer(toward: next)
        await gate.release()
        try await djWait("the provider rate limit") { playback.rateLimited && station.retryAfter != nil }
        session.load()
        session.advance()
        station.fillIfLow()
        station.submit("a different song")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(session.video?.id, seed.id)
        XCTAssertEqual(session.next?.id, next.id)
    }

    func testDJCatalogCooldownPreservesPlaybackAndWaitsForExplicitRetry() async throws {
        let seed = djSong("seed", "Seed Song")
        let next = djSong("next", "Requested next song")
        let fresh = djSong("fresh", "Fresh song")
        let calls = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in
            if await calls.count() == 1 { throw CatalogError.rateLimited(until: Date().addingTimeInterval(1)) }
            return [fresh]
        })
        let station = RoomDJStation(source: catalog)
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        station.steer(toward: next)
        try await djWait("catalog cooldown during playback") { station.retryAfter != nil }
        XCTAssertFalse(station.canRetryRefill)
        XCTAssertEqual(session.next?.id, next.id)
        let item = try XCTUnwrap(playback.player.currentItem)
        item.forwardPlaybackEndTime = playback.player.currentTime() + CMTime(seconds: 0.2, preferredTimescale: 600)
        try await djWait("the original song to finish") { playback.phase == .finished }
        station.retry()
        session.advance()
        try await djWait("the cooldown to elapse") { (station.retryAfter ?? .distantFuture) <= Date() }
        XCTAssertEqual(session.video?.id, seed.id)
        XCTAssertEqual(session.next?.id, next.id)
        let beforeRetry = await calls.calls
        XCTAssertEqual(beforeRetry, 1)
        station.retry()
        try await djWait("the preserved next song and a resumed refill") {
            session.video?.id == next.id && session.next?.id == fresh.id
        }
    }

    func testDJPreparesOnlyTheLatestQueueHeadAndExplicitAdvanceBypassesTheDelay() async throws {
        let seed = djSong("seed", "Seed song")
        let first = djSong("first", "First recommendation")
        let intermediate = djSong("intermediate", "Intermediate request")
        let latest = djSong("latest", "Latest request")
        let immediate = djSong("immediate", "Play now")
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { anchor, _ in
            anchor.id == seed.id ? [first] : []
        })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var resolutions = [String]()
        let playback = ChannelPlayback(itemResolver: { video in
            resolutions.append(video.id)
            return AVPlayerItem(url: url)
        })
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("the first preloaded recommendation") { playback.hasPreparedNext }
        station.steer(toward: intermediate)
        station.steer(toward: latest)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(resolutions, [seed.id, first.id])
        XCTAssertEqual(session.next?.id, latest.id)
        try await djWait("the stable queue head to prepare") { playback.hasPreparedNext }
        XCTAssertEqual(resolutions, [seed.id, first.id, latest.id])
        station.steer(toward: immediate)
        let advancedAt = ContinuousClock.now
        session.advance()
        try await djWait("explicit advance to resolve the request") {
            resolutions.last == immediate.id && playback.player.currentTime().seconds > 0.1
        }
        XCTAssertLessThan(ContinuousClock.now - advancedAt, .seconds(5))
        XCTAssertEqual(session.video?.id, immediate.id)
        XCTAssertEqual(resolutions, [seed.id, first.id, latest.id, immediate.id])
    }

    func testDJThrottledPrefetchCannotStartASecondResolverAtHandoff() async throws {
        let seed = djSong("seed", "Seed song")
        let next = djSong("next", "Next song")
        let tail = djSong("tail", "Editable tail")
        let gate = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in [next, tail] })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var nextAttempts = 0
        let playback = ChannelPlayback(itemResolver: { video in
            if video.id == next.id {
                nextAttempts += 1
                if nextAttempts == 1 { await gate.suspend() }
                throw PublicPlayerError.badResponse(429)
            }
            return AVPlayerItem(url: url)
        })
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("preparation of the next song") { await gate.waiting }
        let item = try XCTUnwrap(playback.player.currentItem)
        item.forwardPlaybackEndTime = playback.player.currentTime() + CMTime(seconds: 0.2, preferredTimescale: 600)
        try await djWait("the session to wait for the prepared song") { session.video?.id == next.id }
        station.removeUpcoming(next) // The old row has already become current.
        station.removeUpcoming(tail)
        XCTAssertTrue(station.upcoming.isEmpty)
        await gate.release()
        try await djWait("the throttled handoff to stop") {
            if case .failed = playback.phase { return station.retryAfter != nil }
            return false
        }
        XCTAssertEqual(nextAttempts, 1)
        XCTAssertEqual(session.video?.id, next.id)
    }

    func testDJRetainsExactSearchSelectionWhenOpenedDuringCooldown() async throws {
        let seed = djSong("seed", "Exact song")
        let deadline = Date().addingTimeInterval(0.15)
        let catalog = DJFixtureCatalog(searchResults: { _ in XCTFail("Unexpected search"); return [] },
                                       recommendations: { _, _ in [] })
        let station = RoomDJStation(source: catalog, providerDeadline: { deadline > Date() ? deadline : nil })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var attempts = 0
        let playback = ChannelPlayback(itemResolver: { _ in
            attempts += 1
            return AVPlayerItem(url: url)
        })
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        station.retry()
        XCTAssertEqual(station.songAwaitingRetry?.id, seed.id)
        XCTAssertEqual(attempts, 0)
        try await djWait("the startup cooldown to elapse") { deadline <= Date() }
        station.retry()
        try await djWait("the original selection to play") { playback.player.currentTime().seconds > 0.1 }
        XCTAssertEqual(session.video?.id, seed.id)
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(station.songAwaitingRetry)
    }

    func testDJPausingCancelsRefillAndResumingReplenishesTheQueue() async throws {
        let seed = djSong("seed", "Seed song")
        let stale = djSong("stale", "Cancelled lookup")
        let fresh = djSong("fresh", "Current lookup")
        let gate = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in
            if await gate.count() == 1 {
                await gate.suspend()
                return [stale]
            }
            return [fresh]
        })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let station = RoomDJStation(source: catalog)
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("a refill during playback") { await gate.waiting }
        let item = try XCTUnwrap(playback.player.currentItem)
        playback.player.pause()
        try await djWait("refill cancellation after pause") { !station.isLoading }
        await gate.release()
        station.fillIfLow()
        XCTAssertNil(session.next)
        playback.player.play()
        try await djWait("one fresh refill on resume") { session.next?.id == fresh.id }
        XCTAssertTrue(item === playback.player.currentItem)
        let count = await gate.calls
        XCTAssertEqual(count, 2)
    }

    func testFailedDJSeedRetriesAndStaysSelectedUntilTheViewerActs() async throws {
        let seed = djSong("B_6d3RBiEN0", "Gulabi Sadi | Marathi Song")
        let next = djSong("sUf2PtEZris", "Shaky | Marathi Song")
        let catalog = DJFixtureCatalog(searchResults: { _ in [seed] }, recommendations: { _, _ in [next] })
        let station = RoomDJStation(source: catalog)
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var attempts = 0
        let playback = ChannelPlayback(itemResolver: { video in
            if video.id == seed.id {
                attempts += 1
                if attempts <= 2 { throw URLError(.resourceUnavailable) }
            }
            return AVPlayerItem(url: url)
        })
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("two attempts at the selected recording") {
            guard case .failed = playback.phase else { return false }
            return attempts == 2
        }
        XCTAssertEqual(session.video?.id, seed.id)
        XCTAssertNil(session.next, "A seed that never played must not launch background catalog lookups")
        session.load()
        try await djWait("retry of the same recording and its first refill") {
            playback.player.currentTime().seconds > 0.1 && session.next?.id == next.id
        }
        XCTAssertEqual(session.video?.id, seed.id)
        XCTAssertEqual(attempts, 3)
    }

    func testDJGulabiSadiSeedRefillFeedbackAndSteeringPreserveTheRunningPlayer() async throws {
        let seed = djSong("B_6d3RBiEN0", "Gulabi Sadi | Official Marathi Song")
        let newSeed = djSong("sUf2PtEZris", "Shaky | Official Marathi Song")
        let firstPool = (1...12).map { djSong("song-\($0)", "Song \($0) | Marathi Music Video", artist: "Singer \($0)") }
        let secondPool = (1...8).map { djSong("shaky-\($0)", "Tune \($0) | Marathi Music Video", artist: "Artist \($0)") }
        let catalog = DJFixtureCatalog(searchResults: { query in
            query.localizedCaseInsensitiveContains("Shaky") ? [newSeed] : [seed]
        }, recommendations: { anchor, excluded in
            let pool = anchor.id == seed.id ? firstPool : secondPool
            return Array(pool.filter { !excluded.contains($0.id) }.prefix(4))
        })
        let suite = "dj-station-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let station = RoomDJStation(source: catalog, defaults: defaults)
        station.select(.local)
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let session = RoomViewingSession(playback: playback, djStation: station, recommendations: { _ in [newSeed] })
        defer { session.close() }
        playback.configureSoftFade(false, next: nil)
        playback.player.isMuted = true

        station.submit("songs like Gulabi Sadi")
        try await djWait("the exact song, its first two picks and audio playback") {
            session.video?.id == seed.id && station.upcoming.count == 2 && playback.player.currentTime().seconds > 0.1
        }
        XCTAssertEqual(session.presentation, .mini)
        XCTAssertEqual(station.effectiveLanguage, "Marathi")
        let firstItem = try XCTUnwrap(playback.player.currentItem)
        // Let AVFoundation signal a natural end and verify that crossing the low-water mark refills the queue.
        firstItem.forwardPlaybackEndTime = playback.player.currentTime() + CMTime(seconds: 0.5, preferredTimescale: 600)
        try await djWait("the next song and a replenished queue") {
            session.video?.id == firstPool[0].id && station.upcoming.map(\.id) == ["song-2", "song-3", "song-4"]
                && playback.player.currentTime().seconds > 0.15
        }
        let player = playback.player
        let item = try XCTUnwrap(player.currentItem)
        let currentID = session.video?.id
        let removed = try XCTUnwrap(station.upcoming.first)
        station.dislike(removed)
        XCTAssertFalse(station.upcoming.contains { $0.id == removed.id })
        station.like(seed)
        let restored = RoomDJStation(source: catalog, defaults: defaults)
        restored.select(.local)
        XCTAssertEqual(restored.feedback(for: removed), .dislike)
        XCTAssertEqual(restored.likedSongs.map(\.id), [seed.id])
        restored.select(.profile("another-profile"))
        XCTAssertNil(restored.feedback(for: removed))
        XCTAssertTrue(restored.likedSongs.isEmpty)

        let before = player.currentTime().seconds
        station.submit("songs like Shaky")
        try await djWait("steering and uninterrupted audio") {
            session.next?.id == newSeed.id && station.upcoming.contains(where: { $0.id == secondPool[0].id })
                && player.currentTime().seconds > before + 0.1
        }
        XCTAssertTrue(playback.player === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(session.video?.id, currentID)
        XCTAssertTrue(Set(station.upcoming.map(\.id)).isDisjoint(with: firstPool.map(\.id)))

        station.setLanguage("Hindi")
        station.playNow(seed)
        XCTAssertEqual(session.video?.id, seed.id)
        XCTAssertEqual(station.effectiveLanguage, "Hindi", "Direct song playback preserves an explicit language choice")
        XCTAssertEqual(session.presentation, .mini)
        XCTAssertTrue(station.isActive)

        session.openPlaylist(newSeed, in: [newSeed, removed, seed])
        XCTAssertFalse(station.isActive)
        XCTAssertEqual(session.upcoming.map(\.id), [removed.id, seed.id])
        XCTAssertEqual(session.presentation, .full)
        session.open(seed, in: [seed, removed])
        try await djWait("ordinary related autoplay") { session.next?.id == newSeed.id }
        XCTAssertFalse(station.isActive)
    }

    func testDJChoiceAndSupersededSearchAndRefillCannotChangeANewerDirection() async throws {
        let original = djSong("B_6d3RBiEN0", "Gulabi Sadi | Official Marathi Song")
        let cover = djSong("cover123456", "Gulabi Sadi | Official Marathi Song", artist: "Another Artist")
        let next = djSong("sUf2PtEZris", "Shaky | Official Marathi Song")
        let pick = djSong("new-pick", "New Song | Marathi Music Video")
        let stale = djSong("stale", "Old Song | Marathi Music Video")
        let searchGate = DJRequestGate(), batchGate = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { query in
            if query == "earlier request" { await searchGate.suspend(); return [stale] }
            return [original, cover]
        }, recommendations: { seed, _ in
            if seed.id == original.id { await batchGate.suspend(); return [stale] }
            return [pick]
        })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) }), djStation: station)
        defer { session.close() }
        session.playback.player.isMuted = true
        station.submit("earlier request")
        try await djWait("the slow search to start") { await searchGate.waiting }
        station.submit("songs like Gulabi Sadi")
        try await djWait("two plausible song choices") { station.choices.count == 2 }
        XCTAssertNil(session.video)
        station.choose(original)
        XCTAssertEqual(session.video?.id, original.id)
        try await djWait("the old direction to request songs") { await batchGate.waiting }
        station.steer(toward: next)
        try await djWait("the steered queue") { station.upcoming.map(\.id) == [next.id, pick.id] }
        await searchGate.release()
        await batchGate.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(station.upcoming.map(\.id), [next.id, pick.id])
        XCTAssertEqual(session.video?.id, original.id)
        XCTAssertTrue(station.choices.isEmpty)
        station.playNow(next)
        XCTAssertEqual(session.video?.id, next.id)
    }
}

extension ChannelPlaybackTests {
    func testDJRetainsProfileDislikesWhenRecentSongMetadataIsPruned() async throws {
        let suite = "dj-dislikes-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = djSong("B_6d3RBiEN0", "Gulabi Sadi | Official Marathi Song")
        let blocked = djSong("suppressed1", "Earlier dislike | Marathi Song")
        let allowed = djSong("otherpick01", "Still eligible | Marathi Song")
        let catalog = DJFixtureCatalog(searchResults: { _ in [seed] }, recommendations: { _, _ in [blocked, allowed] })
        let preferences = RoomDJStation(source: catalog, defaults: defaults)
        let firstAccount = UUID(), secondAccount = UUID()
        preferences.select(nil, sessionID: firstAccount)
        preferences.dislike(blocked)
        preferences.select(nil, sessionID: secondAccount)
        XCTAssertNil(preferences.feedback(for: blocked), "Unresolved profiles cannot inherit a previous account’s votes")
        preferences.select(.local)
        preferences.dislike(blocked)
        preferences.select(.profile("second-viewer"))
        XCTAssertNil(preferences.feedback(for: blocked))
        for i in 0...300 { preferences.like(djSong("rated-\(i)", "Song \(i)")) }
        XCTAssertLessThanOrEqual(preferences.likedSongs.count, 300)

        let restored = RoomDJStation(source: catalog, defaults: defaults)
        restored.select(.local)
        XCTAssertEqual(restored.feedback(for: blocked), .dislike)
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RoomViewingSession(playback: ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) }), djStation: restored)
        defer { session.close() }
        restored.playNow(seed)
        try await djWait("a refill after earlier feedback metadata was evicted") { !restored.upcoming.isEmpty }
        XCTAssertEqual(restored.upcoming.map(\.id), [allowed.id])
        restored.dislike(blocked)
        XCTAssertNil(restored.feedback(for: blocked), "Toggling the dislike releases the durable exclusion")
    }

    func testDJShowsEnrichedSeedLanguageAndRestoresBroadAndDirectLanguageDefaults() async throws {
        let seed = djSong("B_6d3RBiEN0", "Gulabi Sadi | Official Song")
        let marathi = djSong("sUf2PtEZris", "Shaky | Marathi Song")
        let hindi = djSong("hindi000001", "Hindi Pop | Official Song")
        let english = djSong("pop00000001", "English Pop | Official Song")
        let catalog = RoomDJCatalog(search: { _ in [marathi, hindi, english] }, mix: { _ in [marathi, hindi, english] },
                                    metadata: { $0 == seed.id ? .init(language: "Marathi", music: true) : nil })
        let station = RoomDJStation(source: catalog)
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RoomViewingSession(playback: ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) }), djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("language from the song’s watch page") { station.effectiveLanguage == "Marathi" }
        station.submit("more Hindi pop songs")
        try await djWait("an explicitly Hindi direction") { station.effectiveLanguage == "Hindi" && !station.isLoading }
        station.playNow(seed)
        XCTAssertEqual(station.effectiveLanguage, "Marathi")
        XCTAssertNil(station.language)

        station.submit("upbeat pop")
        try await djWait("the broad direction to refill after playback starts") {
            station.direction == "upbeat pop" && station.upcoming.count >= 2 && !station.isLoading
        }
        XCTAssertNil(station.effectiveLanguage)
        XCTAssertFalse(station.upcoming.contains { $0.id == marathi.id })
        XCTAssertTrue(station.upcoming.contains { $0.id == hindi.id })
        XCTAssertTrue(station.upcoming.contains { $0.id == english.id })
        station.setLanguage("English")
        station.playNow(seed)
        XCTAssertEqual(station.effectiveLanguage, "English")
    }
}

extension ChannelPlaybackTests {
    func testDJAutomaticTransitionsPreserveQueueOrderAndReuseOneCatalogBatch() async throws {
        let seed = djSong("seed", "Seed")
        let songs = (1...6).map { djSong("song-\($0)", "Song \($0)") }
        let calls = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in
            _ = await calls.count()
            return songs
        })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("the first catalog batch") { !station.upcoming.isEmpty }
        XCTAssertEqual(station.upcoming.map(\.id), ["song-1", "song-2"])
        let tails = [["song-2", "song-3", "song-4"], ["song-3", "song-4"], ["song-4", "song-5", "song-6"]]
        for (i, queue) in tails.enumerated() {
            let item = try XCTUnwrap(playback.player.currentItem)
            item.forwardPlaybackEndTime = playback.player.currentTime() + CMTime(seconds: 0.3, preferredTimescale: 600)
            try await djWait("the next recording to start and request its top-up") {
                session.video?.id == songs[i].id && session.canFillDJQueue && !station.isLoading
            }
            for _ in 0..<8 { station.fillIfLow() }
            XCTAssertEqual(station.upcoming.map(\.id), queue)
        }
        let requestCount = await calls.calls
        XCTAssertEqual(requestCount, 1)
    }

    func testSystemNextAdvancesTheActiveQueueInFullAndMiniPlayers() async throws {
        let file = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let songs = ["First", "Second", "Third"].map { djSong($0, $0) }
        let session = RoomViewingSession(playback: ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: file) }))
        defer { session.close() }
        XCTAssertEqual(session.handleSystemNext(), .noActionableNowPlayingItem)
        session.openPlaylist(songs[0], in: songs)
        try await djWait("the first item to start") { session.playback.player.timeControlStatus == .playing }
        XCTAssertEqual(session.handleSystemNext(), .success)
        XCTAssertEqual(session.video?.id, songs[1].id)
        try await djWait("the second item to start") { session.playback.phase == .playing }
        session.minimize()
        XCTAssertEqual(session.presentation, .mini)
        let result = await Task.detached { session.handleSystemNext() }.value
        XCTAssertEqual(result, .success)
        XCTAssertEqual(session.video?.id, songs[2].id)
        XCTAssertEqual(session.handleSystemNext(), .noSuchContent)
        session.close()
        XCTAssertEqual(session.handleSystemNext(), .noActionableNowPlayingItem)
    }

    func testNaturalHandoffDismissesPreviewAndReleaseCannotSeekTheNextSong() async throws {
        let file = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let image = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: file) })
        playback.scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in image })
        let first = djSong("preview-first", "First")
        let second = djSong("preview-next", "Second")
        let session = RoomViewingSession(playback: playback)
        defer { session.close() }
        session.openPlaylist(first, in: [first, second])
        try await djWait("the current song and its prepared successor") {
            playback.player.currentTime().seconds > 0.05 && playback.incomingPlayer?.currentItem?.status == .readyToPlay
        }
        let original = try XCTUnwrap(playback.player.currentItem)
        var insetVisible = false
        XCTAssertTrue(playback.scanner.begin(on: playback.player) { insetVisible = $0 != nil })
        playback.scanner.move(by: 4)
        try await djWait("the inset to display a future frame") { insetVisible }
        original.forwardPlaybackEndTime = playback.player.currentTime() + CMTime(seconds: 0.4, preferredTimescale: 600)
        try await djWait("the next song to start naturally") { session.video?.id == second.id && playback.player.currentItem !== original }
        XCTAssertFalse(insetVisible)
        XCTAssertFalse(playback.scanner.busy)
        playback.scanner.finish()
        XCTAssertLessThan(playback.player.currentTime().seconds, 2)
    }

    func testDJStoredRadioResultsAvoidAdditionalProviderPagesAcrossNineHandoffs() async throws {
        let seed = djSong("radiostart1", "Seed | Marathi Song")
        let songs = (1...12).map {
            djSong(String(format: "radio%06d", $0), "Recording \($0) | Marathi Song", artist: "Singer \($0)")
        }
        let pages = DJRequestGate()
        let catalog = RoomDJCatalog(search: { _ in _ = await pages.count(); return [] }, mix: { _ in
            _ = await pages.count()
            return songs
        }, metadata: { _ in XCTFail("These recordings already have language and music evidence"); return nil })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        try await djWait("the first radio page") { !station.upcoming.isEmpty }
        var played = Set<String>()
        for _ in 0..<9 {
            let nextID = try XCTUnwrap(session.next?.id)
            XCTAssertTrue(played.insert(nextID).inserted)
            session.advance()
            try await djWait("the next radio recording") {
                session.video?.id == nextID && session.canFillDJQueue && !station.isLoading
            }
        }
        XCTAssertEqual(played.count, 9)
        XCTAssertEqual(station.upcoming.count, 3)
        let pageRequests = await pages.calls
        XCTAssertEqual(pageRequests, 1)
    }

    func testDJEmptyAndFailedRefillsStayIdleAndOnlyTheFailureOffersOneManualRetry() async throws {
        let seed = djSong("seed", "Seed")
        let songs = (1...4).map { djSong("pick-\($0)", "Recovered song \($0)") }
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        for fails in [false, true] {
            let calls = DJRequestGate()
            let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in
                if await calls.count() > 1 { return songs }
                if fails { throw URLError(.timedOut) }
                return []
            })
            let station = RoomDJStation(source: catalog)
            let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
            let session = RoomViewingSession(playback: playback, djStation: station)
            defer { session.close() }
            station.playNow(seed)
            try await djWait("the provider response") { station.message != nil }
            XCTAssertEqual(station.canRetryRefill, fails)
            for _ in 0..<4 {
                station.fillIfLow()
                try await Task.sleep(for: .milliseconds(30))
            }
            let item = try XCTUnwrap(playback.player.currentItem)
            item.forwardPlaybackEndTime = playback.player.currentTime() + CMTime(seconds: 0.2, preferredTimescale: 600)
            try await djWait("the recording to finish") { playback.phase == .finished && !station.isLoading }
            let count = await calls.calls
            XCTAssertEqual(count, 1)
            XCTAssertTrue(station.upcoming.isEmpty)
            station.retry()
            if fails {
                try await djWait("the recovered queue to resume playback") {
                    session.video?.id == "pick-1" && session.canFillDJQueue && !station.isLoading
                }
                XCTAssertEqual(station.upcoming.map(\.id), ["pick-2", "pick-3", "pick-4"])
            } else {
                XCTAssertFalse(station.isLoading)
            }
            XCTAssertFalse(station.canRetryRefill)
            let afterRetry = await calls.calls
            XCTAssertEqual(afterRetry, fails ? 2 : 1)
        }
    }
}

extension ChannelPlaybackTests {
    func testDJManualEditsKeepThePlayingItemAndEveryOtherSongInOrder() async throws {
        let seed = djSong("seed", "Playing")
        let first = djSong("first", "First suggestion")
        let second = djSong("second", "Second suggestion")
        let pick = djSong("pick", "Play next")
        let tail = djSong("tail", "Play last")
        let calls = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in
            _ = await calls.count()
            return [first, second]
        })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }

        station.playNow(seed)
        try await djWait("both DJ suggestions") { station.upcoming.map(\.id) == ["first", "second"] }
        let original = try XCTUnwrap(playback.player.currentItem)
        station.enqueue(pick, at: .next)
        XCTAssertEqual(station.upcoming.map(\.id), ["pick", "first", "second"])
        station.enqueue(tail, at: .end)
        station.enqueue(tail, at: .end)
        XCTAssertEqual(station.upcoming.map(\.id), ["pick", "first", "second", "tail"])
        station.enqueue(second, at: .next)
        XCTAssertEqual(station.upcoming.map(\.id), ["second", "pick", "first", "tail"])
        station.enqueue(pick, at: .end)
        XCTAssertEqual(station.upcoming.map(\.id), ["second", "first", "tail", "pick"])
        station.removeUpcoming(first)
        station.enqueue(seed, at: .next)
        XCTAssertEqual(station.upcoming.map(\.id), ["second", "tail", "pick"])
        XCTAssertNil(station.feedback(for: first))
        let requests = await calls.calls
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(station.direction, seed.title)
        XCTAssertTrue(original === playback.player.currentItem)
        XCTAssertEqual(session.video?.id, seed.id)
    }

    func testDJQueueRemovalsExcludeLateResultsAndStoredCandidatesWithoutDislikingThem() async throws {
        let seed = djSong("seed", "Seed")
        let request = djSong("request", "Requested next")
        let head = djSong("head", "First quick pick")
        let middle = djSong("middle", "Second quick pick")
        let keep = djSong("keep", "Third quick pick")
        let picks = (1...5).map { djSong("pick-\($0)", "Song \($0)") }
        let gate = DJRequestGate()
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in
            if await gate.count() == 1 { await gate.suspend() }
            return [head, middle, request] + picks
        })
        let suite = "edited-dj-queue-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoomPlaylistStore(defaults: defaults)
        let station = RoomDJStation(source: catalog, defaults: defaults)
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        station.playNow(seed)
        station.steer(toward: request)
        try await djWait("the catalog refill to start") { await gate.waiting }
        let original = try XCTUnwrap(playback.player.currentItem)
        for song in [head, middle, keep] { session.addToQuickPlaylist(song, seconds: nil, store: store) }
        XCTAssertEqual(station.upcoming.map(\.id), ["head", "middle", "keep", "request"])
        for song in [middle, request] { station.removeUpcoming(song) }
        XCTAssertNil(station.requestedNext)
        XCTAssertEqual(station.upcoming.map(\.id), ["head", "keep"])
        await gate.release()
        try await djWait("the stale provider response") { !station.isLoading }
        XCTAssertEqual(station.upcoming.map(\.id), ["head", "keep"])
        station.removeUpcoming(head)
        XCTAssertEqual(station.upcoming.map(\.id), ["keep"])
        station.fillIfLow()
        XCTAssertEqual(station.upcoming.map(\.id), ["keep", "pick-1", "pick-2"])
        session.addToQuickPlaylist(picks[2], seconds: nil, store: store)
        XCTAssertEqual(station.upcoming.map(\.id), ["keep", "pick-3", "pick-1", "pick-2"])
        station.removeUpcoming(picks[2])
        XCTAssertTrue(original === playback.player.currentItem)
        for song in [middle, request, head, picks[2]] { XCTAssertNil(station.feedback(for: song)) }
        session.advance()
        try await djWait("the first surviving quick pick") { session.video?.id == "keep" && session.canFillDJQueue }
        session.advance()
        try await djWait("the next top-up from the stored songs") { session.video?.id == "pick-1" && session.canFillDJQueue }
        XCTAssertEqual(station.upcoming.map(\.id), ["pick-2", "pick-4", "pick-5"])
        let count = await gate.calls
        XCTAssertEqual(count, 1)
        session.close()
        station.playNow(seed)
        try await djWait("a new station to allow previously removed songs") { session.next?.id == head.id }
    }

    func testDJRemovingAFadingHeadRestoresTheCurrentItemAndAdvancesToTheSurvivor() async throws {
        let seed = djSong("seed", "Seed")
        let head = djSong("head", "Fading track")
        let next = djSong("next", "Next remaining track")
        let catalog = DJFixtureCatalog(searchResults: { _ in [] }, recommendations: { _, _ in [head, next] })
        let url = try djAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = ChannelPlayback(itemResolver: { _ in AVPlayerItem(url: url) })
        playback.configureOverlap(seconds: 2)
        let station = RoomDJStation(source: catalog)
        let session = RoomViewingSession(playback: playback, djStation: station)
        defer { session.close() }
        var started = [String]()
        session.onVideoStarted = { started.append($0.id) }
        station.playNow(seed)
        try await djWait("both recordings to be ready") { playback.incomingPlayer?.currentItem?.status == .readyToPlay }
        let player = playback.player
        let item = try XCTUnwrap(player.currentItem)
        let incoming = try XCTUnwrap(playback.incomingPlayer)
        item.forwardPlaybackEndTime = player.currentTime() + CMTime(seconds: 0.8, preferredTimescale: 600)
        try await djWait("the outgoing and incoming recordings to overlap") { incoming.rate > 0 && player.volume < 1 }
        station.removeUpcoming(head)
        XCTAssertTrue(playback.player === player)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.volume, 1, accuracy: 0.01)
        XCTAssertNil(incoming.currentItem)
        XCTAssertEqual(session.next?.id, next.id)
        try await djWait("a natural handoff to the surviving queue head") { started.count == 2 }
        station.removeUpcoming(next) // A late press from the old queue row.
        XCTAssertEqual(session.video?.id, next.id)
        XCTAssertEqual(started, [seed.id, next.id])
        XCTAssertFalse(station.upcoming.contains { $0.id == head.id })
    }
}
