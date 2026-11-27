import Foundation

struct ChannelVideo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let channelID: String
    let channelTitle: String
    let thumbnail: URL?
    var publishedAt: Date = .distantPast
    var coverThumbnail: URL?
    var durationSeconds: Int? = nil
    var uploadPosition: Int? = nil

    static func chronological(_ videos: [Self], followed: Set<String>) -> [Self] {
        var seen = Set<String>()
        return videos.filter { followed.contains($0.channelID) }.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            return ($0.uploadPosition ?? .max, $0.id) < ($1.uploadPosition ?? .max, $1.id)
        }.filter { seen.insert($0.id).inserted }
    }
}

struct RoomChannel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    var thumbnail: URL?
    var uploadsID: String?
    var topics: [String]?
    var handle: String?
}

struct SubscriptionInventory: Sendable {
    var channels = [RoomChannel]()
    var reportedTotal: Int?
    var received = 0
    var pages = 0
}

struct CatalogPage: Sendable {
    var channels: [RoomChannel] = []
    var videos: [ChannelVideo] = []
    var next: String?
}

struct RoomVideoFacts: Sendable {
    let duration: String?
    let views: UInt64?
    let live: Bool
    let short: Bool

    static func creatorTaggedShort(title: String?, tags: [String]?, duration: String?) -> Bool {
        guard let duration else { return false }
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] * 60 + parts[1] <= 180 else { return false }
        let tagged = tags?.contains { ["shorts", "ytshorts", "youtubeshorts"].contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))) } == true
        return tagged || title?.range(of: "#(?:shorts|ytshorts|youtubeshorts)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func clock(_ duration: String?) -> String? {
        guard let duration, let time = duration.wholeMatch(of: /^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/) else { return nil }
        let hours = time.1.flatMap { Int($0) } ?? 0
        let minutes = time.2.flatMap { Int($0) } ?? 0
        let seconds = time.3.flatMap { Int($0) } ?? 0
        guard hours + minutes + seconds > 0 else { return nil }
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                         : String(format: "%d:%02d", minutes, seconds)
    }
}

enum CatalogError: LocalizedError {
    case unavailable(String)
    case unreadable
    case channelMissing
    case playlistMissing

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .unreadable: "YouTube returned an unreadable response. Try again."
        case .channelMissing: "This channel could not be found. Check its YouTube handle or channel ID."
        case .playlistMissing: "This channel’s uploads playlist is unavailable."
        }
    }
}

enum ChannelAddress: Equatable {
    case id(String)
    case handle(String)

    static func isID(_ value: String) -> Bool {
        value.range(of: #"^UC[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil
    }

    init?(_ input: String) {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("youtube.com/") || value.hasPrefix("www.youtube.com/") || value.hasPrefix("m.youtube.com/") {
            value = "https://" + value
        }
        if let url = URL(string: value), let host = url.host?.lowercased() {
            guard ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.first == "channel", parts.count >= 2 { value = parts[1] }
            else if let first = parts.first, first.hasPrefix("@") { value = first }
            else { return nil }
        }
        if Self.isID(value) { self = .id(value) }
        else if value.hasPrefix("@"), (2...101).contains(value.count),
                value.range(of: #"[\s/?#]"#, options: .regularExpression) == nil { self = .handle(value) }
        else { return nil }
    }
}

struct ChannelCatalog: Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 25
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    func subscriptions(token: String, order: String? = "alphabetical") async throws -> SubscriptionInventory {
        var inventory = SubscriptionInventory()
        var seenPages = Set<String>()
        var seenChannels = Set<String>()
        var page: String?
        repeat {
            try Task.checkCancellation()
            let result = try await list("subscriptions", ["part": "snippet", "mine": "true", "maxResults": "50",
                "order": order, "pageToken": page, "fields": "pageInfo/totalResults,nextPageToken,items(snippet(title,resourceId/channelId,thumbnails))"], token)
            inventory.pages += 1
            inventory.received += result.items.count
            inventory.reportedTotal = result.pageInfo?.totalResults ?? inventory.reportedTotal
            inventory.channels += result.items.compactMap { item in
                guard let snippet = item.snippet, let id = snippet.resourceId?.channelId,
                      ChannelAddress.isID(id), seenChannels.insert(id).inserted else { return nil }
                return RoomChannel(id: id, title: snippet.title ?? id, thumbnail: snippet.image)
            }
            page = result.nextPageToken
        } while page.map { seenPages.insert($0).inserted } == true
        return inventory
    }

    func channelDetails(ids: [String], token: String) async throws -> [RoomChannel] {
        try await resolve(["id": ids.joined(separator: ",")], token)
    }

    func profile(token: String) async throws -> RoomChannel? {
        try await resolve(["mine": "true"], token).first
    }

    private func resolve(_ selector: [String: String?], _ token: String) async throws -> [RoomChannel] {
        let params = selector.merging(["part": "snippet,contentDetails,topicDetails", "maxResults": "50",
            "fields": "items(id,snippet(title,customUrl,thumbnails),contentDetails/relatedPlaylists/uploads,topicDetails/topicCategories)"]) { value, _ in value }
        let response = try await list("channels", params, token)
        return response.items.compactMap {
            guard let id = $0.id?.raw, ChannelAddress.isID(id), let snippet = $0.snippet,
                  let title = snippet.title else { return nil }
            return RoomChannel(id: id, title: title, thumbnail: snippet.image, uploadsID: $0.contentDetails?.relatedPlaylists?.uploads,
                               topics: $0.topicDetails?.topicCategories?.compactMap(RoomDiscovery.topicName), handle: snippet.customUrl)
        }
    }

    func find(address: ChannelAddress, token: String?) async throws -> RoomChannel {
        if let token {
            let selector: [String: String]
            switch address {
            case .id(let id): selector = ["id": id]
            case .handle(let handle): selector = ["forHandle": handle]
            }
            guard let channel = try await resolve(selector, token).first else { throw CatalogError.channelMissing }
            return channel
        }
        let id: String
        switch address {
        case .id(let channelID):
            id = channelID
        case .handle(let handle):
            // Read public channel metadata. Never send account credentials to web pages.
            let url = URL(string: "https://www.youtube.com")!.appendingPathComponent(handle)
            let html = try await data(URLRequest(url: url))
            guard let text = String(data: html, encoding: .utf8),
                  let channelID = Self.channelIDFromHTML(text) else { throw CatalogError.channelMissing }
            id = channelID
        }
        return try await publicFeed(id).0
    }

    static func channelIDFromHTML(_ text: String) -> String? {
        // Restrict matches to the channel's canonical link, feed link or channelId metatag.
        let patterns = [
            #"<link\b(?=[^>]*\brel=["']canonical["'])[^>]*\bhref=["']https://(?:www\.)?youtube\.com/channel/(UC[A-Za-z0-9_-]{22})["'][^>]*>"#,
            #"<link\b[^>]*href=["'][^"']*/feeds/videos\.xml\?channel_id=(UC[A-Za-z0-9_-]{22})["'][^>]*>"#,
            #"<meta\b[^>]*itemprop=["']channelId["'][^>]*content=["'](UC[A-Za-z0-9_-]{22})["'][^>]*>"#
        ]
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: range),
               let value = Range(match.range(at: 1), in: text) { return String(text[value]) }
        }
        return nil
    }

    func publicFeed(_ id: String) async throws -> (RoomChannel, CatalogPage) {
        guard ChannelAddress.isID(id) else { throw CatalogError.channelMissing }
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)")!
        var emptyFeed: (RoomChannel, CatalogPage)?
        do {
            let feed = try ChannelAtom.read(await data(URLRequest(url: url)), id: id)
            if !feed.1.videos.isEmpty { return feed }
            emptyFeed = feed
        } catch { try Task.checkCancellation() }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/channel/\(id)/videos?app=desktop&hl=en")!)
        request.setValue("FreeTube/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do { return try Self.publicUploads(from: await data(request), channelID: id) }
        catch {
            try Task.checkCancellation()
            if let emptyFeed { return emptyFeed }
            throw error
        }
    }

    func uploads(_ channel: RoomChannel, token: String?, page: String? = nil, count: Int = 30) async throws -> CatalogPage {
        guard let token, let playlist = channel.uploadsID else { return try await publicFeed(channel.id).1 }
        let result: APIPage
        do {
            result = try await list("playlistItems", ["part": "snippet,contentDetails,status", "playlistId": playlist,
                "maxResults": String(count), "pageToken": page,
                "fields": "nextPageToken,items(snippet(title,videoOwnerChannelId,thumbnails),contentDetails(videoId,videoPublishedAt),status/privacyStatus)"], token)
        } catch {
            try Task.checkCancellation()
            guard page == nil else {
                if case CatalogError.playlistMissing = error { return CatalogPage() }
                throw error
            }
            do { return try await publicFeed(channel.id).1 }
            catch CatalogError.channelMissing { return CatalogPage() }
        }
        let videos = result.items.compactMap { item -> ChannelVideo? in
            guard let snippet = item.snippet, let title = snippet.title, let details = item.contentDetails,
                  let id = details.videoId, let date = Self.date(details.videoPublishedAt),
                  item.status?.privacyStatus != "private",
                  snippet.videoOwnerChannelId == nil || snippet.videoOwnerChannelId == channel.id else { return nil }
            return ChannelVideo(id: id, title: title, channelID: channel.id, channelTitle: channel.title,
                                thumbnail: snippet.image, publishedAt: date,
                                coverThumbnail: snippet.thumbnails?["maxres"]?.url ?? snippet.thumbnails?["standard"]?.url)
        }
        return CatalogPage(videos: videos, next: result.nextPageToken)
    }

    func search(_ query: String, token: String, page: String? = nil, videosOnly: Bool = false) async throws -> CatalogPage {
        let result = try await list("search", ["part": "snippet", "q": query, "type": videosOnly ? "video" : "channel,video",
            "maxResults": videosOnly ? "50" : "30", "pageToken": page,
            "fields": "nextPageToken,items(id(channelId,videoId),snippet(title,channelTitle,channelId,publishedAt,thumbnails))"], token)
        var found = CatalogPage(next: result.nextPageToken)
        for item in result.items {
            guard let id = item.id, let snippet = item.snippet, let title = snippet.title else { continue }
            if let channelID = id.channelId {
                found.channels.append(RoomChannel(id: channelID, title: Self.decodeTitle(title), thumbnail: snippet.image))
            } else if let videoID = id.videoId, let channelID = snippet.channelId, let channelTitle = snippet.channelTitle {
                found.videos.append(ChannelVideo(id: videoID, title: Self.decodeTitle(title), channelID: channelID,
                    channelTitle: Self.decodeTitle(channelTitle), thumbnail: snippet.image, publishedAt: Self.date(snippet.publishedAt) ?? .distantPast))
            }
        }
        return found
    }

    func likedIDs(token: String) async throws -> [String] {
        let page = try await list("videos", ["part": "id", "myRating": "like", "maxResults": "50",
                                             "fields": "items/id"], token)
        return page.items.compactMap { $0.id?.raw }
    }

    func facts(for ids: [String], token: String) async throws -> [String: RoomVideoFacts] {
        guard !ids.isEmpty else { return [:] }
        let response = try await list("videos", ["part": "contentDetails,statistics,snippet", "id": ids.joined(separator: ","),
            "fields": "items(id,contentDetails/duration,statistics/viewCount,snippet(title,tags,liveBroadcastContent))"], token)
        var facts = [String: RoomVideoFacts]()
        for item in response.items {
            guard let id = item.id?.raw else { continue }
            let duration = RoomVideoFacts.clock(item.contentDetails?.duration)
            facts[id] = RoomVideoFacts(duration: duration,
                                       views: item.statistics?.viewCount.flatMap(UInt64.init),
                                       live: item.snippet?.liveBroadcastContent == "live",
                                       short: RoomVideoFacts.creatorTaggedShort(title: item.snippet?.title, tags: item.snippet?.tags, duration: duration))
        }
        return facts
    }

    func publicSearch(_ query: String) async throws -> CatalogPage {
        try Self.publicResults(from: await publicPage(path: "results", item: URLQueryItem(name: "search_query", value: query)))
    }

    func videoDescription(for videoID: String, token: String?) async throws -> String? {
        guard RoomAIValidation.validID(videoID) else { throw CatalogError.unreadable }
        if let token {
            do {
                let page = try await list("videos", ["part": "snippet", "id": videoID, "fields": "items(id,snippet/description)"], token)
                if let text = page.items.first(where: { $0.id?.raw == videoID })?.snippet?.description {
                    return Self.creatorText(text)
                }
            } catch { try Task.checkCancellation() }
        }
        return try Self.publicDescription(from: await watchPage(videoID), videoID: videoID)
    }

    func similarVideos(to video: ChannelVideo) async throws -> [ChannelVideo] {
        try await related(to: video.id)
    }

    func related(to videoID: String) async throws -> [ChannelVideo] {
        guard RoomAIValidation.validID(videoID) else { throw CatalogError.unreadable }
        return try Self.publicRelated(from: await watchPage(videoID), videoID: videoID)
    }

    private func watchPage(_ videoID: String) async throws -> Data {
        try await publicPage(path: "watch", item: URLQueryItem(name: "v", value: videoID))
    }

    private func publicPage(path: String, item: URLQueryItem) async throws -> Data {
        var components = URLComponents(string: "https://www.youtube.com/" + path)!
        components.queryItems = [item, URLQueryItem(name: "app", value: "desktop")]
        var request = URLRequest(url: components.url!)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("FreeTube/0.1", forHTTPHeaderField: "User-Agent")
        return try await data(request)
    }

    private typealias Object = [String: Any]

    static func publicContents(from data: Data) throws -> [String: Any] {
        guard let contents = try publicRoot(from: data)["contents"] as? Object else { throw CatalogError.unreadable }
        return contents
    }

    static func publicRoot(from data: Data, variable: String = "ytInitialData") throws -> [String: Any] {
        let html = String(decoding: data, as: UTF8.self)
        let assignment = #"var\s+"# + NSRegularExpression.escapedPattern(for: variable) + #"\s*=\s*"#
        guard let start = html.range(of: assignment, options: .regularExpression)?.upperBound,
              let end = html.range(of: "</script>", options: .caseInsensitive, range: start..<html.endIndex)?.lowerBound
        else { throw CatalogError.unreadable }
        var json = html[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        // m.youtube.com wraps its JSON in a quoted JavaScript string, including \xNN escapes.
        if json.first == "'", json.last == "'" {
            var literal = [UInt8(ascii: "\"")]
            var bytes = json.dropFirst().dropLast().utf8.makeIterator()
            while let byte = bytes.next() {
                if byte == UInt8(ascii: "\\"), let escaped = bytes.next() {
                    switch escaped {
                    case UInt8(ascii: "x"):
                        guard let a = bytes.next(), let b = bytes.next() else { throw CatalogError.unreadable }
                        literal.append(contentsOf: #"\u00"#.utf8)
                        literal.append(a); literal.append(b)
                    case UInt8(ascii: "'"): literal.append(escaped)
                    default: literal.append(byte); literal.append(escaped)
                    }
                } else {
                    if byte == UInt8(ascii: "\"") { literal.append(UInt8(ascii: "\\")) }
                    literal.append(byte)
                }
            }
            literal.append(UInt8(ascii: "\""))
            json = try JSONDecoder().decode(String.self, from: Data(literal))
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? Object else { throw CatalogError.unreadable }
        return root
    }

    static func publicResults(from data: Data) throws -> CatalogPage {
        let contents = try publicContents(from: data)
        let desktop = (contents["twoColumnSearchResultsRenderer"] as? Object)?["primaryContents"] as? Object
        guard let sectionList = (desktop ?? contents)["sectionListRenderer"] as? Object,
              let sections = sectionList["contents"] as? [Object] else { throw CatalogError.unreadable }

        func title(_ node: Object?) -> String? {
            if let text = node?["simpleText"] as? String { return text }
            guard let runs = node?["runs"] as? [Object] else { return nil }
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        func thumbnail(_ node: Object) -> URL? {
            let thumbnails = (node["thumbnail"] as? Object)?["thumbnails"] as? [Object]
            guard var value = thumbnails?.last?["url"] as? String else { return nil }
            if value.hasPrefix("//") { value = "https:" + value }
            guard let url = URL(string: value), url.scheme == "https" else { return nil }
            return url
        }

        var page = CatalogPage()
        // Only direct matches in the main search listing. Shelves and promoted items are separate renderers.
        for section in sections {
            guard let block = section["itemSectionRenderer"] as? Object, let items = block["contents"] as? [Object] else { continue }
            for item in items {
                if let channel = item["channelRenderer"] as? Object, let id = channel["channelId"] as? String,
                   ChannelAddress.isID(id), let name = title(channel["title"] as? Object) {
                    page.channels.append(RoomChannel(id: id, title: name, thumbnail: thumbnail(channel)))
                } else if let video = (item["videoRenderer"] ?? item["videoWithContextRenderer"]) as? Object,
                          let id = video["videoId"] as? String, let name = title((video["title"] ?? video["headline"]) as? Object),
                          let owner = (video["ownerText"] ?? video["shortBylineText"]) as? Object,
                          let channelName = title(owner), let runs = owner["runs"] as? [Object],
                          let navigation = runs.first?["navigationEndpoint"] as? Object,
                          let endpoint = navigation["browseEndpoint"] as? Object, let channelID = endpoint["browseId"] as? String,
                          ChannelAddress.isID(channelID) {
                    page.videos.append(ChannelVideo(id: id, title: name, channelID: channelID,
                        channelTitle: channelName, thumbnail: thumbnail(video),
                        durationSeconds: RoomAIValidation.seconds(title(video["lengthText"] as? Object) ??
                            (video["thumbnailOverlays"] as? [Object])?.compactMap { overlay in
                                let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? Object
                                return title(status?["text"] as? Object)
                            }.first)))
                }
            }
        }
        return page
    }

    static func publicThumbnailBadges(_ thumbnail: [String: Any]?) -> [[String: Any]] {
        let overlays = thumbnail?["overlays"] as? [Object] ?? []
        return overlays.flatMap { overlay -> [Object] in
            let bottom = overlay["thumbnailBottomOverlayViewModel"] as? Object
            let badge = overlay["thumbnailOverlayBadgeViewModel"] as? Object
            return (bottom?["badges"] ?? badge?["thumbnailBadges"]) as? [Object] ?? []
        }.compactMap { $0["thumbnailBadgeViewModel"] as? Object }
    }

    private static func decodeTitle(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(string)) ??
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
    }

    private func list(_ resource: String, _ query: [String: String?], _ token: String) async throws -> APIPage {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(resource)")!
        components.queryItems = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let bytes = try await data(request)
        return try JSONDecoder().decode(APIPage.self, from: bytes)
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.unreadable }
        guard (200..<300).contains(http.statusCode) else {
            if let reason = try? JSONDecoder().decode(APIError.self, from: bytes) {
                if http.statusCode == 404, reason.error.errors?.contains(where: { $0.reason == "playlistNotFound" }) == true {
                    throw CatalogError.playlistMissing
                }
                let message = reason.error.message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                throw CatalogError.unavailable(message)
            }
            if http.statusCode == 404 { throw CatalogError.channelMissing }
            throw CatalogError.unavailable("YouTube returned HTTP \(http.statusCode). Try again later.")
        }
        return bytes
    }
}

private struct APIError: Decodable {
    struct Detail: Decodable {
        struct Entry: Decodable { let reason: String? }
        let message: String
        let errors: [Entry]?
    }
    let error: Detail
}
private struct APIPage: Decodable {
    struct PageInfo: Decodable { let totalResults: Int? }
    let nextPageToken: String?
    let items: [APIItem]
    let pageInfo: PageInfo?
}
private struct APIItem: Decodable {
    struct ID: Decodable {
        let raw: String?
        let channelId: String?
        let videoId: String?
        enum CodingKeys: CodingKey { case channelId, videoId }
        init(from decoder: Decoder) throws {
            if let id = try? decoder.singleValueContainer().decode(String.self) {
                raw = id; channelId = nil; videoId = nil
            } else {
                raw = nil
                let object = try decoder.container(keyedBy: CodingKeys.self)
                channelId = try object.decodeIfPresent(String.self, forKey: .channelId)
                videoId = try object.decodeIfPresent(String.self, forKey: .videoId)
            }
        }
    }
    struct Snippet: Decodable {
        struct Thumbnail: Decodable { let url: URL? }
        struct Resource: Decodable { let channelId: String? }
        let title, description, channelTitle, publishedAt, channelId, videoOwnerChannelId, liveBroadcastContent, customUrl: String?
        let tags: [String]?
        let resourceId: Resource?
        let thumbnails: [String: Thumbnail]?
        var image: URL? {
            ["high", "medium", "standard", "default"].compactMap { thumbnails?[$0]?.url }.first
        }
    }
    struct Details: Decodable {
        struct Related: Decodable { let uploads: String? }
        let relatedPlaylists: Related?
        let videoId, videoPublishedAt, duration: String?
    }
    struct Status: Decodable { let privacyStatus: String? }
    struct Topics: Decodable { let topicCategories: [String]? }
    struct Statistics: Decodable { let viewCount: String? }
    let id: ID?
    let snippet: Snippet?
    let contentDetails: Details?
    let status: Status?
    let topicDetails: Topics?
    let statistics: Statistics?
}
