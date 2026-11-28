import AVFoundation
import ImageIO
import XCTest
@testable import freeTube

@MainActor
final class RoomScrubFramesTests: XCTestCase {
    private let base = "https://i.ytimg.com/sb/fixture/storyboard3_L$L/$N.jpg?sqp=a%2Bb"
    private let level = "2#1#6#2#2#1000#M$M#rs$fixture"
    private func item() -> AVPlayerItem {
        AVPlayerItem(url: URL(string: "https://example.invalid/video.m3u8")!)
    }

    func testTimedLevelUsesOriginalOrdinalQueryAndPartialLastSheet() throws {
        let spec = base + "|48#27#100#10#10#0#default#old|80#45#128#10#10#5000#M$M#low|160#90#128#5#5#5000#M$M#rs$test|320#180#128#3#3#5000#M$M#higher"
        let board = try XCTUnwrap(RoomStoryboard(spec: spec))
        let tile = try XCTUnwrap(board.tile(at: 30, duration: 633))
        XCTAssertEqual(tile.url.path, "/sb/fixture/storyboard3_L2/M0.jpg")
        let query = URLComponents(url: tile.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "sqp" }?.value, "a+b")
        XCTAssertEqual(query?.first { $0.name == "sigh" }?.value, "rs$test")
        XCTAssertEqual(tile.rect, CGRect(x: 160, y: 90, width: 160, height: 90))
        XCTAssertEqual(board.tile(at: 124.999, duration: 633)?.rect, CGRect(x: 640, y: 360, width: 160, height: 90))
        XCTAssertEqual(board.tile(at: 125, duration: 633)?.url.lastPathComponent, "M1.jpg")
        let last = try XCTUnwrap(board.tile(at: 900, duration: 633))
        XCTAssertEqual(last.url.lastPathComponent, "M5.jpg")
        XCTAssertEqual(last.rect, CGRect(x: 320, y: 0, width: 160, height: 90))
    }

    func testMalformedOrExternalSheetsAreRejectedAndDefaultLevelCanUseDuration() throws {
        XCTAssertNil(RoomStoryboard(spec: "https://i.ytimg.com.evil.invalid/sb/id/$N.jpg|" + level))
        XCTAssertNil(RoomStoryboard(spec: base + "|160#90#5#0#1#1000#M$M#x"))
        XCTAssertNil(RoomStoryboard(spec: base + "|160#90#999999999999999999999#2#2#1000#M$M#x"))
        let fixed = try XCTUnwrap(RoomStoryboard(spec: base + "|2#1#4#2#2#0#default#x"))
        XCTAssertEqual(fixed.tile(at: 5, duration: 10)?.rect, CGRect(x: 0, y: 1, width: 2, height: 1))
        XCTAssertNil(fixed.tile(at: 5, duration: .nan))
        XCTAssertNil(fixed.tile(at: .nan, duration: 10))
    }

    func testConcurrentTilesShareOneSheetAndCancelledReaderCannotPublish() async throws {
        let sheet = try makeSheet()
        let gate = SheetFixture(bytes: sheet)
        let frames = RoomScrubFrames(loadSheet: { await gate.load($0) })
        let item = item()
        frames.register(item, storyboardSpec: base + "|" + level)
        XCTAssertTrue(frames.canPreview(item))
        let stale = Task { await frames.image(for: item, at: 0) }
        while await gate.count == 0 { await Task.yield() }
        let lower = Task { await frames.image(for: item, at: 2) }
        stale.cancel()
        await gate.release()
        let staleResult = await stale.value
        XCTAssertNil(staleResult)
        let first = await lower.value
        let second = await frames.image(for: item, at: 1)
        let repeated = await frames.image(for: item, at: 2.4)
        let blue = try pixel(XCTUnwrap(first))
        XCTAssertEqual(blue, [0, 0, 255])
        XCTAssertEqual(try pixel(XCTUnwrap(second)), [0, 255, 0])
        XCTAssertEqual(try pixel(XCTUnwrap(repeated)), blue)
        let count = await gate.count
        XCTAssertEqual(count, 1)
    }

    func testReplacingRegistrationDropsAStaleSheetAndFailedSourceIsNotRetried() async throws {
        let gate = SheetFixture(bytes: try makeSheet())
        let frames = RoomScrubFrames(loadSheet: { await gate.load($0) })
        let item = item()
        frames.register(item, storyboardSpec: base + "|" + level)
        let stale = Task { await frames.image(for: item, at: 0) }
        while await gate.count == 0 { await Task.yield() }
        frames.register(item, storyboardSpec: nil)
        await gate.release()
        let result = await stale.value
        XCTAssertNil(result)
        XCTAssertFalse(frames.canPreview(item))
        let bad = SheetFixture(bytes: Data())
        await bad.release()
        let failing = RoomScrubFrames(loadSheet: { await bad.load($0) })
        failing.register(item, storyboardSpec: base + "|" + level)
        let failed = await failing.image(for: item, at: 1)
        XCTAssertNil(failed)
        XCTAssertFalse(failing.canPreview(item))
        let again = await failing.image(for: item, at: 5)
        XCTAssertNil(again)
        let count = await bad.count
        XCTAssertEqual(count, 1)
    }

    func testAvailableMP4FrameFallbackUsesTheExistingItemsAsset() async throws {
        // Three 32×32 H.264 keyframes at 1 fps (blue, red, red), independent of a device encoder.
        let movie = try XCTUnwrap(Data(base64Encoded: """
            AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMcbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAC7gA
            AQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAgAAAkd0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAC7gAAAAAAAAAAAAAAAAAAAAAAAEA
            AAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAu4
            AAAAAAABAAAAAAG/bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAwABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUA
            AAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABam1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYA
            AAAAAAAAAQAAAAx1cmwgAAAAAQAAASpzdGJsAAAAunN0c2QAAAAAAAAAAQAAAKphdmMxAAAAAAAAAAEAAAAAAAAAAAAA
            AAAAAAAAACAAIABIAAAASAAAAAAAAAABFUxhdmM2Mi4xMS4xMDAgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAAMGF2Y0MB
            ZBAK/+EAFGdkEAqsuS2AiAAAAwAIAAADABAgAQAFaO4PLIv9+PgAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAA
            APUAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAMAAEAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAADAAAAAQAAACBzdHN6AAAA
            AAAAAAAAAAADAAAAHgAAAB8AAAAfAAAAFHN0Y28AAAAAAAAAAQAAA0wAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxy
            AAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYyLjMuMTAw
            AAAACGZyZWUAAABkbWRhdAAAABpliIQEv/7oyfzLLXnmdRqJlloPlacbsHAv4QAAABtliIIBf/7ugr4FNs0QPwcsKsvJ
            +Zz45PXEf8AAAAAbZYiEBf/+7oK+BTbNED8HLCrLyfmc+OT1xH/B
            """, options: .ignoreUnknownCharacters))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try movie.write(to: file)
        let frames = RoomScrubFrames(loadSheet: { _ in XCTFail("A local movie needs no sheet"); return Data() })
        let item = AVPlayerItem(url: file)
        XCTAssertTrue(frames.canPreview(item))
        let blueFrame = await frames.image(for: item, at: 0)
        let redFrame = await frames.image(for: item, at: 1.1)
        let blue = try pixel(XCTUnwrap(blueFrame)), red = try pixel(XCTUnwrap(redFrame))
        XCTAssertGreaterThan(Int(blue[2]) - Int(blue[0]), 180)
        XCTAssertGreaterThan(Int(red[0]) - Int(red[2]), 180)
    }

    private func makeSheet() throws -> Data {
        let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255], white: [UInt8] = [255, 255, 255, 255]
        let bytes = Data(red + red + green + green + blue + blue + white + white)
        let source = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: source, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return png as Data
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [bytes[0], bytes[1], bytes[2]]
    }
}

private actor SheetFixture {
    let bytes: Data
    private(set) var count = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false
    init(bytes: Data) { self.bytes = bytes }
    func load(_ url: URL) async -> Data {
        count += 1
        if !open { await withCheckedContinuation { waiting = $0 } }
        return bytes
    }
    func release() { open = true; waiting?.resume(); waiting = nil }
}
