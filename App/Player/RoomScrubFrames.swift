import AVFoundation
import ImageIO

/// A public storyboard has a URL template followed by one descriptor for each resolution.
struct RoomStoryboard {
    struct Tile {
        let url: URL
        let rect: CGRect
    }

    private let template: String
    private struct Level {
        let index, width, height, count, columns, rows, milliseconds: Int
        let name, signature: String
    }
    private let level: Level

    init?(spec: String) {
        guard spec.utf8.count <= 65_536 else { return nil }
        let parts = spec.components(separatedBy: "|")
        guard (2...17).contains(parts.count), let template = parts.first, template.contains("$N"),
              let base = URLComponents(string: template), base.scheme == "https", let host = base.host?.lowercased(),
              host.hasSuffix(".ytimg.com"), base.port == nil, base.user == nil, base.password == nil,
              base.path.hasPrefix("/sb/") else { return nil }
        let levels = parts.dropFirst().enumerated().compactMap { index, encoded -> Level? in
            let fields = encoded.components(separatedBy: "#")
            guard fields.count == 8, let width = Int(fields[0]), (1...1024).contains(width),
                  let height = Int(fields[1]), (1...768).contains(height),
                  let count = Int(fields[2]), (1...1_000_000).contains(count),
                  let columns = Int(fields[3]), (1...100).contains(columns),
                  let rows = Int(fields[4]), (1...100).contains(rows),
                  width * columns <= 4096, height * rows <= 4096,
                  width * columns * height * rows <= 8_000_000,
                  let milliseconds = Int(fields[5]), (0...86_400_000).contains(milliseconds),
                  !fields[6].isEmpty, fields[6].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "$_-".contains($0)) }),
                  count <= columns * rows || fields[6].contains("$M") || template.contains("$M") else { return nil }
            return Level(index: index, width: width, height: height, count: count, columns: columns, rows: rows,
                         milliseconds: milliseconds, name: fields[6], signature: fields[7])
        }
        // 90px artwork keeps ordinary landscape sheets near 800 × 450, including on long videos.
        let timed = levels.filter { $0.milliseconds > 0 }
        guard let level = (timed.isEmpty ? levels : timed).min(by: { abs($0.height - 90) < abs($1.height - 90) }) else { return nil }
        self.template = template
        self.level = level
    }

    func tile(at seconds: Double, duration: Double) -> Tile? {
        guard seconds.isFinite else { return nil }
        let step = level.milliseconds > 0 ? Double(level.milliseconds) / 1000 : duration / Double(level.count)
        guard step.isFinite, step > 0 else { return nil }
        let frame = Int(min(Double(level.count - 1), max(0, seconds) / step))
        let perSheet = level.columns * level.rows
        let cell = frame % perSheet
        let address = template.replacingOccurrences(of: "$L", with: String(level.index))
            .replacingOccurrences(of: "$N", with: level.name)
            .replacingOccurrences(of: "$M", with: String(frame / perSheet))
        guard var url = URLComponents(string: address) else { return nil }
        if !level.signature.isEmpty {
            var signature = URLComponents()
            signature.queryItems = [URLQueryItem(name: "sigh", value: level.signature)]
            // Preserve the provider's original encoded query, including opaque signatures.
            let query = [url.percentEncodedQuery, signature.percentEncodedQuery].compactMap { $0 }.filter { !$0.isEmpty }
            url.percentEncodedQuery = query.joined(separator: "&")
        }
        guard let location = url.url else { return nil }
        return Tile(url: location, rect: CGRect(x: (cell % level.columns) * level.width, y: (cell / level.columns) * level.height,
                                               width: level.width, height: level.height))
    }
}

@MainActor
final class RoomScrubFrames {
    typealias SheetLoader = @Sendable (URL) async throws -> Data
    private final class Source {
        let board: RoomStoryboard?
        var boardFailed = false
        var assetFailed = false
        init(_ spec: String?) { board = spec.flatMap(RoomStoryboard.init(spec:)) }
    }
    private let sources = NSMapTable<AVPlayerItem, Source>.weakToStrongObjects()
    private let sheets: RoomScrubSheets

    init(loadSheet: @escaping SheetLoader = RoomScrubSheets.download) { sheets = RoomScrubSheets(load: loadSheet) }

    func register(_ item: AVPlayerItem, storyboardSpec: String?) {
        sources.setObject(Source(storyboardSpec), forKey: item)
    }

    private func source(for item: AVPlayerItem) -> Source {
        if let source = sources.object(forKey: item) { return source }
        let source = Source(nil)
        sources.setObject(source, forKey: item)
        return source
    }

    private func canGenerate(_ item: AVPlayerItem) -> Bool {
        if item.asset is AVComposition { return true }
        guard let url = (item.asset as? AVURLAsset)?.url else { return false }
        if url.isFileURL || ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name == "mime" && $0.value?.lowercased() == "video/mp4"
        } == true
    }

    func canPreview(_ item: AVPlayerItem) -> Bool {
        let source = source(for: item)
        return (source.board != nil && !source.boardFailed) || (!source.assetFailed && canGenerate(item))
    }

    func image(for item: AVPlayerItem, at seconds: Double) async -> CGImage? {
        guard seconds.isFinite, !Task.isCancelled else { return nil }
        let source = source(for: item)
        if !source.boardFailed, let tile = source.board?.tile(at: seconds, duration: item.duration.seconds) {
            let sheet = await sheets.image(at: tile.url)
            guard !Task.isCancelled, sources.object(forKey: item) === source else { return nil }
            if let sheet, CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height).contains(tile.rect),
               let crop = sheet.cropping(to: tile.rect) { return crop }
            source.boardFailed = true
        }
        guard !source.assetFailed, canGenerate(item) else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        let cancel: @MainActor @Sendable () -> Void = { generator.cancelAllCGImageGeneration() }
        let result: CGImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, outcome, _ in
                    continuation.resume(returning: outcome == .succeeded ? image : nil)
                }
            }
        } onCancel: { Task { @MainActor in cancel() } }
        guard !Task.isCancelled, sources.object(forKey: item) === source else { return nil }
        if result == nil { source.assetFailed = true }
        return result
    }
}

/// Serialize misses and retain two decoded sheets. A cancelled swipe can share its download with the next target.
private actor RoomScrubSheets {
    private struct Request {
        let id = UUID()
        let url: URL
        let task: Task<CGImage?, Never>
    }
    private let load: RoomScrubFrames.SheetLoader
    private var recent: [(url: URL, image: CGImage?)] = []
    private var pending: Request?
    private var lastStart: ContinuousClock.Instant?
    init(load: @escaping RoomScrubFrames.SheetLoader) { self.load = load }

    func image(at url: URL) async -> CGImage? {
        while !Task.isCancelled {
            if let index = recent.firstIndex(where: { $0.url == url }) {
                let hit = recent.remove(at: index)
                recent.append(hit)
                return hit.image
            }
            let request: Request
            if let pending { request = pending }
            else {
                let task = Task { () -> CGImage? in
                    if let lastStart { try? await ContinuousClock().sleep(until: lastStart + .milliseconds(700)) }
                    lastStart = .now
                    guard let data = try? await load(url), data.count <= 4_194_304,
                          let image = CGImageSourceCreateWithData(data as CFData, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let width = props[kCGImagePropertyPixelWidth] as? Int, (1...4096).contains(width),
                          let height = props[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(height),
                          width * height <= 8_000_000 else { return nil }
                    return CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }
                request = Request(url: url, task: task)
                pending = request
            }
            let result = await request.task.value
            if pending?.id == request.id {
                pending = nil
                if recent.count == 2 { recent.removeFirst() }
                recent.append((request.url, result))
            }
            if request.url == url { return result }
        }
        return nil
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config)
    }()

    nonisolated static func download(_ url: URL) async throws -> Data {
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_194_304 else {
            throw URLError(.badServerResponse)
        }
        return try Data(contentsOf: file)
    }
}
