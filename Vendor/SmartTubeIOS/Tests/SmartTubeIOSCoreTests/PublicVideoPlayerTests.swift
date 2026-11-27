import Foundation
import Testing
@testable import SmartTubeIOSCore

private let videoID = "selected-id"
private let channelID = "selected-channel"
private let hls = "https://manifest.googlevideo.com/master.m3u8?token=abc%2Bdef"
private let video = "https://example.googlevideo.com/video"
private let audio = "https://example.googlevideo.com/audio"

private func result(_ streams: String, channel: String = channelID, status: String = "OK") throws -> PublicVideoStream {
    let page = #"<script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"\#(status)","reason":"Restricted"},"videoDetails":{"videoId":"\#(videoID)","channelId":"\#(channel)","title":"A } \"quoted\" title"},"streamingData":{\#(streams)}}; other();</script>"#
    return try PublicVideoPlayer.stream(in: Data(page.utf8), videoID: videoID, channelID: channelID)
}

@Test func prefersPublisherHLS() throws {
    #expect(try result(#""hlsManifestUrl":"\#(hls)","formats":[]"#) == .single(URL(string: hls)!))
}

@Test func playsMuxedMP4() throws {
    #expect(try result(#""formats":[{"url":"\#(video)","mimeType":"video/mp4; codecs=\"avc1, mp4a\""}]"#) == .single(URL(string: video)!))
}

@Test func selectsSeparateNativeAudioAndVideo() throws {
    #expect(try result(#""adaptiveFormats":[{"url":"\#(video)","mimeType":"video/mp4; codecs=avc1"},{"url":"\#(audio)","mimeType":"audio/mp4"}]"#) == .separate(video: URL(string: video)!, audio: URL(string: audio)!))
}

@Test func rejectsUnrelatedChannelsAndRestrictions() {
    #expect(throws: PublicPlayerError.differentVideo) { try result("", channel: "other") }
    #expect(throws: PublicPlayerError.restricted("Restricted")) { try result("", status: "LOGIN_REQUIRED") }
}

@Test func rejectsUnsupportedOrExternalSources() {
    #expect(throws: PublicPlayerError.unsupported) { try result(#""hlsManifestUrl":"https://fakegooglevideo.com/other""#) }
    #expect(throws: PublicPlayerError.unsupported) { try result(#""serverAbrStreamingUrl":"\#(video)""#) }
}

private class PublicPlayerFixture: URLProtocol, @unchecked Sendable {
    class var nativeResponse: String {
        #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"selected-id","channelId":"selected-channel"},"streamingData":{"hlsManifestUrl":"\#(hls)"}}"#
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body: String
        if url.path == "/watch" {
            body = #"<script>ytcfg.set({"VISITOR_DATA":"issued-visitor"});var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"selected-id","channelId":"selected-channel"},"streamingData":{"serverAbrStreamingUrl":"https://example.googlevideo.com/abr"}};</script>"#
        } else {
            guard url.host == "www.youtube.com", url.path == "/youtubei/v1/player",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == "issued-visitor",
                  request.value(forHTTPHeaderField: "Authorization") == nil else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            body = Self.nativeResponse
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RestrictedPlayerFixture: PublicPlayerFixture, @unchecked Sendable {
    override class var nativeResponse: String {
        #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to watch"}}"#
    }
}

private func resolve(using fixture: PublicPlayerFixture.Type) async throws -> PublicVideoStream {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [fixture]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try await PublicVideoPlayer(session: session).stream(videoID: videoID, channelID: channelID)
}

@Test func resolvesNativePlaylistForPublicWatchPageWithoutMediaURLs() async throws {
    #expect(try await resolve(using: PublicPlayerFixture.self) == .single(URL(string: hls)!))
}

@Test func preservesRestrictionFromPlaylistRequest() async {
    await #expect(throws: PublicPlayerError.restricted("Sign in to watch")) {
        try await resolve(using: RestrictedPlayerFixture.self)
    }
}
