import Foundation

struct AICandidate: Codable, Sendable {
    let id: String
    let title: String
    let channel: String
    let durationSeconds: Int?
}

struct AICue: Codable, Sendable, Hashable, Identifiable {
    let index: Int
    let start: Double
    let end: Double
    let text: String
    var id: Int { index }
}

struct AIRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case query, playlist, summary, jump, followup }
    let kind: Kind
    let prompt: String
    var videoID: String? = nil
    var candidates: [AICandidate] = []
    var cues: [AICue] = []
}

struct AIProposal: Codable, Sendable {
    struct Point: Codable, Sendable { let text: String; let cueIndex: Int }
    var query: String? = nil
    var title: String? = nil
    var videoIDs: [String]? = nil
    var points: [Point]? = nil
    var cueIndex: Int? = nil
}

enum RoomAIError: Error, LocalizedError {
    case invalidProposal, noSearchResults, noEvidence, staleVideo, noDuration, longPrompt

    var errorDescription: String? {
        switch self {
        case .invalidProposal: "The helper returned a selection Free Tube could not verify. Try a different request."
        case .noSearchResults: "No matching videos were available from search. Try another topic."
        case .noEvidence: "There’s no matching caption evidence in the supplied cues. Try related search."
        case .staleVideo: "The playing video changed. Open Ask AI on the current video."
        case .noDuration: "A verified playback duration is needed to jump to this cue."
        case .longPrompt: "Shorten the request to 2,000 bytes or fewer."
        }
    }
}

enum RoomAIValidation {
    static func validID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func text(_ text: String?, maxBytes: Int) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    static func clipped(_ string: String, bytes: Int) -> String {
        var result = "", count = 0
        for character in string {
            let size = character.utf8.count
            guard count + size <= bytes else { break }
            result.append(character)
            count += size
        }
        return result
    }

    static func seconds(_ clock: String?) -> Int? {
        RoomVideoFacts.seconds(from: clock)
    }

    static func targetSeconds(in prompt: String) -> Int? {
        let pattern = #/\b(\d{1,3}(?:\.\d+)?)\s*[-– ]?\s*(hours?|hrs?|minutes?|mins?)\b/#
        let matches = prompt.lowercased().matches(of: pattern)
        let total = matches.reduce(0.0) { sum, match in
            sum + (Double(match.1) ?? 0) * (match.2.hasPrefix("h") ? 3600 : 60)
        }
        return total > 0 && total <= 86400 ? Int(total.rounded()) : nil
    }

    // Resolve exclusively against this response's catalog, never against model-authored metadata.
    static func resolve(_ ids: [String]?, in results: [ChannelVideo], excluding id: String? = nil) throws -> [ChannelVideo] {
        guard let ids, ids.count <= 50 else { throw RoomAIError.invalidProposal }
        let candidates = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(), videos: [ChannelVideo] = []
        for key in ids {
            guard validID(key), key != id, let video = candidates[key] else { throw RoomAIError.invalidProposal }
            if seen.insert(key).inserted { videos.append(video) }
        }
        return videos
    }

    // Find the closest total within the requested time, preserving the helper's teaching order.
    static func fitting(_ ranked: [ChannelVideo], durations: [String: Int], target: Int?) -> [ChannelVideo] {
        guard let target, (1...86400).contains(target) else { return ranked }
        var last = [Int](repeating: -1, count: target + 1)
        last[0] = -2
        for (index, video) in ranked.enumerated() {
            guard let length = durations[video.id], (1...target).contains(length) else { continue }
            for sum in stride(from: target, through: length, by: -1) where last[sum] == -1 && last[sum - length] != -1 {
                last[sum] = index
            }
        }
        var sum = last.lastIndex(where: { $0 >= 0 }) ?? 0
        var selected: [ChannelVideo] = []
        while sum > 0 {
            let video = ranked[last[sum]]
            selected.append(video)
            sum -= durations[video.id]!
        }
        return selected.reversed()
    }

    static func validTrack(_ cues: [AICue], duration: Double?) throws -> [AICue] {
        guard cues.count <= 2400 else { throw RoomAIError.invalidProposal }
        var used = Set<Int>()
        for cue in cues {
            guard cue.index >= 0, used.insert(cue.index).inserted, cue.start.isFinite, cue.end.isFinite,
                  cue.start >= 0, cue.end > cue.start, cue.end <= 604800,
                  text(cue.text, maxBytes: 2000) != nil else { throw RoomAIError.invalidProposal }
        }
        return cues.filter { cue in duration.map { cue.start < $0 } ?? true }.sorted { $0.start < $1.start }
    }

    static func excerpts(_ cues: [AICue], question: String, forJump: Bool) -> [AICue] {
        guard !cues.isEmpty else { return [] }
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init))
        var priority: [Int] = []
        if forJump {
            var hits: [(index: Int, score: Int)] = []
            for (index, cue) in cues.enumerated() {
                let parts = cue.text.lowercased().split { !$0.isLetter && !$0.isNumber }
                let score = words.intersection(parts.map(String.init)).count
                if score > 0 { hits.append((index, score)) }
            }
            hits.sort { lhs, rhs in
                if lhs.score == rhs.score { return lhs.index < rhs.index }
                return lhs.score > rhs.score
            }
            for (i, _) in hits.prefix(45) {
                priority += [i, i - 1, i + 1].filter { cues.indices.contains($0) }
            }
        }
        // Even coverage first, including the final cue, when a whole transcript does not fit.
        let count = min(256, cues.count)
        for i in 0..<count { priority.append(count == 1 ? 0 : i * (cues.count - 1) / (count - 1)) }
        var used = Set<Int>(), bytes = 0, selection: [AICue] = []
        for i in priority where used.insert(i).inserted {
            let size = cues[i].text.utf8.count
            if selection.count == 256 { break }
            if bytes + size <= 60000 { selection.append(cues[i]); bytes += size }
        }
        return selection.sorted { $0.start < $1.start }
    }

    static func evidence(_ index: Int?, in supplied: [AICue]) throws -> AICue {
        guard let index, let cue = supplied.first(where: { $0.index == index }) else { throw RoomAIError.noEvidence }
        return cue
    }

    static func summary(_ proposal: AIProposal, in cues: [AICue]) throws -> [(String, AICue)] {
        guard let points = proposal.points, (1...12).contains(points.count) else { throw RoomAIError.noEvidence }
        return try points.map { point in
            guard let sentence = text(point.text, maxBytes: 1600) else { throw RoomAIError.invalidProposal }
            return (sentence, try evidence(point.cueIndex, in: cues))
        }
    }
}

extension TimeInterval {
    var roomTimestamp: String {
        let seconds = isFinite && self >= 0 && self < 1e8 ? Int(self) : 0
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
