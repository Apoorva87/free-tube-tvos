import Foundation

/// YouTube's public Atom feed supplies the channel name and the exact upload dates.
final class ChannelAtom: NSObject, XMLParserDelegate {
    private struct Entry {
        var id = ""
        var title = ""
        var owner = ""
        var publisher = ""
        var thumbnail: URL?
        var date: Date?
        var views: UInt64?
    }

    private let channelID: String
    private var path = [String]()
    private var text = ""
    private var feedTitle = ""
    private var entry: Entry?
    private var videos = [ChannelVideo]()
    private var sawFeed = false

    private init(id: String) { channelID = id }

    static func read(_ data: Data, id: String) throws -> (RoomChannel, CatalogPage) {
        let result = ChannelAtom(id: id)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = result
        guard parser.parse(), result.sawFeed, !result.feedTitle.isEmpty else { throw CatalogError.unreadable }
        return (RoomChannel(id: id, title: result.feedTitle), CatalogPage(videos: result.videos))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        text = ""
        if path == ["feed"] { sawFeed = true }
        if path == ["feed", "entry"] { entry = Entry() }
        if name == "media:statistics" { entry?.views = attributes["views"].flatMap(UInt64.init) }
        if entry != nil, name == "media:thumbnail", let url = attributes["url"].flatMap(URL.init(string:)),
           url.scheme == "https" { entry?.thumbnail = url }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch path {
        case ["feed", "title"]: feedTitle = value
        case ["feed", "entry", "title"]: entry?.title = value
        case ["feed", "entry", "yt:videoId"]: entry?.id = value
        case ["feed", "entry", "yt:channelId"]: entry?.owner = value
        case ["feed", "entry", "author", "name"]: entry?.publisher = value
        case ["feed", "entry", "published"]: entry?.date = ChannelCatalog.date(value)
        case ["feed", "entry"]:
            if let entry, !entry.id.isEmpty, !entry.title.isEmpty, let date = entry.date,
               entry.owner.isEmpty || entry.owner == channelID {
                videos.append(ChannelVideo(id: entry.id, title: entry.title, channelID: channelID,
                    channelTitle: entry.publisher.isEmpty ? feedTitle : entry.publisher, thumbnail: entry.thumbnail,
                    publishedAt: date, viewLabel: entry.views.map(ChannelVideo.formatViews)))
            }
            entry = nil
        default: break
        }
        path.removeLast()
        text = ""
    }
}
