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
            let age = parts.compactMap { $0["accessibilityLabel"] as? String }.compactMap { approximateDate($0, now: now) }.first
            // The tab orders items newest-first even when several display the same coarse age.
            let thumbnail = object(video, "contentImage", "thumbnailViewModel")
            let duration = publicThumbnailBadges(thumbnail).compactMap { RoomVideoFacts.seconds(from: $0["text"] as? String) }.first
            return ChannelVideo(id: id, title: name, channelID: channelID, channelTitle: title,
                                thumbnail: image(object(thumbnail, "image")?["sources"]), publishedAt: age ?? .distantPast,
                                durationSeconds: duration, uploadPosition: index)
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
