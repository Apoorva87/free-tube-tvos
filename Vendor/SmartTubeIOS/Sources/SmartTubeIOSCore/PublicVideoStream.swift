// Adapted from SmartTubeIOSCore PlayerInfo's HLS, muxed MP4 and adaptive stream selection.
// Native playlist negotiation follows AuTube’s HLS playback approach.
import Foundation

public enum PublicVideoStream: Equatable, Sendable {
    case single(URL)
    case separate(video: URL, audio: URL)
}

public struct PublicPlaybackMedia: Sendable {
    public let stream: PublicVideoStream
    public let storyboardSpec: String?
}

public enum PublicPlayerError: LocalizedError, Equatable {
    case restricted(String)
    case unavailable
    case differentVideo
    case unsupported
    case badResponse(Int)
    case rateLimited(retryAfter: String?)

    public var errorDescription: String? {
        switch self {
        case .restricted(let reason): reason
        case .unavailable: "YouTube did not return player details for this video."
        case .differentVideo: "The returned video does not match your channel selection."
        case .unsupported: "YouTube did not offer a stream this Apple TV can play directly."
        case .rateLimited: "YouTube is limiting playback requests. Try again later."
        case .badResponse(let status): "YouTube returned HTTP \(status) for this video."
        }
    }
}

public struct PublicVideoPlayer: Sendable {
    private static let userAgent = "freeTube/0.1 (Apple TV; native HLS player)"
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config)
    }

    public func stream(videoID: String, channelID: String) async throws -> PublicVideoStream {
        try await media(videoID: videoID, channelID: channelID).stream
    }

    public func media(videoID: String, channelID: String) async throws -> PublicPlaybackMedia {
        var page = URLComponents()
        page.scheme = "https"
        page.host = "www.youtube.com"
        page.path = "/watch"
        page.queryItems = [URLQueryItem(name: "v", value: videoID)]
        guard let url = page.url else { throw PublicPlayerError.unavailable }
        var pageRequest = URLRequest(url: url)
        pageRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let html = String(decoding: try await data(for: pageRequest), as: UTF8.self)
        let watch = try Self.readPlayer(in: html)
        try watch.validate(videoID: videoID, channelID: channelID)
        let watchBoard = watch.storyboards?.spec
        if let hls = watch.hls { return PublicPlaybackMedia(stream: .single(hls), storyboardSpec: watchBoard) }

        // The watch page and the native playlist request belong to the same anonymous visit.
        let visitor = watch.responseContext?.visitorData ?? Self.pageVisitor(in: html)
        let request = try Self.playlistRequest(videoID: videoID, visitor: visitor)
        let reply: Data
        do {
            reply = try await data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            try Task.checkCancellation()
            if let stream = try? watch.stream() { return PublicPlaybackMedia(stream: stream, storyboardSpec: watchBoard) }
            throw error
        } catch PublicPlayerError.badResponse(let code) where (500...599).contains(code) {
            return try PublicPlaybackMedia(stream: watch.stream(), storyboardSpec: watchBoard)
        }
        let native = try JSONDecoder().decode(PlayerResponse.self, from: reply)
        try native.validate(videoID: videoID, channelID: channelID)
        let storyboard = watchBoard ?? native.storyboards?.spec
        if let stream = try? native.stream() { return PublicPlaybackMedia(stream: stream, storyboardSpec: storyboard) }
        return try PublicPlaybackMedia(stream: watch.stream(), storyboardSpec: storyboard)
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PublicPlayerError.unavailable }
        if http.statusCode == 429 {
            throw PublicPlayerError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        guard http.statusCode == 200 else { throw PublicPlayerError.badResponse(http.statusCode) }
        return data
    }

    private static func playlistRequest(videoID: String, visitor: String?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        let version = "1.02"
        var client = ["clientName": "VISIONOS", "clientVersion": version, "hl": "en",
                      "osName": "tvOS", "deviceMake": "Apple"]
        if let visitor, !visitor.isEmpty {
            client["visitorData"] = visitor
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["videoId": videoID, "context": ["client": client]])
        return request
    }

    static func stream(in page: Data, videoID: String, channelID: String) throws -> PublicVideoStream {
        let player = try readPlayer(in: String(decoding: page, as: UTF8.self))
        try player.validate(videoID: videoID, channelID: channelID)
        return try player.stream()
    }

    private static func readPlayer(in html: String) throws -> PlayerResponse {
        let object = try embeddedJSON(in: html, pattern: #"(?:var\s+)?ytInitialPlayerResponse\s*=\s*\{"#)
        return try JSONDecoder().decode(PlayerResponse.self, from: object)
    }

    private struct PageConfig: Decodable { let VISITOR_DATA: String? }

    private static func pageVisitor(in html: String) -> String? {
        guard let object = try? embeddedJSON(in: html, pattern: #"ytcfg\.set\(\s*\{"#) else { return nil }
        return (try? JSONDecoder().decode(PageConfig.self, from: object))?.VISITOR_DATA
    }

    private static func embeddedJSON(in html: String, pattern: String) throws -> Data {
        // Page data can contain braces and escaped quotes inside strings.
        guard let marker = html.range(of: pattern, options: .regularExpression) else { throw PublicPlayerError.unavailable }
        let bytes = html[html.index(before: marker.upperBound)...].utf8
        var depth = 0
        var inString = false
        var escaped = false
        for index in bytes.indices {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 { inString = true }
            else if byte == 0x7b { depth += 1 }
            else if byte == 0x7d {
                depth -= 1
                if depth == 0 {
                    return Data(bytes[...index])
                }
            }
        }
        throw PublicPlayerError.unavailable
    }
}

private struct PlayerResponse: Decodable {
    struct Storyboards: Decodable {
        let spec: String?
        private enum Key: String, CodingKey { case playerStoryboardSpecRenderer, spec }
        init(from decoder: Decoder) {
            let renderer = try? decoder.container(keyedBy: Key.self).nestedContainer(keyedBy: Key.self, forKey: .playerStoryboardSpecRenderer)
            let value = try? renderer?.decode(String.self, forKey: .spec)
            spec = value.flatMap { !$0.isEmpty && $0.utf8.count <= 65_536 ? $0 : nil }
        }
    }
    struct Playability: Decodable { let status: String; let reason: String? }
    struct VideoDetails: Decodable { let videoId: String; let channelId: String }
    struct Streams: Decodable {
        let hlsManifestUrl: String?
        let formats: [Format]?
        let adaptiveFormats: [Format]?
    }
    struct Format: Decodable {
        let url: String?
        let mimeType: String?
        let bitrate: Int?
        let audioTrack: AudioTrack?
        struct AudioTrack: Decodable { let audioIsDefault: Bool? }
    }
    struct ResponseContext: Decodable { let visitorData: String? }
    let responseContext: ResponseContext?
    let playabilityStatus: Playability
    let videoDetails: VideoDetails?
    let streamingData: Streams?
    let storyboards: Storyboards?

    var hls: URL? { Self.mediaURL(streamingData?.hlsManifestUrl) }

    func validate(videoID: String, channelID: String) throws {
        guard playabilityStatus.status == "OK" else {
            throw PublicPlayerError.restricted(playabilityStatus.reason ?? "YouTube marked this video unavailable for public playback.")
        }
        guard videoDetails?.videoId == videoID, videoDetails?.channelId == channelID else {
            throw PublicPlayerError.differentVideo
        }
    }

    func stream() throws -> PublicVideoStream {
        guard let streams = streamingData else { throw PublicPlayerError.unsupported }
        if let hls { return .single(hls) }
        let muxed = (streams.formats ?? []).filter {
            let mime = $0.mimeType ?? ""
            return mime.hasPrefix("video/mp4") && mime.contains(",")
        }
        if let url = bestURL(muxed) { return .single(url) }
        let adaptive = streams.adaptiveFormats ?? []
        let video = adaptive.filter {
            let mime = $0.mimeType ?? ""
            return mime.hasPrefix("video/mp4") && (mime.contains("avc1") || mime.contains("hvc1") || mime.contains("hev1"))
        }
        let audio = adaptive.filter { $0.mimeType?.hasPrefix("audio/mp4") == true }
        guard let videoURL = bestURL(video),
              let audioURL = bestURL(audio.filter { $0.audioTrack?.audioIsDefault == true }) ?? bestURL(audio)
        else { throw PublicPlayerError.unsupported }
        return .separate(video: videoURL, audio: audioURL)
    }

    private func bestURL(_ formats: [Format]) -> URL? {
        formats.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.lazy.compactMap { Self.mediaURL($0.url) }.first
    }

    private static func mediaURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              ["googlevideo.com", "youtube.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        return url
    }
}
