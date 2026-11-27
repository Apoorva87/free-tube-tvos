import Foundation
import Observation

@MainActor @Observable
final class ChannelAccount {
    enum State: Equatable {
        case unconfigured, signedOut, requesting
        case waiting(userCode: String, verificationURL: URL)
        case signedIn
        case failed(String)
    }

    private(set) var state: State = .signedOut
    private(set) var sessionID = UUID()
    private(set) var signOutError: String?
    private(set) var switchError: String?
    var isSignedIn: Bool { refreshToken != nil }

    private var refreshToken: String?
    @ObservationIgnored private var bearer: (value: String, expires: Date)?
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var flowID: UUID?
    private var oauth: ChannelOAuthClient?
    private var store: any ChannelRefreshStore
    private static let clientStore = ChannelKeychain(clientID: "installed-oauth-client")
    private struct InstalledClient: Codable { let id: String; let secret: String }
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    convenience init() {
        let saved = try? Self.clientStore.load()
        let installed = saved.flatMap { try? JSONDecoder().decode(InstalledClient.self, from: Data($0.utf8)) }
        let oauth = installed.map { ChannelOAuthClient(clientID: $0.id, clientSecret: $0.secret) }
            ?? ChannelOAuthClient.configured(in: .main)
        self.init(oauth: oauth, store: ChannelKeychain(clientID: oauth?.clientID ?? ""))
    }

    func configure(clientID: String, secret: String) throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSignedIn, id.hasSuffix(".apps.googleusercontent.com"),
              !id.contains(where: { $0.isWhitespace }), !secret.isEmpty else {
            throw ConfigurationError()
        }
        let nextStore = ChannelKeychain(clientID: id)
        let token = try nextStore.load()
        let settings = try JSONEncoder().encode(InstalledClient(id: id, secret: secret))
        try Self.clientStore.save(String(decoding: settings, as: UTF8.self))
        oauth = ChannelOAuthClient(clientID: id, clientSecret: secret)
        store = nextStore
        refreshToken = token
        state = token == nil ? .signedOut : .signedIn
        if token != nil { sessionID = UUID() }
    }

    private struct ConfigurationError: LocalizedError {
        var errorDescription: String? { "Enter the Google TV client ID ending in .apps.googleusercontent.com and its client secret." }
    }

    init(
        oauth: ChannelOAuthClient?,
        store: any ChannelRefreshStore,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.oauth = oauth
        self.store = store
        self.now = now
        self.sleep = sleep
        guard oauth != nil else {
            state = .unconfigured
            return
        }
        do {
            refreshToken = try store.load()
            state = isSignedIn ? .signedIn : .signedOut
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // The view's structured task owns the polling lifetime.
    func signIn(replacingCurrent: Bool = false) async {
        guard let oauth, !isSignedIn || replacingCurrent else { return }
        let id = UUID()
        flowID = id
        switchError = nil
        state = .requesting
        do {
            try Task.checkCancellation()
            let code = try await oauth.requestCode()
            try checkFlow(id)
            state = .waiting(userCode: code.userCode, verificationURL: code.verificationUrl)
            let deadline = now().addingTimeInterval(code.expiresIn)
            var interval = max(code.interval ?? 5, 1)
            while true {
                let remaining = deadline.timeIntervalSince(now())
                guard remaining > 0 else { throw ChannelAccountError.expired }
                try await sleep(min(interval, remaining))
                try checkFlow(id)
                guard now() < deadline else { throw ChannelAccountError.expired }
                do {
                    let grant = try await oauth.exchange(deviceCode: code.deviceCode)
                    try checkFlow(id)
                    guard let refresh = grant.refreshToken, !refresh.isEmpty else {
                        throw ChannelAccountError.missingRefreshToken
                    }
                    try store.save(refresh)
                    refreshTask?.cancel()
                    refreshTask = nil
                    refreshToken = refresh
                    cache(grant)
                    sessionID = UUID()
                    state = .signedIn
                    flowID = nil
                    return
                } catch ChannelAccountError.oauth("authorization_pending") {
                    continue
                } catch ChannelAccountError.oauth("slow_down") {
                    interval += 5
                } catch let error as URLError where error.code == .timedOut {
                    interval *= 2
                }
            }
        } catch {
            guard flowID == id else { return }
            flowID = nil
            let cancelled = Task.isCancelled || error is CancellationError
            if isSignedIn {
                switchError = cancelled ? nil : error.localizedDescription
                state = .signedIn
            } else {
                state = cancelled ? .signedOut : .failed(error.localizedDescription)
            }
        }
    }

    func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard let oauth, let refreshToken else { throw ChannelAccountError.signedOut }
        if let bearer, bearer.expires.timeIntervalSince(now()) > 60 { return bearer.value }
        let id = sessionID
        let task: Task<String, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            task = Task { @MainActor in
                defer { if sessionID == id { refreshTask = nil } }
                do {
                    let grant = try await oauth.refresh(refreshToken)
                    try Task.checkCancellation()
                    guard sessionID == id else { throw CancellationError() }
                    if let replacement = grant.refreshToken, !replacement.isEmpty, replacement != refreshToken {
                        try store.save(replacement)
                        self.refreshToken = replacement
                    }
                    cache(grant)
                    return grant.accessToken
                } catch ChannelAccountError.oauth("invalid_grant") {
                    guard sessionID == id else { throw CancellationError() }
                    let expired = ChannelAccountError.oauth("invalid_grant")
                    clearSession()
                    state = .failed(expired.localizedDescription)
                    try store.remove()
                    throw expired
                }
            }
            refreshTask = task
        }
        let token = try await task.value
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
        return token
    }

    func signOut() {
        do {
            try store.remove()
            clearSession()
            state = .signedOut
        } catch {
            signOutError = error.localizedDescription
        }
    }

    private func checkFlow(_ id: UUID) throws {
        try Task.checkCancellation()
        guard flowID == id else { throw CancellationError() }
    }

    private func cache(_ grant: ChannelTokenGrant) {
        bearer = (grant.accessToken, now().addingTimeInterval(grant.expiresIn))
    }

    private func clearSession() {
        refreshTask?.cancel()
        refreshTask = nil
        flowID = nil
        bearer = nil
        refreshToken = nil
        signOutError = nil
        switchError = nil
        sessionID = UUID()
    }
}
