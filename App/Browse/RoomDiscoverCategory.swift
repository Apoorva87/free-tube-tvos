import Foundation
import Observation

enum RoomDiscoverCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case forYou = "for-you"
    case explore, music, gaming, news, sports, live

    var id: String { rawValue }
    var title: String { self == .forYou ? "For you" : rawValue.capitalized }

    fileprivate var channelID: String? {
        switch self {
        case .music: "UC-9-kyTW8ZkZNDHQJ6FgpwQ"
        case .gaming: "UCOpNcN46UbXVtpKMrmU4Abg"
        case .news: "UCYfdidRxbB8Qhf0Nx7ioOYw"
        case .sports: "UCEgdi0XIXXZ-qJOFPf4JSKw"
        case .live: "UC4R8DWoMoI7CAwX8_LjQHig"
        case .explore, .forYou: nil
        }
    }
}

@MainActor @Observable
final class RoomCategoryCatalog {
    private(set) var category: RoomDiscoverCategory = .forYou
    private(set) var shelves = [RoomDiscoverShelf]()
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private struct Page {
        let shelves: [RoomDiscoverShelf]
        let expires: Date
    }

    @ObservationIgnored private var cache = [RoomDiscoverCategory: Page]()
    @ObservationIgnored private var currentRequest = UUID()
    private let fetch: @Sendable (RoomDiscoverCategory) async throws -> [RoomDiscoverShelf]

    init() {
        let feed = RoomCategoryFeed()
        fetch = { try await feed.shelves(for: $0) }
    }

    init(fetch: @escaping @Sendable (RoomDiscoverCategory) async throws -> [RoomDiscoverShelf]) {
        self.fetch = fetch
    }

    func load(_ category: RoomDiscoverCategory, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        currentRequest = request
        self.category = category
        shelves = []
        errorMessage = nil
        isLoading = false
        guard category != .forYou else { return }
        let destinations: [RoomDiscoverCategory] = category == .explore ? [.news, .live, .sports, .gaming, .music] : [category]
        let now = Date()
        let pending = destinations.filter { force || (cache[$0]?.expires ?? .distantPast) <= now }
        var failure: Error?
        if !pending.isEmpty {
            isLoading = true
            await withTaskGroup(of: (RoomDiscoverCategory, Result<[RoomDiscoverShelf], Error>).self) { group in
                for destination in pending {
                    group.addTask { [fetch] in
                        do { return (destination, .success(try await fetch(destination))) }
                        catch { return (destination, .failure(error)) }
                    }
                }
                for await (destination, result) in group {
                    guard currentRequest == request, !Task.isCancelled else { group.cancelAll(); return }
                    switch result {
                    case .success(let rows):
                        let lifetime: TimeInterval = destination == .live ? 90 : 900
                        cache[destination] = Page(shelves: rows, expires: Date().addingTimeInterval(lifetime))
                    case .failure(let error):
                        failure = error
                    }
                }
            }
        }
        guard currentRequest == request else { return }
        isLoading = false
        guard !Task.isCancelled else { return }

        var shown = Set<String>()
        for destination in destinations {
            guard let page = cache[destination], page.expires > Date() else { continue }
            let rows = category == .explore ? Array(page.shelves.prefix(2)) : page.shelves
            for row in rows {
                let videos = row.videos.filter { shown.insert($0.id).inserted }
                if !videos.isEmpty {
                    let title = category == .explore ? "\(destination.title) · \(row.title)" : row.title
                    shelves.append(RoomDiscoverShelf(id: row.id, title: title, videos: videos))
                }
            }
        }
        if shelves.isEmpty || (force && category != .explore) {
            errorMessage = failure?.localizedDescription
        }
    }
}

private typealias CategoryObject = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func object(_ path: String...) -> CategoryObject? {
        path.reduce(self as CategoryObject?) { $0?[$1] as? CategoryObject }
    }

    var label: String? {
        let runs = self["runs"] as? [CategoryObject]
        let text = self["simpleText"] as? String ?? self["content"] as? String ?? runs?.compactMap { $0["text"] as? String }.joined()
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Reads the same public YouTube destination pages that are available in a signed-out browser.
struct RoomCategoryFeed: Sendable {
    private let catalog = ChannelCatalog()

    func shelves(for category: RoomDiscoverCategory) async throws -> [RoomDiscoverShelf] {
        guard let id = category.channelID else { return [] }
        var url = URLComponents(string: "https://www.youtube.com/channel/" + id)!
        url.queryItems = [URLQueryItem(name: "app", value: "desktop"), URLQueryItem(name: "hl", value: "en")]
        var request = URLRequest(url: url.url!)
        request.setValue("FreeTube/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await catalog.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CatalogError.unavailable("YouTube could not load \(category.title). Try again.")
        }
        return try Self.parse(data, category: category)
    }

    static func parse(_ data: Data, category: RoomDiscoverCategory) throws -> [RoomDiscoverShelf] {
        let contents = try ChannelCatalog.publicContents(from: data)
        let browser = contents.object("twoColumnBrowseResultsRenderer") ?? contents.object("singleColumnBrowseResultsRenderer")
        let tabs = browser?["tabs"] as? [CategoryObject] ?? []
        guard let tab = tabs.compactMap({ $0.object("tabRenderer", "content") }).first else { throw CatalogError.unreadable }

        var groups: [(title: String, cards: [CategoryObject])] = []
        if let grid = tab.object("richGridRenderer")?["contents"] as? [CategoryObject] {
            for item in grid {
                if let shelf = item.object("richSectionRenderer", "content", "richShelfRenderer"),
                   let title = shelf.object("title")?.label, let cards = shelf["contents"] as? [CategoryObject] {
                    groups.append((title, cards))
                }
            }
            let loose = grid.filter { $0["richItemRenderer"] != nil }
            if !loose.isEmpty { groups.append((category.title, loose)) }
        }
        if let sections = tab.object("sectionListRenderer")?["contents"] as? [CategoryObject] {
            for section in sections {
                let items = section.object("itemSectionRenderer")?["contents"] as? [CategoryObject] ?? []
                for item in items {
                    if let shelf = item.object("horizontalCardListRenderer"),
                       let title = shelf.object("header", "richListHeaderRenderer", "title")?.label,
                       let cards = shelf["cards"] as? [CategoryObject] {
                        groups.append((title, cards))
                    } else if let shelf = item.object("shelfRenderer"), let title = shelf.object("title")?.label,
                              let list = shelf.object("content", "horizontalListRenderer") ?? shelf.object("content", "expandedShelfContentsRenderer"),
                              let cards = list["items"] as? [CategoryObject] {
                        groups.append((title, cards))
                    }
                }
            }
        }

        var seen = Set<String>()
        var rows = [RoomDiscoverShelf]()
        for (index, group) in groups.enumerated() {
            let videos = group.cards.compactMap { card -> ChannelVideo? in
                let content = card.object("richItemRenderer", "content") ?? card
                guard let video = video(in: content, liveOnly: category == .live), seen.insert(video.id).inserted else { return nil }
                return video
            }
            if !videos.isEmpty {
                rows.append(RoomDiscoverShelf(id: "\(category.id)-\(index)", title: group.title, videos: videos))
            }
        }
        guard !rows.isEmpty else {
            let message = category == .live ? "YouTube has no live streams to show right now." : "YouTube has no videos to show in \(category.title) right now."
            throw CatalogError.unavailable(message)
        }
        return rows
    }

    private static func video(in content: CategoryObject, liveOnly: Bool) -> ChannelVideo? {
        if let lockup = content.object("lockupViewModel") { return lockupVideo(lockup, liveOnly: liveOnly) }
        guard let renderer = content.object("videoRenderer") ?? content.object("videoCardRenderer") ?? content.object("gridVideoRenderer"),
              let id = renderer["videoId"] as? String, let title = renderer.object("title")?.label,
              let owner = renderer.object("longBylineText") ?? renderer.object("bylineText") ?? renderer.object("shortBylineText") ?? renderer.object("ownerText"),
              let runs = owner["runs"] as? [CategoryObject], let name = owner.label,
              let channel = runs.first?.object("navigationEndpoint", "browseEndpoint")?["browseId"] as? String,
              ChannelAddress.isID(channel) else { return nil }
        let overlays = renderer["thumbnailOverlays"] as? [CategoryObject] ?? []
        let live = overlays.contains { $0.object("thumbnailOverlayTimeStatusRenderer")?["style"] as? String == "LIVE" }
        let badges = renderer["badges"] as? [CategoryObject] ?? []
        let liveBadge = badges.contains { $0.object("metadataBadgeRenderer")?["style"] as? String == "BADGE_STYLE_TYPE_LIVE_NOW" }
        guard !liveOnly || live || liveBadge else { return nil }
        return ChannelVideo(id: id, title: title, channelID: channel, channelTitle: name,
                            thumbnail: image(renderer.object("thumbnail")?["thumbnails"]),
                            durationSeconds: RoomVideoFacts.seconds(from: renderer.object("lengthText")?.label))
    }

    private static func lockupVideo(_ lockup: CategoryObject, liveOnly: Bool) -> ChannelVideo? {
        guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = lockup["contentId"] as? String, let metadata = lockup.object("metadata", "lockupMetadataViewModel"),
              let title = metadata.object("title")?.label,
              let rows = metadata.object("metadata", "contentMetadataViewModel")?["metadataRows"] as? [CategoryObject],
              let parts = rows.first?["metadataParts"] as? [CategoryObject], let owner = parts.first?.object("text"),
              let name = owner.label else { return nil }
        let commands = owner["commandRuns"] as? [CategoryObject]
        let ownerEndpoint = commands?.first?.object("onTap", "innertubeCommand", "browseEndpoint")
            ?? metadata.object("image", "decoratedAvatarViewModel", "rendererContext", "commandContext", "onTap", "innertubeCommand", "browseEndpoint")
        guard let channel = ownerEndpoint?["browseId"] as? String, ChannelAddress.isID(channel) else { return nil }
        let thumbnail = lockup.object("contentImage", "thumbnailViewModel")
        let overlays = thumbnail?["overlays"] as? [CategoryObject] ?? []
        let badges = overlays.flatMap { overlay in
            overlay.object("thumbnailOverlayBadgeViewModel")?["thumbnailBadges"] as? [CategoryObject] ?? []
        }.compactMap { $0.object("thumbnailBadgeViewModel") }
        guard !liveOnly || badges.contains(where: { $0["badgeStyle"] as? String == "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE" }) else { return nil }
        let seconds = badges.compactMap { RoomVideoFacts.seconds(from: $0["text"] as? String) }.first
        return ChannelVideo(id: id, title: title, channelID: channel, channelTitle: name,
                            thumbnail: image(thumbnail?.object("image")?["sources"]), durationSeconds: seconds)
    }

    private static func image(_ sources: Any?) -> URL? {
        guard let images = sources as? [CategoryObject], var value = images.last?["url"] as? String else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        guard let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }
}
