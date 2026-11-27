import Foundation

private typealias WatchObject = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func object(_ path: String...) -> WatchObject? {
        path.reduce(self as WatchObject?) { $0?[$1] as? WatchObject }
    }

    var watchText: String? {
        if let content = self["content"] as? String { return content }
        if let simple = self["simpleText"] as? String { return simple }
        return (self["runs"] as? [WatchObject])?.compactMap { $0["text"] as? String }.joined()
    }
}

extension ChannelCatalog {
    static func creatorText(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func publicDescription(from data: Data, videoID: String) throws -> String? {
        if let player = try? publicRoot(from: data, variable: "ytInitialPlayerResponse"),
           let details = player.object("videoDetails"), let playerID = details["videoId"] as? String {
            guard playerID == videoID else { throw CatalogError.unreadable }
            // Despite its name, this field holds the full, plain-text description including original URLs.
            if let text = details["shortDescription"] as? String { return creatorText(text) }
        }

        let root = try watchRoot(from: data, videoID: videoID)
        let sections = root.object("contents", "twoColumnWatchNextResults", "results", "results")?["contents"] as? [WatchObject] ?? []
        if let info = sections.compactMap({ $0.object("videoSecondaryInfoRenderer") }).first,
           let text = info.object("attributedDescription")?.watchText ?? info.object("description")?.watchText {
            return creatorText(text)
        }

        let panels = root["engagementPanels"] as? [WatchObject] ?? []
        for panel in panels {
            let description = panel.object("engagementPanelSectionListRenderer", "content", "structuredDescriptionContentRenderer")
            for item in description?["items"] as? [WatchObject] ?? [] {
                if let body = item.object("expandableVideoDescriptionBodyRenderer"),
                   let text = body.object("attributedDescriptionBodyText")?.watchText ?? body.object("descriptionBodyText")?.watchText {
                    return creatorText(text)
                }
            }
        }
        throw CatalogError.unreadable
    }

    private static func watchRoot(from data: Data, videoID: String) throws -> WatchObject {
        let root = try publicRoot(from: data)
        guard root.object("currentVideoEndpoint", "watchEndpoint")?["videoId"] as? String == videoID else {
            throw CatalogError.unreadable
        }
        return root
    }

    static func publicRelated(from data: Data, videoID: String) throws -> [ChannelVideo] {
        let root = try watchRoot(from: data, videoID: videoID)
        let entries: [WatchObject]
        if let results = root.object("contents", "twoColumnWatchNextResults", "secondaryResults", "secondaryResults")?["results"] as? [WatchObject] {
            entries = results.flatMap { $0.object("itemSectionRenderer")?["contents"] as? [WatchObject] ?? [$0] }
        } else if let contents = root.object("contents", "singleColumnWatchNextResults", "results", "results")?["contents"] as? [WatchObject],
                  let feed = contents.compactMap({ $0.object("itemSectionRenderer") }).first(where: {
                      $0["targetId"] as? String == "watch-next-feed" || $0["sectionIdentifier"] as? String == "related-items"
                  }), let items = feed["contents"] as? [WatchObject] {
            entries = items
        } else { throw CatalogError.unreadable }

        var seen: Set<String> = [videoID]
        var understoodListing = entries.isEmpty
        var videos = [ChannelVideo]()
        for item in entries {
            let content = item.object("richItemRenderer", "content") ?? item
            let video: ChannelVideo?
            if let lockup = content.object("lockupViewModel") {
                video = publicVideoLockup(lockup)
            } else if let compact = content.object("compactVideoRenderer") ?? content.object("videoWithContextRenderer") ?? content.object("videoRenderer") {
                video = publicVideoRenderer(compact)
            } else if content["compactPlaylistRenderer"] != nil || content["compactRadioRenderer"] != nil {
                video = nil
            } else { continue }
            understoodListing = true
            if let video, RoomAIValidation.validID(video.id), seen.insert(video.id).inserted {
                videos.append(video)
            }
        }
        guard understoodListing else { throw CatalogError.unreadable }
        return videos
    }

    static func publicVideoLockup(_ video: [String: Any]) -> ChannelVideo? {
        guard video["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO", let id = video["contentId"] as? String,
              let metadata = video.object("metadata", "lockupMetadataViewModel"), let title = metadata.object("title")?.watchText,
              let rows = metadata.object("metadata", "contentMetadataViewModel")?["metadataRows"] as? [WatchObject],
              let parts = rows.first?["metadataParts"] as? [WatchObject], let owner = parts.first?.object("text"),
              let name = owner.watchText else { return nil }
        let commands = owner["commandRuns"] as? [WatchObject]
        let channel = commands?.first?.object("onTap", "innertubeCommand", "browseEndpoint")
            ?? metadata.object("image", "decoratedAvatarViewModel", "rendererContext", "commandContext", "onTap", "innertubeCommand", "browseEndpoint")
        guard let channelID = channel?["browseId"] as? String, ChannelAddress.isID(channelID) else { return nil }
        let thumbnail = video.object("contentImage", "thumbnailViewModel")
        let badges = publicThumbnailBadges(thumbnail)
        guard !badges.contains(where: { ($0["badgeStyle"] as? String) == "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE" }) else { return nil }
        let labels = ChannelVideo.listingLabels(rows)
        return ChannelVideo(id: id, title: title, channelID: channelID, channelTitle: name,
                            thumbnail: watchImage(thumbnail?.object("image")?["sources"]),
                            durationSeconds: badges.compactMap { RoomVideoFacts.seconds(from: $0["text"] as? String) }.first,
                            publicationLabel: labels.publication, viewLabel: labels.views)
    }

    static func publicVideoRenderer(_ video: [String: Any]) -> ChannelVideo? {
        guard let id = video["videoId"] as? String, let title = video.object("title")?.watchText ?? video.object("headline")?.watchText,
              let byline = video.object("shortBylineText") ?? video.object("longBylineText") ?? video.object("ownerText"),
              let runs = byline["runs"] as? [WatchObject], let owner = runs.first,
              let name = owner["text"] as? String, let channelID = owner.object("navigationEndpoint", "browseEndpoint")?["browseId"] as? String,
              ChannelAddress.isID(channelID) else { return nil }
        let overlays = (video["thumbnailOverlays"] as? [WatchObject] ?? []).compactMap { $0.object("thumbnailOverlayTimeStatusRenderer") }
        guard !overlays.contains(where: { $0["style"] as? String == "LIVE" }) else { return nil }
        let duration = video.object("lengthText")?.watchText ?? overlays.first?.object("text")?.watchText
        return ChannelVideo(id: id, title: title, channelID: channelID, channelTitle: name,
                            thumbnail: watchImage(video.object("thumbnail")?["thumbnails"]), durationSeconds: RoomVideoFacts.seconds(from: duration),
                            publicationLabel: video.object("publishedTimeText")?.watchText,
                            viewLabel: (video.object("shortViewCountText") ?? video.object("viewCountText"))?.watchText)
    }

    private static func watchImage(_ images: Any?) -> URL? {
        guard var value = (images as? [WatchObject])?.last?["url"] as? String else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        guard let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }
}
