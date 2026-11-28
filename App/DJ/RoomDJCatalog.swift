import Foundation
import NaturalLanguage
import os

/// Public catalog data supplements the seed radio. YouTube's radio may cross languages.
struct RoomDJCatalog: Sendable {
    struct Metadata: Codable, Sendable {
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
    private enum Page: Hashable {
        case mix(String), search(String)
    }

    // Serialize misses, including across overlapping searches and refills. Recheck the cache
    // after taking the turn so two requests for the same page or song use one response.
    private actor RequestGate {
        static let shared = RequestGate(interval: .seconds(6))
        let interval: Duration
        let checkCooldown: @Sendable () throws -> Void
        var lastStart: ContinuousClock.Instant?
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(interval: Duration, checkCooldown: @escaping @Sendable () throws -> Void = RoomDJCooldown.check) {
            self.interval = interval
            self.checkCooldown = checkCooldown
        }

        func request<Value: Sendable>(cached: @Sendable () -> Value?,
                                      fetch: @Sendable () async throws -> Value) async throws -> Value {
            try Task.checkCancellation()
            if let value = cached() { return value }
            if busy {
                await withCheckedContinuation { waiters.append($0) }
            } else {
                busy = true
            }
            defer {
                if waiters.isEmpty { busy = false }
                else { waiters.removeFirst().resume() }
            }
            try Task.checkCancellation()
            if let value = cached() { return value }
            try checkCooldown()
            if let lastStart {
                try await ContinuousClock().sleep(until: lastStart.advanced(by: interval))
            }
            try Task.checkCancellation()
            try checkCooldown()
            lastStart = .now
            return try await fetch()
        }
    }

    private let gate: RequestGate
    private let cache: RoomDJSongCache
    private let pages = OSAllocatedUnfairLock(initialState: [Page: (expires: ContinuousClock.Instant, videos: [ChannelVideo])]())
    private let detailRetryDates = OSAllocatedUnfairLock(initialState: [String: ContinuousClock.Instant]())
    private let recordings = OSAllocatedUnfairLock(initialState: [String: String]())

    init() {
        gate = .shared
        cache = .shared
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
         metadata: @escaping @Sendable (String) async throws -> Metadata?,
         cache: RoomDJSongCache = RoomDJSongCache(), requestInterval: Duration = .zero,
         checkCooldown: @escaping @Sendable () throws -> Void = {}) {
        self.cache = cache
        gate = RequestGate(interval: requestInterval, checkCooldown: checkCooldown)
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

    private func page(_ source: Page) async throws -> [ChannelVideo] {
        try await gate.request {
            pages.withLock { stored in
                guard let hit = stored[source], hit.expires > .now else { return nil }
                return hit.videos
            }
        } fetch: {
            let videos: [ChannelVideo] = switch source {
            case .mix(let id): try await fetchMix(id)
            case .search(let query): try await fetchSearch(query)
            }
            try Task.checkCancellation()
            pages.withLock { stored in
                if stored.count >= 32, let oldest = stored.min(by: { $0.value.expires < $1.value.expires }) {
                    stored.removeValue(forKey: oldest.key)
                }
                stored[source] = (.now.advanced(by: .seconds(15 * 60)), videos)
            }
            return videos
        }
    }

    // Missing pages and unavailable metadata can use other evidence. A cancellation or a
    // server-requested pause ends the entire operation, including any remaining fallbacks.
    private func optionalPage(_ source: Page) async throws -> [ChannelVideo]? {
        do { return try await page(source) }
        catch {
            try Self.checkInterruption(error)
            return nil
        }
    }

    private static func checkInterruption(_ error: Error) throws {
        try Task.checkCancellation()
        if case CatalogError.rateLimited = error { throw error }
        if error is CancellationError { throw error }
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
            var results = [[ChannelVideo]]()
            var options = [ChannelVideo]()
            for suffix in [" official song", " official track lyrics"] {
                for stem in stems {
                    guard let videos = try await optionalPage(.search(stem + suffix)) else { continue }
                    results.append(videos)
                    options = Self.interleaved(results)
                    let ready = eligibleSongs(options, radioIDs: [], languages: languages)
                    let represented = Set(ready.compactMap { info($0).language })
                    if languages.allSatisfy(represented.contains) { return ready }
                }
                let ready = eligibleSongs(options, radioIDs: [], languages: languages)
                if !ready.isEmpty { return ready }
            }
            guard !results.isEmpty else { throw CatalogError.unavailable("Couldn’t search for music. Try again.") }
            var detailAttempts = Set<String>()
            return try await fillMissingEvidence(options, radioIDs: [], languages: languages, mode: .flow,
                                                 attempts: &detailAttempts, limit: 2)
        }
        let videos = try await page(.search(cleaned + " official music video"))
        try Task.checkCancellation()
        var candidates = Self.orderedMatches(cleaned, Self.interleaved([videos]))
        if Self.resolvedSeed(for: query, from: candidates) == nil,
           let alternate = try await optionalPage(.search(cleaned + " original song official audio")) {
            candidates = Self.orderedMatches(cleaned, Self.interleaved([videos, alternate]))
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

    private func needsDetail(_ id: String) -> Bool {
        cache.entry(for: id) == nil && detailRetryDates.withLock { dates in
            dates[id].map { $0 <= .now } ?? true
        }
    }

    private func loadDetails(_ id: String) async throws {
        _ = try await gate.request {
            needsDetail(id) ? nil : true
        } fetch: {
            do {
                let metadata = try await fetchMetadata(id)
                try Task.checkCancellation()
                cache.store(metadata, for: id)
            } catch {
                try Self.checkInterruption(error)
                // A temporary failure gets one minute to recover. A later refill can try
                // a different card without treating the failure as a durable missing record.
                detailRetryDates.withLock { dates in
                    dates = dates.filter { $0.value > .now }
                    if dates.count >= 32, let oldest = dates.min(by: { $0.value < $1.value }) {
                        dates.removeValue(forKey: oldest.key)
                    }
                    dates[id] = .now.advanced(by: .seconds(60))
                }
            }
            return true
        }
    }

    func detectedLanguage(for video: ChannelVideo) -> String? { info(video).language }

    private func info(_ video: ChannelVideo) -> Metadata {
        var info = cache.entry(for: video.id)?.metadata ?? Metadata()
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
        let votedDown = Set(disliked.map(\.id))
        let excluded = excluding.union(votedDown).union([seed.id])
        var detailAttempts = Set<String>()
        if language == nil, topic == nil, info(seed).language == nil, needsDetail(seed.id) {
            detailAttempts.insert(seed.id)
            try await loadDetails(seed.id)
        }
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
        let stems = languages.map { [$0, direction].compactMap { $0 }.joined(separator: " ") }
        let hits = stems.map { Page.search($0 + " " + popularTerms[round % popularTerms.count]) }
        let fresh = stems.map { Page.search($0 + " " + freshTerms[round % freshTerms.count] + " " + String(year)) }
        let lyrics = stems.map { Page.search($0 + " song official lyrics video") }
        let override = language != nil && seedInfo.language != nil && language != seedInfo.language
        let radio = Page.mix(seed.id)
        var sources = round.isMultiple(of: 2) ? hits + fresh : fresh + hits
        // Rotate in new releases on later refills. An explicit mood or language override
        // starts with a scoped search even if the seed radio already has plenty of songs.
        sources.insert(radio, at: topic == nil && !override && round.isMultiple(of: 2) ? 0 : stems.count)
        sources += lyrics
        var results = [[ChannelVideo]]()
        var radioIDs = Set<String>()
        var freshIDs = Set<String>()
        var triedPivot = false

        func order(_ songs: [ChannelVideo]) -> [ChannelVideo] {
            ranked(songs, seed: seed, mode: mode, liked: liked, disliked: disliked, direction: direction,
                   excludedIDs: excluded, freshIDs: freshIDs)
        }

        for (index, source) in sources.enumerated() {
            guard let videos = try await optionalPage(source) else { continue }
            results.append(videos)
            if case .mix = source { radioIDs.formUnion(videos.map(\.id)) }
            if fresh.contains(source) { freshIDs.formUnion(videos.map(\.id)) }
            let options = Self.interleaved(results, excluding: excluded)
            var ready = order(eligibleSongs(options, radioIDs: radioIDs, languages: languages))
            if ready.isEmpty, index >= 1 {
                // A second listing can supply missing counts or language for many songs at once.
                // Only then spend the shared three-detail budget, stopping at the first playable result.
                let enriched = try await fillMissingEvidence(options, radioIDs: radioIDs, languages: languages,
                                                             mode: mode, attempts: &detailAttempts, limit: 3)
                ready = order(enriched)
            }
            if index == 0 && topic != nil && languages.count > 1 && !ready.isEmpty {
                let represented = Set(ready.compactMap { info($0).language })
                if !languages.allSatisfy(represented.contains) { continue }
            }
            // A thin cross-language result can seed a better radio. Later refills can pivot
            // through liked or previously played songs when the original listing is exhausted.
            if !triedPivot && ready.count < 4 && (override || round > 0) {
                let pivots = (liked + videos.filter { excluding.contains($0.id) } + ready).filter {
                    $0.id != seed.id && !votedDown.contains($0.id) && info($0).language.map(languages.contains) == true
                }
                if !pivots.isEmpty {
                    triedPivot = true
                    let pivot = pivots[max(0, round - 1) % pivots.count]
                    if let more = try await optionalPage(.mix(pivot.id)) {
                        results.append(more)
                        radioIDs.formUnion(more.map(\.id))
                        ready = order(eligibleSongs(Self.interleaved(results, excluding: excluded), radioIDs: radioIDs,
                                                    languages: languages))
                    }
                }
            }
            if !ready.isEmpty { return ready }
        }
        guard !results.isEmpty else { throw CatalogError.unavailable("Couldn’t reach the DJ music catalog. Try again.") }
        let options = Self.interleaved(results, excluding: excluded)
        return order(try await fillMissingEvidence(options, radioIDs: radioIDs, languages: languages,
                                                   mode: mode, attempts: &detailAttempts, limit: 3))
    }

    private func fillMissingEvidence(_ options: [ChannelVideo], radioIDs: Set<String>, languages: [String],
                                     mode: RoomDJMode, attempts: inout Set<String>, limit: Int) async throws -> [ChannelVideo] {
        for song in options {
            guard attempts.count < limit else { break }
            guard !attempts.contains(song.id), needsDetail(song.id) else { continue }
            let facts = info(song)
            guard facts.language.map(languages.contains) != false else { continue }
            let radio = radioIDs.contains(song.id)
            guard facts.language == nil || (!radio && !Self.hasMusicMetadata(song))
                    || (mode == .popularShuffle && facts.views == nil) else { continue }
            attempts.insert(song.id)
            try await loadDetails(song.id)
            let eligible = eligibleSongs([song], radioIDs: radioIDs, languages: languages)
            if !eligible.isEmpty && (mode == .flow || info(song).views != nil) {
                return eligibleSongs(options, radioIDs: radioIDs, languages: languages)
            }
        }
        return eligibleSongs(options, radioIDs: radioIDs, languages: languages)
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
