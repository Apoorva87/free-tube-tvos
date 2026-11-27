import Foundation

struct RoomVideoConversation {
    private struct Exchange {
        let turn: AIConversationTurn
        let evidence: [AICue]
    }

    private var videoID: String?
    private var history: [Exchange] = []
    private var pending: AIRequest?

    var exchanges: [AIConversationTurn] { history.map(\.turn) }

    mutating func reset() {
        self = Self()
    }

    mutating func prepare(videoID: String, question: String, track: [AICue]) throws -> AIRequest {
        pending = nil
        if self.videoID != videoID {
            reset()
            self.videoID = videoID
        }
        guard RoomAIValidation.validID(videoID) else { throw RoomAIError.staleVideo }
        let track = try RoomAIValidation.validTrack(track, duration: nil)
        let current = Dictionary(uniqueKeysWithValues: track.map { ($0.index, $0) })
        // A changed caption also invalidates later replies that could depend on that turn.
        history = Array(history.prefix { exchange in
            exchange.evidence.allSatisfy { current[$0.index] == $0 }
        })
        guard !track.isEmpty else { throw RoomAIError.noEvidence }
        guard question.utf8.count <= 2000 else { throw RoomAIError.longPrompt }
        guard let question = try RoomAIValidation.message(question) else { throw RoomAIError.invalidProposal }
        let turns = exchanges
        let cited = Set(turns.flatMap(\.cueIndices))
        let cues = RoomAIValidation.excerpts(track, question: question, forJump: true, retaining: cited)
        let request = AIRequest(kind: .conversation, prompt: question, videoID: videoID, cues: cues, turns: turns)
        pending = request
        return request
    }

    mutating func append(_ proposal: AIProposal, for request: AIRequest) throws -> [(String, AICue)] {
        guard let sent = pending, sent.localID == request.localID, sent.videoID == request.videoID,
              sent.cues == request.cues, sent.turns == request.turns else { throw RoomAIError.staleVideo }
        pending = nil
        guard proposal.action == nil, proposal.message == nil, proposal.queries == nil, proposal.targetID == nil,
              proposal.research == nil, proposal.sources == nil, proposal.query == nil, proposal.title == nil,
              proposal.videoIDs == nil, proposal.cueIndex == nil,
              let points = proposal.points, points.count <= 3 else { throw RoomAIError.invalidProposal }
        guard !points.isEmpty else { throw RoomAIError.noEvidence }

        var answer: [(String, AICue)] = []
        var evidence: [AICue] = []
        for point in points {
            guard let text = try RoomAIValidation.message(point.text, maxBytes: 500) else { throw RoomAIError.invalidProposal }
            let cue = try RoomAIValidation.evidence(point.cueIndex, in: sent.cues)
            answer.append((text, cue))
            if !evidence.contains(cue) { evidence.append(cue) }
        }
        let turn = AIConversationTurn(question: sent.prompt, answer: answer.map { $0.0 }.joined(separator: " "),
                                      cueIndices: evidence.map(\.index))
        history.append(Exchange(turn: turn, evidence: evidence))
        if history.count > 3 { history.removeFirst() }
        return answer
    }
}
