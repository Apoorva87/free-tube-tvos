import AppIntents
import Observation

@MainActor @Observable
final class RoomSystemSearch {
    struct Request: Equatable {
        let id = UUID()
        let term: String
    }

    static let shared = RoomSystemSearch()
    private(set) var pending: Request?

    func request(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        pending = Request(term: term)
    }

    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

struct SearchFreeTubeIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search freeTube"
    static let searchScopes: [StringSearchScope] = [.general, .freeformVideo]
    @Parameter(title: "Search terms") var criteria: StringSearchCriteria

    @MainActor func perform() async throws -> some IntentResult {
        RoomSystemSearch.shared.request(criteria.term)
        return .result()
    }
}
