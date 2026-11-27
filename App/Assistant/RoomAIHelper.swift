import Foundation
import Observation

@MainActor @Observable final class RoomAIHelper {
    private enum State: Equatable {
        case unpaired, unreachable, checking, ready, signedOut(String), unavailable(String), revoked
    }
    private struct Status: Decodable {
        let state: String
        let detail: String?
    }
    private struct PairReply: Decodable { let token: String }
    private struct Captions: Decodable {
        let videoID: String
        let cues: [AICue]
    }

    private var state: State = .unpaired
    private var discoveryProblem: String?
    private var credential: RoomHelperCredential?
    private var endpoints: [String: URL] = [:]
    @ObservationIgnored private let discovery = RoomHelperDiscovery()
    @ObservationIgnored private var statusCheck: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var transfers: [UUID: Task<Data, Error>] = [:]
    @ObservationIgnored private var generation = UUID()
    private(set) var isPairing = false

    init() {
        do {
            credential = try RoomHelperKeychain.load()
            if credential != nil { state = .unreachable }
        } catch { state = .unavailable(error.localizedDescription) }
        discovery.changed = { [weak self] found, problem in self?.discovered(found, problem: problem) }
    }

    var pairedName: String? { credential?.name }
    var helpers: [String] { endpoints.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var isReady: Bool { state == .ready }
    var pairingNotice: String? { state == .unpaired ? discoveryProblem : statusText }
    var statusText: String {
        if let discoveryProblem { return discoveryProblem }
        return switch state {
        case .unpaired: "Pair a laptop to use Ask AI."
        case .unreachable: RoomHelperError.offline.localizedDescription
        case .checking: "Checking the laptop helper…"
        case .ready: "The laptop helper is ready."
        case let .signedOut(detail), let .unavailable(detail): detail
        case .revoked: "This pairing has expired or was revoked. Pair your laptop again."
        }
    }

    func start() {
        if !discovery.isBrowsing { discovery.start() }
        checkStatus()
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self else { return }
                if !self.discovery.isBrowsing || self.pairedName.map({ self.endpoints[$0] == nil }) == true {
                    self.endpoints.removeAll()
                    self.discovery.start()
                }
                self.checkStatus()
            }
        }
    }

    func refresh() {
        statusCheck?.cancel()
        statusCheck = nil
        endpoints.removeAll()
        if credential != nil { state = .checking }
        discovery.start()
        start()
    }

    func stop() {
        poll?.cancel()
        poll = nil
        cancelRequests()
        discovery.stop()
        endpoints.removeAll()
        if credential != nil { state = .unreachable }
    }

    func forget() throws {
        try RoomHelperKeychain.delete()
        cancelRequests()
        credential = nil
        state = .unpaired
    }

    func pair(name: String, text: String) async throws {
        guard !isPairing, credential == nil else { throw RoomHelperError.message("Finish the current pairing first.") }
        guard let base = endpoints[name] else { throw RoomHelperError.offline }
        let code = try RoomPairingCode(text)
        isPairing = true
        let current = generation
        defer { if generation == current { isPairing = false } }
        let body = try JSONEncoder().encode(["code": code.secret])
        let data = try await send(base: base, path: "v1/pair", fingerprint: code.fingerprint, body: body)
        guard current == generation else { throw CancellationError() }
        guard let reply = try? JSONDecoder().decode(PairReply.self, from: data),
              (1...512).contains(reply.token.utf8.count), reply.token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw RoomHelperError.invalidResponse
        }
        let saved = RoomHelperCredential(name: name, fingerprint: code.fingerprint, token: reply.token)
        try RoomHelperKeychain.save(saved)
        credential = saved
        state = .checking
        checkStatus()
    }

    func ask(_ request: AIRequest) async throws -> AIProposal {
        guard isReady else { throw RoomHelperError.message(statusText) }
        let data = try await authorized(path: "v1/ask", body: try JSONEncoder().encode(request), timeout: 180, limit: 131072)
        guard let plan = try? JSONDecoder().decode(AIProposal.self, from: data) else { throw RoomHelperError.invalidResponse }
        return plan
    }

    func captions(for videoID: String) async throws -> [AICue] {
        guard RoomAIValidation.validID(videoID) else { throw RoomHelperError.message("The video ID is invalid.") }
        let data = try await authorized(path: "v1/captions/" + videoID, timeout: 15, limit: 1_048_576)
        guard let response = try? JSONDecoder().decode(Captions.self, from: data), response.videoID == videoID else {
            throw RoomHelperError.invalidResponse
        }
        return response.cues
    }

    private func discovered(_ found: [String: URL], problem: String?) {
        let old = pairedName.flatMap { endpoints[$0] }
        endpoints = found
        discoveryProblem = problem
        guard let name = pairedName else { return }
        guard let base = found[name] else {
            state = .unreachable
            statusCheck?.cancel()
            statusCheck = nil
            return
        }
        if base != old {
            statusCheck?.cancel()
            statusCheck = nil
            state = .checking
            checkStatus()
        }
    }

    private func checkStatus() {
        guard statusCheck == nil, let credential else { return }
        guard endpoints[credential.name] != nil else { state = .unreachable; return }
        statusCheck = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.statusCheck = nil } }
            do {
                let data = try await self.authorized(path: "v1/status", timeout: 16)
                try Task.checkCancellation()
                guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
                    throw RoomHelperError.invalidResponse
                }
                let detail = RoomHelperTransport.shortDetail(status.detail)
                switch status.state {
                case "ready": self.state = .ready
                case "signed_out": self.state = .signedOut(detail ?? "Sign in to Codex on your laptop.")
                case "unavailable": self.state = .unavailable(detail ?? "Check the helper on your laptop.")
                default: throw RoomHelperError.invalidResponse
                }
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled || self.credential != credential { return }
                self.state = .unavailable(error.localizedDescription)
            }
        }
    }

    private func authorized(path: String, body: Data? = nil, timeout: TimeInterval = 9, limit: Int = 8192) async throws -> Data {
        guard let credential else { throw RoomHelperError.message(statusText) }
        guard let base = endpoints[credential.name] else { throw RoomHelperError.offline }
        do {
            return try await send(base: base, path: path, fingerprint: credential.fingerprint, token: credential.token,
                                  body: body, timeout: timeout, limit: limit)
        } catch let error as RoomHelperError {
            guard self.credential == credential, endpoints[credential.name] == base else { throw CancellationError() }
            switch error {
            case .http(401, _, _):
                try forget()
                state = .revoked
            case .http(503, "signed_out", let detail):
                state = .signedOut(detail ?? "Sign in to Codex on your laptop.")
            case .http(503, _, _), .trust: state = .unavailable(error.localizedDescription)
            case .offline: state = .unreachable
            default: break
            }
            throw error
        }
    }

    private func send(base: URL, path: String, fingerprint: String, token: String? = nil, body: Data? = nil,
                      timeout: TimeInterval = 9, limit: Int = 8192) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        let current = generation
        let task = Task {
            try await RoomHelperTransport.send(base: base, path: path, fingerprint: fingerprint,
                                               token: token, body: body, timeout: timeout, limit: limit)
        }
        transfers[id] = task
        defer { transfers.removeValue(forKey: id) }
        let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        return data
    }

    private func cancelRequests() {
        generation = UUID()
        statusCheck?.cancel()
        statusCheck = nil
        for transfer in transfers.values { transfer.cancel() }
        transfers.removeAll()
        isPairing = false
    }
}
