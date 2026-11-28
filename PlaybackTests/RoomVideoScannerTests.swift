import AVFoundation
import CoreGraphics
import os
import XCTest
@testable import freeTube

@MainActor
final class RoomVideoScannerTests: XCTestCase {
    func testPausedPreviewOnlySeeksOnReleaseAndKeepsMuteAndPause() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        player.pause()
        player.isMuted = true
        let origin = player.currentTime().seconds
        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in image })
        var frame: RoomVideoScanner.Preview?
        XCTAssertTrue(scanner.begin(on: player) { frame = $0 })
        scanner.move(by: 8)
        try await wait { frame != nil }
        scanner.move(by: 7)
        try await wait { (frame?.time ?? 0) >= origin + 14.9 }
        XCTAssertEqual(player.currentTime().seconds, origin, accuracy: 0.1)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(player.isMuted)
        scanner.finish()
        try await wait { abs(player.currentTime().seconds - origin - 15) < 0.2 }
        XCTAssertNil(frame)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(player.isMuted)
    }

    func testPlayingPreviewUpdatesFramesThenMakesOneSeek() async throws {
        let (player, file) = try await localPlayer(makeItem: { SeekCountingItem(url: $0) })
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        try await wait { player.currentTime().seconds > 0.1 }
        let item = try XCTUnwrap(player.currentItem as? SeekCountingItem)
        let initialCount = item.seekCount
        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in image })
        var times: [Double] = []
        XCTAssertTrue(scanner.begin(on: player) { if let frame = $0 { times.append(frame.time) } })
        scanner.move(by: 7)
        try await wait { !times.isEmpty }
        scanner.move(by: 8)
        try await wait { times.count == 2 }
        XCTAssertEqual(item.seekCount - initialCount, 0)
        XCTAssertLessThan(player.currentTime().seconds, 2)
        XCTAssertFalse(player.isMuted)
        scanner.finish()
        try await wait { player.currentTime().seconds > 14 }
        XCTAssertEqual(item.seekCount - initialCount, 1)
        XCTAssertEqual(player.currentTime().seconds, try XCTUnwrap(times.last), accuracy: 0.3)
        XCTAssertEqual(player.rate, 1.25, accuracy: 0.01)
        XCTAssertFalse(player.isMuted)
    }

    func testPlayingPreviewKeepsAudioAndTransportAndCancelsWithoutSeeking() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in image })
        var displayed = false
        let start = player.currentTime().seconds
        XCTAssertTrue(scanner.begin(on: player) { displayed = $0 != nil })
        scanner.move(by: 20)
        try await wait { displayed && player.currentTime().seconds > start + 0.1 }
        XCTAssertEqual(player.rate, 1.25, accuracy: 0.01)
        XCTAssertFalse(player.isMuted)
        scanner.stop()
        XCTAssertFalse(displayed)
        XCTAssertLessThan(player.currentTime().seconds - start, 1.5)
        XCTAssertEqual(player.rate, 1.25, accuracy: 0.01)
    }

    func testUnavailableFramesAndReplacementNeverSeekTheMainPlayer() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        let unavailable = RoomVideoScanner(canPreview: { _ in false }, image: { _, _ in nil })
        XCTAssertFalse(unavailable.begin(on: player) { _ in XCTFail("No preview source") })
        let missing = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in nil })
        XCTAssertTrue(missing.begin(on: player) { XCTAssertNil($0) })
        missing.move(by: 15)
        try await wait { !missing.busy }
        missing.finish()
        XCTAssertFalse(missing.canBegin(on: player))
        XCTAssertLessThan(player.currentTime().seconds, 1.5)

        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in image })
        var frame: RoomVideoScanner.Preview?
        XCTAssertTrue(scanner.begin(on: player) { frame = $0 })
        scanner.move(by: 12)
        try await wait { frame != nil }
        player.replaceCurrentItem(with: AVPlayerItem(url: file))
        scanner.finish()
        XCTAssertNil(frame)
        XCTAssertLessThan(player.currentTime().seconds, 1.5)
    }

    func testReleaseCommitsTheDisplayedFrameWhenANewerFrameIsPending() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        player.pause()
        let origin = player.currentTime().seconds
        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, seconds in
            if seconds > 15 { try? await Task.sleep(for: .seconds(1)) }
            return image
        })
        var frame: RoomVideoScanner.Preview?
        XCTAssertTrue(scanner.begin(on: player) { frame = $0 })
        scanner.move(by: 10)
        try await wait { frame != nil }
        scanner.move(by: 10)
        scanner.finish()
        try await wait { abs(player.currentTime().seconds - origin - 10) < 0.2 }
        XCTAssertNil(frame)
        XCTAssertEqual(player.rate, 0)
    }

    func testBriefFirstSwipeDisplaysItsColdImageThenSeeksOnce() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        player.pause()
        let origin = player.currentTime().seconds
        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in
            try? await Task.sleep(for: .milliseconds(120))
            return image
        })
        var shown: Double?
        XCTAssertTrue(scanner.begin(on: player) { if let frame = $0 { shown = frame.time } })
        scanner.move(by: 8)
        scanner.finish()
        XCTAssertEqual(player.currentTime().seconds, origin, accuracy: 0.1)
        try await wait { shown != nil }
        XCTAssertEqual(player.currentTime().seconds, origin, accuracy: 0.1)
        try await wait { abs(player.currentTime().seconds - origin - 8) < 0.15 }
        XCTAssertEqual(player.rate, 0)
    }

    func testCancellingAColdReleaseDiscardsItsLateImage() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        player.pause()
        let origin = player.currentTime().seconds
        let image = try testImage()
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in
            try? await Task.sleep(for: .milliseconds(120))
            return image
        })
        var showed = false
        XCTAssertTrue(scanner.begin(on: player) { if $0 != nil { showed = true } })
        scanner.move(by: 15)
        scanner.finish()
        scanner.cancelPendingRelease()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(showed)
        XCTAssertEqual(player.currentTime().seconds, origin, accuracy: 0.1)
    }

    func testSlowColdReleaseExpiresWithoutASeek() async throws {
        let (player, file) = try await localPlayer()
        defer { player.pause(); try? FileManager.default.removeItem(at: file) }
        player.pause()
        let origin = player.currentTime().seconds
        let scanner = RoomVideoScanner(canPreview: { _ in true }, image: { _, _ in
            try? await Task.sleep(for: .seconds(3))
            return nil
        })
        XCTAssertTrue(scanner.begin(on: player) { XCTAssertNil($0) })
        scanner.move(by: 15)
        scanner.finish()
        try await wait { !scanner.busy }
        XCTAssertEqual(player.currentTime().seconds, origin, accuracy: 0.1)
    }

    private func testImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func localPlayer(makeItem: (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) }) async throws -> (AVPlayer, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let count: AVAudioFrameCount = 240_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(count))
        try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        let player = AVPlayer(playerItem: makeItem(file))
        player.defaultRate = 1.25
        player.playImmediately(atRate: 1.25)
        try await wait { player.currentItem?.status == .readyToPlay && player.rate > 0 && !(player.currentItem?.seekableTimeRanges.isEmpty ?? true) }
        return (player, file)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition())
    }
}

private final class SeekCountingItem: AVPlayerItem, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var seekCount: Int { calls.withLock { $0 } }

    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: (@Sendable (Bool) -> Void)?) {
        calls.withLock { $0 += 1 }
        super.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter, completionHandler: completionHandler)
    }
}
