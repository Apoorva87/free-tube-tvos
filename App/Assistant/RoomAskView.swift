import SwiftUI
import AVFoundation

private struct AskDraft: Identifiable {
    let id = UUID()
    let title: String
    let picks: [ChannelVideo]
    let matches: RoomAskMatches
    let target: Int?
    var original: RoomPlaylist? = nil
}

private struct AssistFlow {
    let id: UUID
    let question: String
    let plan: RoomAssistPlan
    let originals: [RoomPlaylist]
    var queries: [String]
}

private struct ResearchApproval {
    let flow: AssistFlow
    let topic: String
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
    @Environment(RoomPlaylistStore.self) private var store
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
    @State private var captionAction: Action?
    @State private var transcript = ""
    @State private var evidenceItem: AVPlayerItem?
    @State private var activeQuestion: String?
    @State private var reply: String?
    @State private var approval: ResearchApproval?
    @State private var chooser: AssistFlow?
    @State private var appendFlow: AssistFlow?
    @State private var findings: RoomWebFindings?

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
                if video == nil {
                    searchField
                    HStack(spacing: 20) {
                        Button("Send") { begin(.assist) }.accessibilityIdentifier("assistant-send")
                        Button("Find videos") { begin(.find) }
                        Button("Build playlist") { begin(.playlist) }
                        Button("Web research") { begin(.planResearch) }.accessibilityIdentifier("assistant-research")
                    }
                    .disabled(!helper.isReady || trimmed.isEmpty || progress != nil)
                    if inSidebar, let current = viewing.video {
                        Button { clearRequest(); askingAbout = current } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Ask about the current video", systemImage: "play.rectangle")
                                Text(current.title).font(.caption).lineLimit(1)
                            }
                        }
                    }
                } else {
                    TextField("Ask about this video’s captions", text: $prompt)
                        .onSubmit { begin(.captionQuestion) }
                    HStack(spacing: 18) {
                        Button("Send") { begin(.captionQuestion) }.disabled(trimmed.isEmpty)
                        Button("Summarize this") { begin(.summary) }
                        Button("Find timestamp") { begin(.jump) }.disabled(trimmed.isEmpty)
                        Button("Find a good follow-up") { begin(.followup) }
                    }
                    .disabled(!helper.isReady || progress != nil)
                }
                Label(helper.statusText, systemImage: helper.isReady ? "checkmark.circle" : "laptopcomputer")
                    .font(.headline)
                Button(helper.isReady ? "Helper settings" : "Connect or check helper") { showPairing = true }
                if let progress {
                    HStack { ProgressView(); Text(progress); Button("Cancel") { cancel() } }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
                if let captionAction, let video {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Use captions for this video").font(.headline)
                        Text("If you have permission to use this track with Ask AI, the paired helper can check YouTube or use a transcript you paste with timestamps.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Use public captions") { begin(captionAction, permitted: true) }
                        TextField("Paste timestamped transcript", text: $transcript)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Use pasted transcript") { begin(captionAction, permitted: true, supplied: transcript) }
                            .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("On your Mac you can also import a caption file for video " + video.id + " and try again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                assistResults
                if let draft {
                    let total = draft.picks.reduce(0) { $0 + (draft.matches.durations[$1.id] ?? 0) }
                    Text(draft.title).font(.title2.bold())
                    Text("\(draft.picks.count) videos" + (draft.target.map { " · \(Double(total).roomTimestamp) of \(Double($0).roomTimestamp) requested" } ?? ""))
                    Button(draft.original == nil ? "Edit and save playlist" : "Review additions to “\(draft.title)”") { editing = draft }
                    if let appendFlow, appendFlow.originals.count > 1 {
                        Button("Choose another playlist") {
                            self.draft = nil
                            chooser = appendFlow
                        }
                    }
                    RoomVideoGrid(videos: draft.picks, numbered: true, durations: draft.matches.durations) { pick in
                        play(pick, in: draft.picks)
                    }
                }
                if !answers.isEmpty { Text("Caption summary").font(.title3.bold()) }
                ForEach(answers) { point in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(point.text).font(.headline)
                        Text("\(point.cue.start.roomTimestamp)  “\(point.cue.text)”").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .focusable()
                }
                if let jump {
                    Text("“\(jump.text)”").font(.title3)
                    Button("Jump to \(jump.start.roomTimestamp)") { seek(jump) }
                }
                if !suggestions.isEmpty {
                    RoomVideoGrid(videos: suggestions) { play($0, in: suggestions) }
                }
                if video != nil && (offerSearch || !helper.isReady) {
                    Button("Search related videos") { begin(.related) }.disabled(progress != nil)
                }
            }
            .frame(minWidth: inSidebar ? nil : 1430, maxWidth: 1430, alignment: .leading).padding(inSidebar ? 16 : 48)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("ask-ai")
        .onAppear { helper.start() }
        .onDisappear { if progress != nil { clearRequest() } }
        .onChange(of: prompt) { _, _ in
            if activeQuestion != trimmed { clearRequest() }
        }
        .onChange(of: viewing.video?.id) { _, current in
            if let video, current != video.id { cancel(); dismiss() }
        }
        .sheet(item: $askingAbout) { current in RoomAskView(video: current) }
        .sheet(isPresented: $showPairing) { RoomPairingView(helper: helper) }
        .sheet(item: $editing) { draft in
            if let original = draft.original {
                RoomPlaylistDraftView(appendingTo: original, videos: draft.picks,
                                      candidates: draft.matches.videos, durations: draft.matches.durations)
            } else {
                RoomPlaylistDraftView(title: draft.title, videos: draft.picks,
                                      candidates: draft.matches.videos, durations: draft.matches.durations)
            }
        }
    }

    @ViewBuilder private var searchField: some View {
        let field = TextField("Ask a question or describe what to watch", text: $prompt)
            .accessibilityIdentifier("assistant-prompt")
            .onSubmit { begin(.assist) }
        if inSidebar, let browseFocus { field.focused(browseFocus, equals: .assistantPrompt) }
        else { field }
    }

    @ViewBuilder private var assistResults: some View {
        if let reply { Text(verbatim: reply).accessibilityIdentifier("assistant-answer") }
        if let approval {
            Text("Public topics for web research").font(.title3.bold())
            Text(verbatim: approval.topic)
            HStack {
                Button("Research these topics") { resume(approval.flow, researchTopic: approval.topic) }
                    .accessibilityIdentifier("assistant-approve-research")
                Button("Continue without web research") { resume(approval.flow) }
            }
        }
        if let findings {
            Text("Web research").font(.title3.bold())
            Text(verbatim: findings.topic).foregroundStyle(.secondary)
            Text(verbatim: findings.message)
            if !findings.sources.isEmpty {
                Text("Sources").font(.headline)
                ForEach(findings.sources, id: \.self) { url in
                    Text(verbatim: url.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let chooser {
            Text("Choose a playlist for these videos").font(.title3.bold())
            ForEach(chooser.originals) { playlist in
                Button(playlist.title) { resume(chooser, original: playlist) }
            }
        }
    }

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private enum Action { case assist, planResearch, find, playlist, summary, captionQuestion, jump, followup, related }

    private func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        progress = nil
    }

    private func clearRequest() {
        cancel()
        activeQuestion = nil
        notice = nil
        answers = []
        jump = nil
        draft = nil
        editing = nil
        suggestions = []
        offerSearch = false
        captionAction = nil
        approval = nil
        chooser = nil
        appendFlow = nil
        findings = nil
        reply = nil
    }

    private func run(_ id: UUID, operation: @escaping @MainActor () async throws -> Void) {
        task = Task {
            defer { if id == requestID { progress = nil; task = nil } }
            do { try await operation() }
            catch {
                guard !Task.isCancelled, id == requestID else { return }
                notice = error.localizedDescription
                offerSearch = video != nil
            }
        }
    }

    private func begin(_ action: Action, permitted: Bool = false, supplied: String? = nil) {
        guard action == .related || helper.isReady else { notice = helper.statusText; return }
        guard [.related, .summary, .followup].contains(action) || !trimmed.isEmpty else { return }
        clearRequest()
        let id = requestID
        let question = trimmed
        activeQuestion = question
        let item = viewing.playback.player.currentItem
        evidenceItem = item
        progress = action == .related ? "Searching for related videos…" : "Contacting your paired helper…"
        run(id) {
            guard question.utf8.count <= 2000 else { throw RoomAIError.longPrompt }
            switch action {
            case .assist, .planResearch:
                try await plan(question: question, request: id, requestResearch: action == .planResearch)
            case .related:
                guard let video else { return }
                let term = question.isEmpty ? video.title : question
                let result = try await RoomAskCatalog.search(term, account: account, relatedTo: video)
                try check(id, item: item)
                suggestions = Array(result.videos.prefix(8))
            case .summary, .captionQuestion, .jump:
                do {
                    try await analyzeCaptions(action, question: question, id: id, item: item, permitted: permitted, supplied: supplied)
                } catch {
                    if permitted, !Task.isCancelled, id == requestID { captionAction = action }
                    throw error
                }
            case .find, .playlist, .followup:
                try await findVideos(action, question: question, id: id, item: item)
            }
        }
    }

    private func plan(question: String, request id: UUID, requestResearch: Bool) async throws {
        let originals = Array(store.playlists.prefix(40))
        let refs = originals.map { AIPlaylistReference(id: $0.id.uuidString, title: RoomAIValidation.clipped($0.title, bytes: 256)) }
        let proposal = try await helper.ask(AIRequest(kind: .assist, prompt: question, playlists: refs))
        try check(id, item: nil)
        let plan = try RoomAIValidation.assist(proposal, references: refs)
        var flow = AssistFlow(id: id, question: question, plan: plan, originals: originals, queries: plan.queries)
        if plan.research || requestResearch {
            if flow.queries.isEmpty {
                let proposed = try await helper.ask(AIRequest(kind: .query, prompt: question))
                try check(id, item: nil)
                guard let term = RoomAIValidation.text(proposed.query, maxBytes: 180) else { throw RoomAIError.invalidProposal }
                flow.queries = [term]
            }
            approval = ResearchApproval(flow: flow, topic: try RoomAIValidation.publicTopic(from: flow.queries))
        } else {
            try await apply(flow)
        }
    }

    private func resume(_ flow: AssistFlow, researchTopic: String? = nil, original: RoomPlaylist? = nil) {
        guard flow.id == requestID, flow.question == trimmed, progress == nil else { return }
        approval = nil
        chooser = nil
        notice = nil
        progress = researchTopic == nil ? "Preparing your request…" : "Researching the approved public topics…"
        run(flow.id) {
            var next = flow
            if let researchTopic {
                let result = try await helper.ask(AIRequest(kind: .research, prompt: researchTopic))
                try check(flow.id, item: nil)
                let report = try RoomAIValidation.findings(result, topic: researchTopic)
                findings = report
                next.queries = report.queries
            }
            try await apply(next, selected: original)
        }
    }

    private func apply(_ flow: AssistFlow, selected: RoomPlaylist? = nil) async throws {
        try check(flow.id, item: nil)
        let action = flow.plan.action
        if action == .answer {
            reply = findings == nil ? flow.plan.message : nil
            return
        }
        reply = flow.plan.message
        var original: RoomPlaylist?
        if action == .append {
            original = selected ?? flow.originals.first { $0.id == flow.plan.targetID }
            guard let original else {
                if flow.originals.isEmpty { notice = "Create a playlist in Playlists, then ask to add videos to it." }
                else { chooser = flow }
                return
            }
            guard flow.originals.contains(original), store.playlists.contains(original) else { throw RoomPlaylistError.changed }
            guard original.videos.count < 100 else { throw RoomPlaylistError.tooManyVideos }
        }
        progress = "Searching for “" + flow.queries.joined(separator: "”, “") + "”…"
        let excluded = Set(original?.videos.map(\.id) ?? [])
        let matches = try await RoomAskCatalog.search(flow.queries, account: account, excluding: excluded)
        try check(flow.id, item: nil)
        guard !matches.videos.isEmpty else {
            notice = "No new videos matched these topics for this playlist."
            return
        }
        if action == .find {
            suggestions = Array(matches.videos.prefix(12))
            return
        }
        progress = "Reviewing \(matches.videos.count) matching videos…"
        let rank = try await helper.ask(AIRequest(kind: .playlist, prompt: flow.question, candidates: matches.candidates))
        try check(flow.id, item: nil)
        if let original, !store.playlists.contains(original) { throw RoomPlaylistError.changed }
        let ranked = try RoomAIValidation.resolve(rank.videoIDs, in: matches.videos)
        let target = RoomAIValidation.targetSeconds(in: flow.question)
        let picks = RoomAIValidation.fitting(ranked, durations: matches.durations, target: target)
        let title = original?.title ?? flow.plan.title ?? RoomAIValidation.text(rank.title, maxBytes: 180) ?? flow.queries[0]
        draft = AskDraft(title: String(title.prefix(100)), picks: Array(picks.prefix(100 - (original?.videos.count ?? 0))),
                         matches: matches, target: target, original: original)
        if original != nil { appendFlow = flow }
        if picks.isEmpty { notice = "Review the search results to choose which videos to include." }
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

    private func analyzeCaptions(_ action: Action, question: String, id: UUID, item: AVPlayerItem?,
                                 permitted: Bool, supplied: String?) async throws {
        guard let video else { throw RoomAIError.staleVideo }
        progress = "Checking for permitted captions…"
        let received = try await helper.captions(for: video.id, permitted: permitted, transcript: supplied)
        try check(id, item: item)
        let rawDuration = item?.duration.seconds
        let duration = rawDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let track = try RoomAIValidation.validTrack(received, duration: duration)
        guard !track.isEmpty else {
            captionAction = action
            notice = permitted ? "YouTube didn’t supply a readable timestamped track. Paste a transcript or search related videos." :
                "Your paired helper has no captions for this video yet."
            offerSearch = true
            return
        }
        transcript = ""
        let cues = RoomAIValidation.excerpts(track, question: question, forJump: action != .summary)
        progress = "Checking \(cues.count) caption cues…"
        let result = try await helper.ask(AIRequest(kind: action == .jump ? .jump : .summary,
            prompt: action == .summary ? "Summarize this video using only the supplied captions." : question, videoID: video.id, cues: cues))
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

    private func play(_ suggestion: ChannelVideo, in queue: [ChannelVideo]) {
        guard queue.contains(where: { $0.id == suggestion.id }) else { return }
        if !inSidebar { dismiss() }
        viewing.open(suggestion, in: queue)
    }
}
