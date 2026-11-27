import Foundation

extension ChannelCatalog {
    static func publicUploads(from data: Data, channelID: String, now: Date = Date()) throws -> (RoomChannel, CatalogPage) {
        typealias Object = [String: Any]
        func object(_ base: Object?, _ path: String...) -> Object? {
            path.reduce(base) { $0?[$1] as? Object }
        }
        func image(_ sources: Any?) -> URL? {
            let url = ((sources as? [Object])?.last?["url"] as? String).flatMap(URL.init(string:))
            return url?.scheme == "https" ? url : nil
        }
        let root = try publicRoot(from: data)
        guard let metadata = object(root, "metadata", "channelMetadataRenderer"),
              metadata["externalId"] as? String == channelID, let title = metadata["title"] as? String else {
            throw CatalogError.channelMissing
        }
        let channel = RoomChannel(id: channelID, title: title, thumbnail: image(object(metadata, "avatar")?["thumbnails"]))
        guard let tabs = object(root, "contents", "twoColumnBrowseResultsRenderer")?["tabs"] as? [Object] else {
            throw CatalogError.unreadable
        }
        let selected = tabs.compactMap { object($0, "tabRenderer") }.first { $0["selected"] as? Bool == true }
        guard let tab = selected, object(tab, "endpoint", "browseEndpoint")?["browseId"] as? String == channelID,
              let path = object(tab, "endpoint", "commandMetadata", "webCommandMetadata")?["url"] as? String,
              URLComponents(string: path)?.path.hasSuffix("/videos") == true else { return (channel, CatalogPage()) }
        guard let grid = object(tab, "content", "richGridRenderer")?["contents"] as? [Object] else { throw CatalogError.unreadable }
        var seen = Set<String>()
        let videos = grid.enumerated().compactMap { index, item -> ChannelVideo? in
            guard let video = object(item, "richItemRenderer", "content", "lockupViewModel"),
                  video["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO", let id = video["contentId"] as? String,
                  RoomAIValidation.validID(id), let text = object(video, "metadata", "lockupMetadataViewModel"),
                  let name = object(text, "title")?["content"] as? String else { return nil }
            // Cards on a creator's own Videos tab usually omit the creator. Verify any explicit owner too.
            if let owner = object(text, "image", "decoratedAvatarViewModel", "rendererContext", "commandContext", "onTap",
                                  "innertubeCommand", "browseEndpoint")?["browseId"] as? String, owner != channelID { return nil }
            let rows = object(text, "metadata", "contentMetadataViewModel")?["metadataRows"] as? [Object] ?? []
            let parts = rows.flatMap { $0["metadataParts"] as? [Object] ?? [] }
            // On collaboration cards the first creator is the uploader. Co-creators can expose
            // the same card on their Videos tabs without providing a browse ID in the byline.
            if parts.dropFirst().contains(where: { (object($0, "text")?["content"] as? String)?.hasPrefix("and ") == true }),
               let primary = object(parts.first, "text")?["content"] as? String,
               primary.caseInsensitiveCompare(title) != .orderedSame { return nil }
            for part in parts {
                let commands = object(part, "text")?["commandRuns"] as? [Object] ?? []
                if let owner = commands.first.flatMap({ object($0, "onTap", "innertubeCommand", "browseEndpoint")?["browseId"] as? String }),
                   owner != channelID { return nil }
            }
            guard seen.insert(id).inserted else { return nil }
            let labels = ChannelVideo.listingLabels(rows)
            let age = parts.compactMap { $0["accessibilityLabel"] as? String }.compactMap { approximateDate($0, now: now) }.first
            // The tab orders items newest-first even when several display the same coarse age.
            let thumbnail = object(video, "contentImage", "thumbnailViewModel")
            let duration = publicThumbnailBadges(thumbnail).compactMap { RoomVideoFacts.seconds(from: $0["text"] as? String) }.first
            return ChannelVideo(id: id, title: name, channelID: channelID, channelTitle: title,
                                thumbnail: image(object(thumbnail, "image")?["sources"]), publishedAt: age ?? .distantPast,
                                durationSeconds: duration, uploadPosition: index,
                                publicationLabel: labels.publication, viewLabel: labels.views)
        }
        return (channel, CatalogPage(videos: videos))
    }

    private static func approximateDate(_ text: String, now: Date) -> Date? {
        guard let age = text.firstMatch(of: /(?i)\b(\d+) (second|minute|hour|day|week|month|year)s? ago\b/),
              let count = Double(age.1) else { return nil }
        let units: [String: Double] = ["second": 1, "minute": 60, "hour": 3600, "day": 86400,
                                      "week": 604800, "month": 2629746, "year": 31556952]
        guard let seconds = units[age.2.lowercased()] else { return nil }
        return Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60 - count * seconds)
    }
}

extension ChannelCatalog {
    func mostViewed(_ channel: RoomChannel, token: String?) async throws -> [ChannelVideo] {
        guard ChannelAddress.isID(channel.id) else { throw CatalogError.channelMissing }
        // YouTube publishes its channel-wide Popular ranking as the UULP playlist.
        let playlist = "UULP" + channel.id.dropFirst(2)
        var ranking = [ChannelVideo]()
        do {
            let data = try await publicPage(path: "playlist", item: URLQueryItem(name: "list", value: playlist))
            ranking = try Self.publicMostViewed(from: data, channelID: channel.id)
        } catch {
            try Task.checkCancellation()
            if token == nil { throw error }
        }
        guard ranking.isEmpty, let token else { return ranking }
        try Task.checkCancellation()
        let page = try await search(nil, token: token, mostViewedBy: channel.id)
        let videos = page.videos.filter { $0.channelID == channel.id }
        let facts = try? await facts(for: videos.map(\.id), token: token)
        try Task.checkCancellation()
        return videos.map { video in
            var enriched = video
            enriched.durationSeconds = RoomVideoFacts.seconds(from: facts?[video.id]?.duration)
            enriched.viewLabel = facts?[video.id]?.views.map(ChannelVideo.formatViews)
            return enriched
        }
    }

    static func publicMostViewed(from data: Data, channelID: String) throws -> [ChannelVideo] {
        typealias Object = [String: Any]
        func object(_ base: Object?, _ path: String...) -> Object? {
            path.reduce(base) { $0?[$1] as? Object }
        }

        let root = try publicRoot(from: data)
        guard let header = object(root, "header", "playlistHeaderRenderer"),
              header["playlistId"] as? String == "UULP" + channelID.dropFirst(2),
              object(header, "ownerEndpoint", "browseEndpoint")?["browseId"] as? String == channelID,
              let tabs = object(root, "contents", "twoColumnBrowseResultsRenderer")?["tabs"] as? [Object],
              let tab = tabs.compactMap({ object($0, "tabRenderer") }).first(where: { $0["selected"] as? Bool == true }),
              let sections = object(tab, "content", "sectionListRenderer")?["contents"] as? [Object] else {
            throw CatalogError.unreadable
        }
        var videos = [ChannelVideo]()
        var seen = Set<String>()
        for section in sections {
            let items = object(section, "itemSectionRenderer")?["contents"] as? [Object] ?? []
            for item in items {
                let entries = object(item, "playlistVideoListRenderer")?["contents"] as? [Object] ?? [item]
                for entry in entries {
                    let video: ChannelVideo?
                    if let lockup = object(entry, "lockupViewModel") {
                        video = publicVideoLockup(lockup)
                    } else if let card = object(entry, "playlistVideoRenderer"), card["isPlayable"] as? Bool != false {
                        video = publicVideoRenderer(card)
                    } else { continue }
                    if let video, video.channelID == channelID, RoomAIValidation.validID(video.id), seen.insert(video.id).inserted {
                        videos.append(video)
                    }
                }
            }
        }
        return videos
    }
}

struct RoomCreatorShelf: Identifiable {
    enum Kind: String {
        case recent = "Recent uploads"
        case popular = "Most viewed"
        case quick = "Under 10 minutes"
        case long = "20 minutes or more"
        case shorter = "Shorter watches"
        case longer = "Longer watches"
        case earlier = "Earlier uploads"
        case more = "More from this channel"
    }

    let kind: Kind
    let videos: [ChannelVideo]
    var id: Kind { kind }

    static func rows(for channelID: String, recent: [ChannelVideo], popular: [ChannelVideo],
                     facts: [String: RoomVideoFacts]) -> [Self] {
        func unique(_ videos: [ChannelVideo]) -> [ChannelVideo] {
            var seen = Set<String>()
            return videos.filter { $0.channelID == channelID && seen.insert($0.id).inserted }
        }

        let recent = unique(recent)
        let popular = unique(popular)
        let mainRows = [Self(kind: .recent, videos: recent), Self(kind: .popular, videos: popular)].filter { !$0.videos.isEmpty }

        // Prefer videos beyond the first screenful of either shelf. Keep both original shelves scrollable.
        let leadIDs = Set([recent.first?.id, popular.first?.id].compactMap { $0 })
        let firstScreen = Set((recent.prefix(5) + popular.prefix(5)).map(\.id))
        let catalog = recent + popular
        let lengths = Dictionary(catalog.compactMap { video -> (String, Int)? in
            guard let seconds = video.durationSeconds ?? RoomVideoFacts.seconds(from: facts[video.id]?.duration),
                  seconds > 0 else { return nil }
            return (video.id, seconds)
        }, uniquingKeysWith: { first, _ in first })
        let available = unique(catalog).filter { !leadIDs.contains($0.id) }.map { video in
            var item = video
            item.durationSeconds = lengths[item.id]
            return item
        }
        let deeper = available.filter { !firstScreen.contains($0.id) }
        let candidates = deeper.count >= 4 ? deeper : available
        guard candidates.count >= 2 else { return mainRows }

        func picks(_ kind: Kind, _ items: [ChannelVideo]) -> Self {
            Self(kind: kind, videos: Array(items.prefix(12)))
        }
        let timed = candidates.filter { $0.durationSeconds != nil }
        let quick = timed.filter { ($0.durationSeconds ?? .max) < 600 }
        let long = timed.filter { ($0.durationSeconds ?? 0) >= 1200 }
        let minimumPicks = min(3, max(1, timed.count / 5))
        if quick.count >= minimumPicks && long.count >= minimumPicks {
            return mainRows + [picks(.quick, quick), picks(.long, long)]
        }
        // Music channels and long-form creators can fall entirely inside one duration band.
        // Split at a real difference in runtime, keeping equal lengths on the same shelf.
        let lengthsInOrder = Set(timed.compactMap(\.durationSeconds)).sorted()
        if lengthsInOrder.count > 1 {
            let pivot = lengthsInOrder[lengthsInOrder.count / 2]
            return mainRows + [picks(.shorter, timed.filter { ($0.durationSeconds ?? .max) < pivot }),
                               picks(.longer, timed.filter { ($0.durationSeconds ?? 0) >= pivot })]
        }

        let dated = candidates.filter { $0.publishedAt != .distantPast }.sorted { $0.publishedAt < $1.publishedAt }
        if let first = dated.first, let last = dated.last, first.publishedAt < last.publishedAt {
            let earlier = picks(.earlier, Array(dated.prefix(max(1, dated.count / 2))))
            let ids = Set(earlier.videos.map(\.id))
            return mainRows + [earlier, picks(.more, candidates.filter { !ids.contains($0.id) })]
        }
        return mainRows + [picks(.more, candidates)]
    }
}
