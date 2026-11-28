import Foundation
import NaturalLanguage
import os

/// Public catalog data supplements the seed radio. YouTube's radio may cross languages.
struct RoomDJCatalog: Sendable {
    struct Metadata: Sendable {
        var language: String?
        var descriptors = Set<String>()
        var artist: String?
        var bpm: Int?
        var views: Double?
        var music: Bool?
    }

    private let fetchSearch: @Sendable (String) async throws -> [ChannelVideo]
    private let fetchMix: @Sendable (String) async throws -> [ChannelVideo]
    private let fetchMetadata: @Sendable (String) async throws -> Metadata?
    private let cache = OSAllocatedUnfairLock(initialState: [String: Metadata]())
    private let recordings = OSAllocatedUnfairLock(initialState: [String: String]())

    init() {
        let catalog = ChannelCatalog()
        fetchSearch = { try await catalog.publicSearch($0).videos }
        fetchMix = RoomCategoryFeed().musicMix(for:)
        fetchMetadata = { id in
            let data = try await catalog.publicPage(path: "watch", item: URLQueryItem(name: "v", value: id))
            let root = try ChannelCatalog.publicRoot(from: data, variable: "ytInitialPlayerResponse")
            return Self.metadata(from: root, id: id)
        }
    }

    init(search: @escaping @Sendable (String) async throws -> [ChannelVideo],
         mix: @escaping @Sendable (String) async throws -> [ChannelVideo],
         metadata: @escaping @Sendable (String) async throws -> Metadata?) {
        fetchSearch = search
        fetchMix = mix
        fetchMetadata = metadata
    }

    // Keep words intact in scripts which use combining marks (including Devanagari).
    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func normalized(_ text: String) -> String { words(text).joined(separator: " ") }

    private static let languages: [(name: String, aliases: [String])] = [
        ("English", ["english", "angrezi"]), ("Hindi", ["hindi", "हिन्दी", "हिंदी", "bollywood"]),
        ("Marathi", ["marathi", "मराठी"]), ("Tamil", ["tamil", "தமிழ்"]),
        ("Telugu", ["telugu", "తెలుగు"]), ("Punjabi", ["punjabi", "ਪੰਜਾਬੀ"]),
        ("Bengali", ["bengali", "bangla", "বাংলা"]), ("Gujarati", ["gujarati", "ગુજરાતી"]),
        ("Kannada", ["kannada", "ಕನ್ನಡ"]), ("Malayalam", ["malayalam", "മലയാളം"]),
        ("Spanish", ["spanish", "español"]), ("French", ["french", "français"]),
        ("Korean", ["korean", "kpop"]), ("Japanese", ["japanese"]), ("Portuguese", ["portuguese"]),
        ("German", ["german"]), ("Arabic", ["arabic"]), ("Urdu", ["urdu"]), ("Italian", ["italian"])
    ]

    static var supportedLanguages: [String] { languages.map(\.name) }

    static func language(in text: String) -> String? {
        let parts = Set(words(text))
        // Prefer a named language to an industry term when both occur, e.g. "Bollywood song (Tamil)".
        let names = languages.filter { entry in
            entry.aliases.filter { $0 != "bollywood" }.contains { alias in
                [alias, alias + "song", alias + "songs", alias + "music"].contains(where: parts.contains)
            }
        }
        if names.count == 1 { return names[0].name }
        if names.isEmpty && parts.contains("bollywood") { return "Hindi" }
        return nil
    }

    static func inferredLanguage(for video: ChannelVideo) -> String? {
        recordingLanguage(in: video.title) ?? language(in: video.channelTitle)
    }

    private static func recordingLanguage(in text: String) -> String? {
        // A translation label describes the on-screen text, not the recording.
        let cleaned = text.replacingOccurrences(of: #"(?i)\b[\p{L}]+\s+(?:lyrics|translation|subtitles|subs)\b|\b(?:lyrics|subtitles|translation) in [\p{L}]+\b"#,
                                                with: " ", options: .regularExpression)
        return language(in: cleaned)
    }

    private static let styles: [(String, Set<String>)] = [
        ("dance", ["dance", "dancefloor", "party", "upbeat", "club", "edm", "disco", "dj"]),
        ("chill", ["chill", "chillout", "mellow", "lofi", "relaxing", "calm", "ambient", "soothing"]),
        ("romantic", ["romantic", "romance", "love"]), ("acoustic", ["acoustic", "unplugged"]),
        ("wedding", ["wedding", "sangeet", "shaadi"]), ("folk", ["folk", "lavani"]),
        ("sad", ["sad", "heartbreak", "melancholy"]), ("pop", ["pop", "synthpop", "kpop"]),
        ("rock", ["rock", "metal", "punk"]), ("rap", ["rap", "hiphop"]),
        ("jazz", ["jazz", "swing"]), ("classical", ["classical", "orchestral"]),
        ("instrumental", ["instrumental", "piano"]), ("country", ["country", "bluegrass"]),
        ("happy", ["happy", "cheerful", "joyful", "uplifting", "feelgood"]),
        ("house", ["house", "techno", "trance"]), ("blues", ["blues"]), ("reggae", ["reggae", "dancehall"]),
        ("soul", ["soul", "rnb", "motown"]), ("indie", ["indie", "alternative"]),
        ("workout", ["workout", "gym", "running"]), ("devotional", ["devotional", "bhajan", "gospel"])
    ]

    private static func descriptors(in text: String) -> Set<String> {
        let parts = Set(words(text.replacingOccurrences(of: "hip hop", with: "hiphop")
            .replacingOccurrences(of: "lo-fi", with: "lofi")))
        return Set(styles.filter { !$0.1.isDisjoint(with: parts) }.map(\.0))
    }

    /// Labels often upload several artists. Prefer an explicit performance credit over the uploader.
    private static func creditedArtist(in text: String) -> String? {
        guard let match = text.firstMatch(of: /(?im)(?:^|[|\n])\s*(?:singers?|vocals?|artists?)\s*[:–-]\s*([^|\n,&]{2,80})/),
              let first = match.1.components(separatedBy: " feat. ").first else { return nil }
        let name = normalized(first)
        return name.isEmpty ? nil : name
    }

    private static func artistKey(_ video: ChannelVideo, _ data: Metadata) -> String {
        if let credit = data.artist { return credit }
        let channel = video.channelTitle.lowercased()
            .replacingOccurrences(of: #"(?:\s*-\s*topic|vevo|\s+official)$"#, with: "", options: .regularExpression)
        return normalized(channel)
    }

    private static func bpm(in text: String) -> Int? {
        guard let value = text.lowercased().firstMatch(of: /\b(\d{2,3})\s*bpm\b/),
              let bpm = Int(value.1), (30...300).contains(bpm) else { return nil }
        return bpm
    }

    static func hasMusicMetadata(_ video: ChannelVideo) -> Bool {
        let text = Set(words(video.title + " " + video.channelTitle))
        return text.contains(where: { ["song", "songs", "music", "lyrics", "lyrical", "officialaudio", "album"].contains($0) })
            || video.channelTitle.lowercased().hasSuffix("vevo") || video.channelTitle.lowercased().hasSuffix(" - topic")
            || video.title.localizedCaseInsensitiveContains("official video")
    }

    static func songSized(_ video: ChannelVideo) -> Bool {
        guard RoomAIValidation.validID(video.id) else { return false }
        if let duration = video.durationSeconds, !(45...900).contains(duration) { return false }
        let text = normalized(video.title)
        return !["jukebox", "tutorial", "reaction", "dance cover", "dance steps", "compilation", "nonstop",
                 "non stop", "playlist", "trailer", "teaser", "shorts", "interview", "medley", "wedding highlights", "mashup", "quiz", "finish the lyrics", "karaoke track"]
            .contains { (" " + text + " ").contains(" " + $0 + " ") }
    }

    private static func cleanedPrompt(_ query: String) -> String {
        var value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"(?i)^\s*(?:please\s+)?(?:play|find|give me|start with|start|more)\s+"#,
                        #"(?i)^\s*(?:(?:some|more)\s+)?(?:songs?|tracks?|music)\s+(?:like|similar to|by)\s+"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
    }

    /// Preserve an open genre/mood request as a station direction, including language and occasion.
    static func topic(for query: String) -> String? {
        let phrase = normalized(query)
        if phrase.range(of: #"\b(like|similar to|by)\b"#, options: .regularExpression) != nil { return nil }
        let cleaned = cleanedPrompt(query)
        let terms = Set(words(cleaned))
        guard !terms.isEmpty, terms.count <= 9 else { return nil }
        let generic: Set<String> = ["songs", "music", "hits", "tracks", "mix", "playlist", "genre"]
        let hasStyle = !descriptors(in: cleaned).isEmpty
        if !terms.isDisjoint(with: generic) || (terms.count <= 3 && (hasStyle || language(in: cleaned) != nil)) {
            return cleaned
        }
        return nil
    }

    private func pages(for queries: [String]) async -> [[ChannelVideo]?] {
        await withTaskGroup(of: (Int, [ChannelVideo]?).self) { group in
            for (i, query) in queries.enumerated() {
                group.addTask { [fetchSearch] in (i, try? await fetchSearch(query)) }
            }
            var pages = [[ChannelVideo]?](repeating: nil, count: queries.count)
            for await (i, page) in group { pages[i] = page }
            return pages
        }
    }

    private static func interleaved(_ pages: [[ChannelVideo]], excluding: Set<String> = []) -> [ChannelVideo] {
        var positions = [String: Int]()
        var options = [ChannelVideo]()
        for i in 0..<(pages.map(\.count).max() ?? 0) {
            for page in pages where page.indices.contains(i) {
                let song = page[i]
                guard !excluding.contains(song.id), songSized(song) else { continue }
                if let index = positions[song.id] {
                    if options[index].viewLabel == nil { options[index].viewLabel = song.viewLabel }
                    if options[index].publicationLabel == nil { options[index].publicationLabel = song.publicationLabel }
                } else {
                    positions[song.id] = options.count
                    options.append(song)
                }
            }
        }
        return options
    }

    func search(_ query: String) async throws -> [ChannelVideo] {
        let cleaned = Self.cleanedPrompt(query)
        guard !cleaned.isEmpty else { return [] }
        if let topic = Self.topic(for: query) {
            let named = Self.language(in: topic)
            let languages = named.map { [$0] } ?? ["English", "Hindi"]
            let stems = named == nil ? languages.map { $0 + " " + topic } : [topic]
            let pages = await pages(for: stems.flatMap { [$0 + " official song", $0 + " official track lyrics"] })
            try Task.checkCancellation()
            guard pages.contains(where: { $0 != nil }) else { throw CatalogError.unavailable("Couldn’t search for music. Try again.") }
            let options = Self.interleaved(pages.compactMap { $0 })
            await enrich(Array(options.prefix(6).filter { info($0).language == nil || !Self.hasMusicMetadata($0) }.map(\.id)))
            try Task.checkCancellation()
            return options.filter { video in
                let facts = info(video)
                return (facts.music ?? Self.hasMusicMetadata(video)) && facts.language.map(languages.contains) == true
            }
        }
        let videos = try await fetchSearch(cleaned + " official music video")
        try Task.checkCancellation()
        var candidates = Self.orderedMatches(cleaned, Self.interleaved([videos]))
        if Self.resolvedSeed(for: query, from: candidates) == nil {
            // A single results page may emphasize reuploads or omit the recording altogether.
            if let alternate = try? await fetchSearch(cleaned + " original song official audio") {
                candidates = Self.orderedMatches(cleaned, Self.interleaved([videos, alternate]))
            }
            try Task.checkCancellation()
        }
        return candidates
    }

    private static func orderedMatches(_ cleaned: String, _ candidates: [ChannelVideo]) -> [ChannelVideo] {
        candidates.enumerated().sorted {
            let left = Self.matchScore(cleaned, $0.element), right = Self.matchScore(cleaned, $1.element)
            return left != right ? left > right : $0.offset < $1.offset
        }.map(\.element)
    }

    private static func matchScore(_ query: String, _ video: ChannelVideo) -> Int {
        let title = normalized(video.title), compact = title.replacingOccurrences(of: " ", with: "")
        let requested = words(query), joined = requested.joined()
        guard !joined.isEmpty else { return 0 }
        var score = 0
        if compact.hasPrefix(joined) { score += 30 }
        else if compact.contains(joined) { score += 22 }
        let credits = Set(words(video.title + " " + video.channelTitle))
        score += (compact.contains(joined) ? requested.count : requested.filter(credits.contains).count) * 3
        if title.contains("official") { score += 7 }
        if title.contains("lyrics") || title.contains("lyric video") || title.contains("remix") { score -= 5 }
        let artist = words(video.channelTitle).filter { $0.count > 2 && !["official", "music", "topic", "vevo", "records"].contains($0) }
        if !artist.isEmpty && artist.allSatisfy(Set(words(video.title)).contains) { score += 15 }
        if video.channelTitle.lowercased().hasSuffix("vevo") || video.channelTitle.lowercased().hasSuffix(" - topic") { score += 8 }
        return score
    }

    static func resolvedSeed(for query: String, from results: [ChannelVideo]) -> ChannelVideo? {
        guard topic(for: query) == nil, let first = results.first else { return nil }
        let query = cleanedPrompt(query)
        let best = matchScore(query, first)
        guard best >= 29 else { return nil }
        let runner = results.dropFirst().first { $0.channelID != first.channelID }
        guard runner.map({ best - matchScore(query, $0) >= 6 }) ?? true else { return nil }
        return first
    }

    /// Use only the player record for this video. Caption translation languages do not identify the recording language.
    static func metadata(from root: [String: Any], id: String) -> Metadata? {
        typealias Object = [String: Any]
        guard let detail = root["videoDetails"] as? Object, detail["videoId"] as? String == id else { return nil }
        let micro = (root["microformat"] as? Object)?["playerMicroformatRenderer"] as? Object
        let tags = detail["keywords"] as? [String] ?? []
        let title = detail["title"] as? String ?? ""
        let name = detail["author"] as? String ?? ""
        let description = detail["shortDescription"] as? String ?? ""
        var lang = (detail["defaultAudioLanguage"] as? String)
            .flatMap { Locale(identifier: "en").localizedString(forLanguageCode: String($0.prefix(2))) }
            .flatMap { language(in: $0) } ?? recordingLanguage(in: title) ?? language(in: name)
        if lang == nil {
            let counts = Dictionary(grouping: tags.compactMap { recordingLanguage(in: $0) }, by: { $0 }).mapValues(\.count)
            let choices = counts.sorted { $0.value > $1.value }
            if let first = choices.first, first.value > (choices.dropFirst().first?.value ?? 0) { lang = first.key }
        }
        if lang == nil, let lyrics = description.range(of: #"(?im)^\s*lyrics\s*[:\-]?\s*\n"#, options: .regularExpression) {
            let sample = String(description[lyrics.upperBound...].prefix(1300))
            if sample.count > 80 {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(sample)
                if let match = recognizer.languageHypotheses(withMaximum: 1).first, match.value >= 0.9,
                   let name = Locale(identifier: "en").localizedString(forLanguageCode: match.key.rawValue) {
                    lang = language(in: name)
                }
            }
        }
        let text = ([title] + tags).joined(separator: " ")
        return Metadata(language: lang, descriptors: descriptors(in: text), artist: creditedArtist(in: description), bpm: bpm(in: text),
                        views: (detail["viewCount"] as? String).flatMap(Double.init),
                        music: (micro?["category"] as? String).map { $0 == "Music" })
    }

    private func enrich(_ ids: [String]) async {
        let missing = cache.withLock { stored in ids.filter { stored[$0] == nil } }
        for start in stride(from: 0, to: missing.count, by: 4) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: (String, Metadata?).self) { group in
                for id in missing[start..<min(start + 4, missing.count)] {
                    group.addTask { [fetchMetadata] in (id, try? await fetchMetadata(id)) }
                }
                for await (id, result) in group {
                    if let result {
                        cache.withLock { stored in
                            if stored.count >= 400, let key = stored.keys.first { stored.removeValue(forKey: key) }
                            stored[id] = result
                        }
                    }
                }
            }
        }
    }

    func detectedLanguage(for video: ChannelVideo) -> String? { info(video).language }

    private func info(_ video: ChannelVideo) -> Metadata {
        var info = cache.withLock { $0[video.id] } ?? Metadata()
        info.language = Self.inferredLanguage(for: video) ?? info.language
        info.descriptors.formUnion(Self.descriptors(in: video.title))
        if info.artist == nil { info.artist = Self.creditedArtist(in: video.title) }
        if info.bpm == nil { info.bpm = Self.bpm(in: video.title) }
        if info.views == nil { info.views = Self.views(video.viewLabel) }
        return info
    }

    private static func views(_ label: String?) -> Double? {
        guard let label, let number = label.lowercased().replacingOccurrences(of: ",", with: "")
            .firstMatch(of: /^\s*(\d+(?:\.\d+)?)\s*([kmb]?)\s*(?:views?)?\s*$/),
              let count = Double(number.1) else { return nil }
        let multiplier: Double = switch number.2 { case "k": 1_000; case "m": 1_000_000; case "b": 1_000_000_000; default: 1 }
        return count * multiplier
    }

    func station(seed: ChannelVideo, language: String?, mode: RoomDJMode, excluding: Set<String>,
                 liked: [ChannelVideo], disliked: [ChannelVideo], topic: String? = nil) async throws -> [ChannelVideo] {
        let excluded = excluding.union(disliked.map(\.id)).union([seed.id])
        async let radio: [ChannelVideo]? = try? fetchMix(seed.id)
        await enrich([seed.id])
        try Task.checkCancellation()
        let seedInfo = info(seed)
        let selected = language ?? (topic == nil ? seedInfo.language : topic.flatMap(Self.language(in:)))
        let languages = selected.map { [$0] } ?? ["English", "Hindi"]
        // Keep the user's chosen language independent of a previously typed station direction.
        var direction = topic.map { Self.words($0).filter { Self.language(in: $0) == nil }.joined(separator: " ") }
        if direction?.isEmpty != false {
            direction = ["wedding", "dance", "chill", "folk", "acoustic", "rock", "pop", "romantic", "rap", "jazz"]
                .first(where: seedInfo.descriptors.contains)
        }
        let year = Calendar.current.component(.year, from: Date())
        let round = excluding.count / 8
        let popularTerms = ["hit official song", "popular music video", "top single official video", "hit song official audio"]
        let freshTerms = ["new song", "new release official audio", "latest single", "new official music video"]
        var queries: [String] = []
        for lang in languages {
            let stem = [lang, direction].compactMap { $0 }.joined(separator: " ")
            queries.append(stem + " " + popularTerms[round % popularTerms.count])
            queries.append(stem + " " + freshTerms[round % freshTerms.count] + " " + String(year))
        }
        let searches = await pages(for: queries)
        var mix = await radio
        if round > 0 {
            let votedDown = Set(disliked.map(\.id))
            let pivots = (liked + (mix ?? []).filter { excluding.contains($0.id) }).filter {
                $0.id != seed.id && !votedDown.contains($0.id) && info($0).language.map(languages.contains) == true
            }
            if !pivots.isEmpty, let next = try? await fetchMix(pivots[(round - 1) % pivots.count].id) {
                mix = next + (mix ?? [])
            }
        }
        try Task.checkCancellation()
        guard mix != nil || searches.contains(where: { $0 != nil }) else {
            throw CatalogError.unavailable("Couldn’t reach the DJ music catalog. Try again.")
        }
        let mixIDs = Set((mix ?? []).map(\.id))
        // A scoped search is stronger evidence of a requested style than a link in an unrelated seed radio.
        let stationPages = (topic == nil ? [mix ?? []] : []) + searches.compactMap { $0 } + (topic == nil ? [] : [mix ?? []])
        let options = Self.interleaved(stationPages, excluding: excluded)
        // Some radio cards omit counts and language. Hydrate a bounded batch from the actual watch pages.
        let needsEvidence = options.filter {
            let known = info($0)
            return known.language == nil || (!mixIDs.contains($0.id) && !Self.hasMusicMetadata($0))
                || (mode == .popularShuffle && known.views == nil)
        }
        var lookup = Array(needsEvidence.prefix(9).map(\.id))
        for song in options where lookup.count < 12 && !lookup.contains(song.id) {
            lookup.append(song.id)
        }
        await enrich(lookup)
        try Task.checkCancellation()
        var eligible = eligibleSongs(options, radioIDs: mixIDs, languages: languages)
        let rankedCount = mode == .popularShuffle ? eligible.filter { info($0).views != nil }.count : eligible.count
        if rankedCount < 4 {
            try Task.checkCancellation()
            // An override can put most of the original radio outside the selected language.
            // Pivot to a matching song and search lyrics listings for additional individual releases.
            let alternateQueries = languages.map { [$0, direction, "song official lyrics video"].compactMap { $0 }.joined(separator: " ") }
            async let alternatePages = pages(for: alternateQueries)
            var pivotMix = [ChannelVideo]()
            if let pivot = eligible.first { pivotMix = (try? await fetchMix(pivot.id)) ?? [] }
            let extra = Self.interleaved([pivotMix] + (await alternatePages).compactMap { $0 },
                                         excluding: excluded.union(eligible.map(\.id)))
            let lookups = extra.filter { info($0).language == nil || info($0).views == nil || !Self.hasMusicMetadata($0) }
            await enrich(Array(lookups.prefix(10).map(\.id)))
            try Task.checkCancellation()
            eligible += eligibleSongs(extra, radioIDs: mixIDs.union(pivotMix.map(\.id)), languages: languages)
        }
        return ranked(eligible, seed: seed, mode: mode, liked: liked, disliked: disliked, direction: direction,
                      excludedIDs: excluded, freshIDs: Set(searches.enumerated().filter { $0.offset % 2 == 1 }.flatMap { ($0.element ?? []).map(\.id) }))
    }

    private func eligibleSongs(_ options: [ChannelVideo], radioIDs: Set<String>, languages: [String]) -> [ChannelVideo] {
        options.filter { video in
            let data = info(video)
            guard radioIDs.contains(video.id) || (data.music ?? Self.hasMusicMetadata(video)) else { return false }
            return data.language.map(languages.contains) == true
        }
    }

    func rank(_ videos: [ChannelVideo], seed: ChannelVideo, language: String?, mode: RoomDJMode,
              excluding: Set<String>, liked: [ChannelVideo], disliked: [ChannelVideo], topic: String? = nil) -> [ChannelVideo] {
        var seen = excluding.union(disliked.map(\.id)).union([seed.id])
        let desiredLanguage = language ?? (topic == nil ? info(seed).language : topic.flatMap(Self.language(in:)))
        let allowed = desiredLanguage.map { [$0] } ?? ["English", "Hindi"]
        let eligible = videos.filter { video in
            guard seen.insert(video.id).inserted else { return false }
            return info(video).language.map(allowed.contains) == true
        }
        return ranked(eligible, seed: seed, mode: mode, liked: liked, disliked: disliked, direction: topic, excludedIDs: excluding.union(disliked.map(\.id)), freshIDs: [])
    }

    private func ranked(_ videos: [ChannelVideo], seed: ChannelVideo, mode: RoomDJMode,
                        liked: [ChannelVideo], disliked: [ChannelVideo], direction: String?, excludedIDs: Set<String>, freshIDs: Set<String>) -> [ChannelVideo] {
        let seedInfo = info(seed)
        func feedbackProfile(_ video: ChannelVideo) -> (String, Set<String>) {
            let data = info(video)
            return (Self.artistKey(video, data), data.descriptors)
        }
        let likedInfo = liked.map(feedbackProfile)
        let dislikedInfo = disliked.map(feedbackProfile)
        let target = direction.map(Self.descriptors(in:)) ?? []
        var facts = [String: Metadata]()
        var scores = [String: Double]()
        var recordingKeys = [String: String]()
        var artists = [seed.id: Self.artistKey(seed, seedInfo)]
        for (index, video) in videos.enumerated() {
            let data = info(video)
            facts[video.id] = data
            recordingKeys[video.id] = Self.recordingKey(video, data)
            let artist = Self.artistKey(video, data)
            artists[video.id] = artist
            let popularity = log10(max(1, data.views ?? 0))
            var score = mode == .popularShuffle ? popularity * 3 + Double.random(in: 0..<1.75)
                : popularity * 0.18 + 3 / (1 + Double(index) * 0.16)
            score += Double(target.intersection(data.descriptors).count) * 1.8
            if mode == .flow {
                score += Double(seedInfo.descriptors.intersection(data.descriptors).count) * 2
                score += Self.tempoAffinity(seedInfo.bpm, data.bpm)
            }
            if likedInfo.contains(where: { $0.0 == artist }) { score += 3 }
            if dislikedInfo.contains(where: { $0.0 == artist }) { score -= 5 }
            if likedInfo.contains(where: { !$0.1.isDisjoint(with: data.descriptors) }) { score += 1.25 }
            if dislikedInfo.contains(where: { !$0.1.isDisjoint(with: data.descriptors) }) { score -= 1.5 }
            scores[video.id] = score
        }
        var candidates = videos
        if mode == .popularShuffle {
            let measured = videos.filter { facts[$0.id]?.views != nil }
            guard !measured.isEmpty else { return [] }
            let mostViewed = measured.sorted { (facts[$0.id]?.views ?? 0) > (facts[$1.id]?.views ?? 0) }
            candidates = Array(mostViewed.prefix(max(8, (mostViewed.count + 1) / 2)))
        }
        let knownDuplicates = recordings.withLock { stored in excludedIDs.compactMap { stored[$0] } }
        var playedRecordings = Set(knownDuplicates + [Self.recordingKey(seed, seedInfo)])
        var selected = [ChannelVideo]()
        var counts = [String: Int]()
        var previous = seed
        while !candidates.isEmpty && selected.count < 24 {
            let includeNew = !selected.isEmpty && selected.count % 5 == 4
            func priority(_ video: ChannelVideo) -> Double {
                var score = scores[video.id] ?? 0
                let artist = artists[video.id] ?? video.channelID
                score -= Double(counts[artist, default: 0]) * 2.5
                if artist == artists[previous.id] { score -= 3.5 }
                if includeNew && freshIDs.contains(video.id) && Self.isRecent(video) { score += 4 }
                if mode == .flow, let last = facts[previous.id], let next = facts[video.id] {
                    score += Double(last.descriptors.intersection(next.descriptors).count) * 0.6
                    score += Self.tempoAffinity(last.bpm, next.bpm)
                }
                return score
            }
            let previousInfo = facts[previous.id] ?? seedInfo
            candidates.removeAll { playedRecordings.contains(recordingKeys[$0.id] ?? $0.id) }
            guard !candidates.isEmpty else { break }
            let differentArtist = candidates.indices.filter { index in
                let song = candidates[index]
                guard artists[song.id] != artists[previous.id] else { return false }
                // When a shared uploader provides no performer credits, space its videos if another artist is available.
                return song.channelID != previous.channelID || (facts[song.id]?.artist != nil && previousInfo.artist != nil)
            }
            let choices = differentArtist.isEmpty ? Array(candidates.indices) : differentArtist
            guard let index = choices.max(by: { priority(candidates[$0]) < priority(candidates[$1]) }) else { break }
            let pick = candidates.remove(at: index)
            counts[artists[pick.id] ?? pick.channelID, default: 0] += 1
            let key = recordingKeys[pick.id] ?? pick.id
            playedRecordings.insert(key)
            recordings.withLock { stored in
                if stored.count >= 768, let oldest = stored.keys.first { stored.removeValue(forKey: oldest) }
                stored[pick.id] = key
            }
            selected.append(pick)
            previous = pick
        }
        return selected
    }

    private static func recordingKey(_ video: ChannelVideo, _ data: Metadata) -> String {
        let title = normalized(video.title)
        // Matching title and credits identify reposts across channels. Short titles need the performer as well.
        let credits = video.title.components(separatedBy: "|").map(normalized).filter { !$0.isEmpty }
        if credits.count >= 3 {
            let creditedTitle = credits.prefix(3).joined(separator: "|")
            if words(creditedTitle).count >= 6 { return creditedTitle }
        }
        return artistKey(video, data) + "|" + title
    }

    private static func isRecent(_ video: ChannelVideo) -> Bool {
        if video.publishedAt != .distantPast { return (0...180 * 86400).contains(Date().timeIntervalSince(video.publishedAt)) }
        guard let label = video.publicationLabel?.lowercased(),
              let match = label.firstMatch(of: /^(\d+) (second|minute|hour|day|week|month)s? ago/),
              let count = Int(match.1) else { return false }
        switch match.2 {
        case "month": return count <= 6
        case "week": return count <= 26
        case "day": return count <= 180
        default: return true
        }
    }

    private static func tempoAffinity(_ first: Int?, _ second: Int?) -> Double {
        guard let first, let second else { return 0 }
        return max(-1, 1.5 - Double(abs(first - second)) / 15)
    }
}
