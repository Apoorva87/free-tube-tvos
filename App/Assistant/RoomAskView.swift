import SwiftUI
import AVFoundation

private struct AskDraft: Identifiable {
    let id = UUID()
    let title: String
    let picks: [ChannelVideo]
    let matches: RoomAskMatches
    let target: Int?
}

private struct CitedAnswer: Identifiable {
    let id = UUID()
    let text: String
    let cue: AICue
}

@MainActor
struct RoomAskView: View {
    let video: ChannelVideo?
    let inSidebar: Bool
    @Environment(\.roomBrowseFocus) private var browseFocus
    @Environment(RoomAIHelper.self) private var helper
    @Environment(ChannelAccount.self) private var account
    @Environment(RoomViewingSession.self) private var viewing
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: String
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var progress: String?
    @State private var notice: String?
    @State private var answers: [CitedAnswer] = []
    @State private var jump: AICue?
    @State private var suggestions: [ChannelVideo] = []
    @State private var draft: AskDraft?
    @State private var editing: AskDraft?
    @State private var showPairing = false
    @State private var askingAbout: ChannelVideo?
    @State private var offerSearch = false
    @State private var evidenceItem: AVPlayerItem?

    init(video: ChannelVideo? = nil, initialPrompt: String = "", inSidebar: Bool = false) {
        self.inSidebar = inSidebar
        self.video = video
        _prompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !inSidebar {
                    HStack {
                        Text("Ask AI").font(.largeTitle.bold())
                        Spacer()
                        Button("Done") { dismiss() }
                    }
                }
                if let video { Text(video.title).font(.title3).lineLimit(2) }
                Label(helper.statusText, systemImage: helper.isReady ? "checkmark.circle" : "laptopcomputer")
                    .font(.headline)
                Button(helper.isReady ? "Helper settings" : "Connect or check helper") { showPairing = true }
                if video == nil {
                    searchField
                    HStack(spacing: 20) {
                        Button("Find videos") { begin(.find) }
                        Button("Build playlist") { begin(.playlist) }
                    }
                    .disabled(!helper.isReady || trimmed.isEmpty || progress != nil)
                    if inSidebar, let current = viewing.video {
                        Button { askingAbout = current } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Ask about the current video", systemImage: "play.rectangle")
                                Text(current.title).font(.caption).lineLimit(1)
                            }
                        }
                    }
                } else {
                    TextField("What should I find in the captions?", text: $prompt)
                        .onSubmit { begin(.jump) }
                    HStack(spacing: 18) {
                        Button("Summarize this") { begin(.summary) }
                        Button("Find timestamp") { begin(.jump) }.disabled(trimmed.isEmpty)
                        Button("Find a good follow-up") { begin(.followup) }
                    }
                    .disabled(!helper.isReady || progress != nil)
                }
                if let progress {
                    HStack { ProgressView(); Text(progress); Button("Cancel") { cancel() } }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
                if let draft {
                    let total = draft.picks.reduce(0) { $0 + (draft.matches.durations[$1.id] ?? 0) }
                    Text(draft.title).font(.title2.bold())
                    Text("\(draft.picks.count) videos" + (draft.target.map { " · \(Double(total).roomTimestamp) of \(Double($0).roomTimestamp) requested" } ?? ""))
                    Button("Edit and save playlist") { editing = draft }
                }
                ForEach(answers) { point in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(point.text).font(.headline)
                        Text("\(point.cue.start.roomTimestamp)  “\(point.cue.text)”").foregroundStyle(.secondary)
                    }
                }
                if let jump {
                    Text("“\(jump.text)”").font(.title3)
                    Button("Jump to \(jump.start.roomTimestamp)") { seek(jump) }
                }
                ForEach(suggestions) { match in
                    Button { play(match) } label: {
                        VStack(alignment: .leading) {
                            Text(match.title)
                            Text(match.channelTitle).font(.caption)
                        }
                    }
                }
                if video != nil && (offerSearch || !helper.isReady) {
                    Button("Search related videos") { begin(.related) }.disabled(progress != nil)
                }
            }
            .frame(maxWidth: 1430, alignment: .leading).padding(inSidebar ? 16 : 48)
        }
        .accessibilityIdentifier("ask-ai")
        .onAppear { helper.start() }
        .onDisappear { cancel() }
        .onChange(of: viewing.video?.id) { _, current in
            if let video, current != video.id { cancel(); dismiss() }
        }
        .sheet(item: $askingAbout) { current in RoomAskView(video: current) }
        .sheet(isPresented: $showPairing) { RoomPairingView(helper: helper) }
        .sheet(item: $editing) { draft in
            RoomPlaylistDraftView(title: draft.title, videos: draft.picks,
                                  candidates: draft.matches.videos, durations: draft.matches.durations)
        }
    }

    @ViewBuilder private var searchField: some View {
        let field = TextField("Find a video or describe a playlist", text: $prompt)
            .onSubmit {
                let asksForPlaylist = trimmed.localizedCaseInsensitiveContains("playlist") || RoomAIValidation.targetSeconds(in: trimmed) != nil
                begin(asksForPlaylist ? .playlist : .find)
            }
        if inSidebar, let browseFocus { field.focused(browseFocus, equals: .assistantPrompt) }
        else { field }
    }

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private enum Action { case find, playlist, summary, jump, followup, related }

    private func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        progress = nil
    }

    private func begin(_ action: Action) {
        guard action == .related || helper.isReady else { notice = helper.statusText; return }
        guard (action != .jump && action != .playlist && action != .find) || !trimmed.isEmpty else { return }
        cancel()
        let id = requestID
        let question = trimmed
        notice = nil; answers = []; jump = nil; draft = nil; suggestions = []; offerSearch = false
        let item = viewing.playback.player.currentItem
        evidenceItem = item
        progress = action == .related ? "Searching for related videos…" : "Contacting your paired helper…"
        task = Task {
            defer { if id == requestID { progress = nil; task = nil } }
            do {
                guard question.utf8.count <= 2000 else { throw RoomAIError.longPrompt }
                switch action {
                case .related:
                    guard let video else { return }
                    let term = question.isEmpty ? video.title : question
                    let result = try await RoomAskCatalog.search(term, account: account, relatedTo: video)
                    try check(id, item: item)
                    suggestions = Array(result.videos.prefix(8))
                case .summary, .jump:
                    try await analyzeCaptions(action, question: question, id: id, item: item)
                case .find, .playlist, .followup:
                    try await findVideos(action, question: question, id: id, item: item)
                }
            } catch {
                guard !Task.isCancelled, id == requestID else { return }
                notice = error.localizedDescription
                offerSearch = video != nil
            }
        }
    }

    private func check(_ id: UUID, item: AVPlayerItem?) throws {
        try Task.checkCancellation()
        guard id == requestID else { throw CancellationError() }
        if let video {
            guard viewing.video?.id == video.id, viewing.playback.player.currentItem === item else { throw RoomAIError.staleVideo }
        }
    }

    private func findVideos(_ action: Action, question: String, id: UUID, item: AVPlayerItem?) async throws {
        let instruction = action == .followup ? "Find a good follow-up to " + (video?.title ?? "") : question
        let (term, results) = try await matchingVideos(instruction: instruction, id: id, item: item)
        if action == .find {
            suggestions = Array(results.videos.prefix(12))
            return
        }
        progress = "Reviewing \(results.videos.count) search results…"
        let proposal = try await helper.ask(AIRequest(kind: action == .playlist ? .playlist : .followup,
            prompt: RoomAIValidation.clipped(instruction, bytes: 2000), videoID: video?.id, candidates: results.candidates))
        try check(id, item: item)
        let ranked = try RoomAIValidation.resolve(proposal.videoIDs, in: results.videos, excluding: video?.id)
        if action == .followup {
            suggestions = Array(ranked.prefix(5))
            if suggestions.isEmpty {
                notice = "The helper found no suitable follow-up in these results."
                offerSearch = true
            }
            return
        }
        let target = RoomAIValidation.targetSeconds(in: question)
        let picks = RoomAIValidation.fitting(ranked, durations: results.durations, target: target)
        let result = AskDraft(title: RoomAIValidation.text(proposal.title, maxBytes: 160) ?? term,
                              picks: picks, matches: results, target: target)
        if picks.isEmpty {
            notice = "You can build your own selection from the available search results."
        }
        draft = result
        editing = result
    }

    private func matchingVideos(instruction: String, id: UUID, item: AVPlayerItem?) async throws -> (String, RoomAskMatches) {
        let initial = RoomAIValidation.clipped(instruction, bytes: 2000)
        var request = initial
        var previous: String?
        for _ in 0..<2 {
            let search = try await helper.ask(AIRequest(kind: .query, prompt: request))
            try check(id, item: item)
            guard let term = RoomAIValidation.text(search.query, maxBytes: 256) else { throw RoomAIError.invalidProposal }
            if let previous, term.caseInsensitiveCompare(previous) == .orderedSame { break }
            progress = "Searching for “\(term)”…"
            do {
                let results = try await RoomAskCatalog.search(term, account: account, relatedTo: video)
                try check(id, item: item)
                return (term, results)
            } catch RoomAIError.noSearchResults {
                try check(id, item: item)
                previous = term
                request = RoomAIValidation.clipped("No videos matched “\(term)”. Use a broader search with only the core topic. Viewer request: " + initial, bytes: 2000)
            }
        }
        throw RoomAIError.noSearchResults
    }

    private func analyzeCaptions(_ action: Action, question: String, id: UUID, item: AVPlayerItem?) async throws {
        guard let video else { throw RoomAIError.staleVideo }
        progress = "Checking for permitted captions…"
        let received = try await helper.captions(for: video.id)
        try check(id, item: item)
        let rawDuration = item?.duration.seconds
        let duration = rawDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let track = try RoomAIValidation.validTrack(received, duration: duration)
        guard !track.isEmpty else {
            notice = "No permitted timestamped captions are available for this video. You can search for a related video."
            offerSearch = true
            return
        }
        let cues = RoomAIValidation.excerpts(track, question: question, forJump: action == .jump)
        progress = "Checking \(cues.count) caption cues…"
        let result = try await helper.ask(AIRequest(kind: action == .jump ? .jump : .summary,
            prompt: action == .jump ? question : "Summarize this video using only the supplied captions.", videoID: video.id, cues: cues))
        try check(id, item: item)
        if action == .jump {
            let cue = try RoomAIValidation.evidence(result.cueIndex, in: cues)
            guard let duration, cue.start < duration else { throw RoomAIError.noDuration }
            jump = cue
        } else {
            answers = try RoomAIValidation.summary(result, in: cues).map { CitedAnswer(text: $0.0, cue: $0.1) }
        }
        notice = cues.count < track.count ? "Based on \(cues.count) excerpts from \(track.count) permitted caption cues." : "Based on this video’s permitted caption track."
    }

    private func seek(_ cue: AICue) {
        guard let video, viewing.video?.id == video.id, let item = evidenceItem, item === viewing.playback.player.currentItem,
              item.duration.seconds.isFinite, cue.start >= 0, cue.start < item.duration.seconds else {
            notice = RoomAIError.staleVideo.localizedDescription; jump = nil; return
        }
        let time = CMTime(seconds: cue.start, preferredTimescale: 1000)
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        guard ranges.isEmpty || ranges.contains(where: { CMTimeRangeContainsTime($0, time: time) }) else {
            notice = "That caption is outside the current seekable range."; return
        }
        viewing.playback.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        dismiss()
    }

    private func play(_ suggestion: ChannelVideo) {
        guard suggestions.contains(where: { $0.id == suggestion.id }) else { return }
        if !inSidebar { dismiss() }
        viewing.open(suggestion, in: suggestions)
    }
}
