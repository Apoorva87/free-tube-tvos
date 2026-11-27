import SwiftUI

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

@MainActor
struct RoomAskView: View {
    let inSidebar: Bool
    @Environment(\.roomBrowseFocus) private var browseFocus
    @Environment(RoomAIHelper.self) private var helper
    @Environment(RoomPlaylistStore.self) private var store
    @Environment(ChannelAccount.self) private var account
    @Environment(RoomViewingSession.self) private var viewing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt: String
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var progress: String?
    @State private var notice: String?
    @State private var suggestions: [ChannelVideo] = []
    @State private var draft: AskDraft?
    @State private var editing: AskDraft?
    @State private var showPairing = false
    @State private var activeQuestion: String?
    @State private var reply: String?
    @State private var approval: ResearchApproval?
    @State private var chooser: AssistFlow?
    @State private var appendFlow: AssistFlow?
    @State private var findings: RoomWebFindings?

    init(initialPrompt: String = "", inSidebar: Bool = false) {
        self.inSidebar = inSidebar
        _prompt = State(initialValue: initialPrompt)
    }

    @ViewBuilder private var helperSettings: some View {
        Label(helper.statusText, systemImage: helper.isReady ? "checkmark.circle" : "laptopcomputer")
            .font(.headline)
        Button(helper.isReady ? "Helper settings" : "Connect or check helper") {
            showPairing = true
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !inSidebar {
                    HStack {
                        Text("Ask AI").font(.largeTitle.bold())
                        Spacer()
                        Button("Done") {
                            cancel()
                            dismiss()
                        }
                    }
                }
                searchField
                HStack(spacing: 20) {
                    Button("Send") { begin(.assist) }.accessibilityIdentifier("assistant-send")
                    Button("Find videos") { begin(.find) }
                    Button("Build playlist") { begin(.playlist) }
                    Button("Web research") { begin(.planResearch) }.accessibilityIdentifier("assistant-research")
                }
                .disabled(!helper.isReady || trimmed.isEmpty || progress != nil)
                helperSettings
                if let progress {
                    HStack {
                        ProgressView()
                        Text(progress)
                        Button("Cancel") { cancel() }.accessibilityIdentifier("assistant-cancel")
                    }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
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
                if !suggestions.isEmpty {
                    RoomVideoGrid(videos: suggestions) { play($0, in: suggestions) }
                }
            }
            .frame(minWidth: inSidebar ? nil : 1430, maxWidth: 1430, alignment: .leading).padding(inSidebar ? 16 : 48)
        }
    }

    var body: some View {
        content
        .scrollClipDisabled()
        .accessibilityIdentifier("ask-ai")
        .onAppear { helper.start() }
        .onDisappear {
            if progress != nil { clearRequest() }
        }
        .onChange(of: prompt) { _, _ in
            if activeQuestion != trimmed { clearRequest() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, progress != nil { clearRequest() }
        }
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
    private enum Action { case assist, planResearch, find, playlist }

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
        draft = nil
        editing = nil
        suggestions = []
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
            }
        }
    }

    private func begin(_ action: Action) {
        guard helper.isReady else { notice = helper.statusText; return }
        guard !trimmed.isEmpty else { return }
        clearRequest()
        let id = requestID
        let question = trimmed
        activeQuestion = question
        progress = "Contacting your paired helper…"
        run(id) {
            guard question.utf8.count <= 2000 else { throw RoomAIError.longPrompt }
            switch action {
            case .assist, .planResearch:
                try await plan(question: question, request: id, requestResearch: action == .planResearch)
            case .find, .playlist:
                try await findVideos(action, question: question, id: id)
            }
        }
    }

    private func plan(question: String, request id: UUID, requestResearch: Bool) async throws {
        let originals = Array(store.playlists.prefix(40))
        let refs = originals.map { AIPlaylistReference(id: $0.id.uuidString, title: RoomAIValidation.clipped($0.title, bytes: 256)) }
        let proposal = try await helper.ask(AIRequest(kind: .assist, prompt: question, playlists: refs))
        try check(id)
        let plan = try RoomAIValidation.assist(proposal, references: refs)
        var flow = AssistFlow(id: id, question: question, plan: plan, originals: originals, queries: plan.queries)
        if plan.research || requestResearch {
            if flow.queries.isEmpty {
                let proposed = try await helper.ask(AIRequest(kind: .query, prompt: question))
                try check(id)
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
                try check(flow.id)
                let report = try RoomAIValidation.findings(result, topic: researchTopic)
                findings = report
                next.queries = report.queries
            }
            try await apply(next, selected: original)
        }
    }

    private func apply(_ flow: AssistFlow, selected: RoomPlaylist? = nil) async throws {
        try check(flow.id)
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
        try check(flow.id)
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
        try check(flow.id)
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

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == requestID else { throw CancellationError() }
    }

    private func findVideos(_ action: Action, question: String, id: UUID) async throws {
        let (term, results) = try await matchingVideos(instruction: question, id: id)
        if action == .find {
            suggestions = Array(results.videos.prefix(12))
            return
        }
        progress = "Reviewing \(results.videos.count) search results…"
        let proposal = try await helper.ask(AIRequest(kind: .playlist, prompt: question, candidates: results.candidates))
        try check(id)
        let ranked = try RoomAIValidation.resolve(proposal.videoIDs, in: results.videos)
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

    private func matchingVideos(instruction: String, id: UUID) async throws -> (String, RoomAskMatches) {
        let initial = RoomAIValidation.clipped(instruction, bytes: 2000)
        var request = initial
        var previous: String?
        for _ in 0..<2 {
            let search = try await helper.ask(AIRequest(kind: .query, prompt: request))
            try check(id)
            guard let term = RoomAIValidation.text(search.query, maxBytes: 256) else { throw RoomAIError.invalidProposal }
            if let previous, term.caseInsensitiveCompare(previous) == .orderedSame { break }
            progress = "Searching for “\(term)”…"
            do {
                let results = try await RoomAskCatalog.search(term, account: account)
                try check(id)
                return (term, results)
            } catch RoomAIError.noSearchResults {
                try check(id)
                previous = term
                request = RoomAIValidation.clipped("No videos matched “\(term)”. Use a broader search with only the core topic. Viewer request: " + initial, bytes: 2000)
            }
        }
        throw RoomAIError.noSearchResults
    }

    private func play(_ suggestion: ChannelVideo, in queue: [ChannelVideo]) {
        guard queue.contains(where: { $0.id == suggestion.id }) else { return }
        if !inSidebar { dismiss() }
        viewing.open(suggestion, in: queue)
    }
}
