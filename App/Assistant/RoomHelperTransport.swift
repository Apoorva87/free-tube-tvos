import CryptoKit
import Foundation
import Network
import os
import Security

struct RoomPairingCode {
    let fingerprint: String
    let secret: String

    init(_ text: String) throws {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 64,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              parts[1].utf8.count == 8, parts[1].utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw RoomHelperError.message("Paste the complete pairing text shown on your laptop.")
        }
        fingerprint = parts[0].lowercased()
        secret = String(parts[1])
    }
}

struct RoomHelperCredential: Codable, Equatable {
    let name: String
    let fingerprint: String
    let token: String
}

enum RoomHelperKeychain {
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "FreeTube") + ".ai-helper",
         kSecAttrAccount as String: "paired-laptop"]
    }

    static func load() throws -> RoomHelperCredential? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(RoomHelperCredential.self, from: data) else {
            throw RoomHelperError.keychain
        }
        return credential
    }

    static func save(_ credential: RoomHelperCredential) throws {
        let fields = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(credential)
        ] as [String: Any]
        var status = SecItemUpdate(item as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(fields) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RoomHelperError.keychain }
    }

    static func delete() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RoomHelperError.keychain }
    }
}

enum RoomHelperError: LocalizedError {
    case message(String), keychain, offline, trust, invalidResponse, tooLarge
    case http(Int, String?, String?)

    var errorDescription: String? {
        switch self {
        case let .message(text): text
        case .keychain: "Apple TV could not access the saved pairing. Try again."
        case .offline: "The laptop is unreachable. Wake it, start the helper, and check that both devices are on the same network."
        case .trust: "The laptop certificate does not match the pairing text. Check the helper identity on your laptop before pairing again."
        case .invalidResponse: "The helper sent an unreadable response. Check the helper version on your laptop."
        case .tooLarge: "The helper response exceeds the size limit."
        case .http(401, _, _): "This pairing has expired or was revoked. Pair this Apple TV again."
        case .http(403, "invalid_pairing", _): "The pairing code is incorrect or expired. Get fresh pairing text from your laptop."
        case .http(429, "busy", _): "The helper is answering another request. Try again in a moment."
        case let .http(429, _, detail): detail ?? "The helper received too many requests. Wait a moment and try again."
        case .http(504, _, _): "The helper timed out. Try asking again."
        case let .http(code, _, detail): detail ?? "The helper could not complete the request (HTTP \(code))."
        }
    }
}

/// The helper serves one fixed-length JSON response per TLS connection.
struct RoomHelperHTTPResponse {
    private var buffer = Data()
    private var head: (status: Int, length: Int)?
    private static let separator = Data([13, 10, 13, 10])

    mutating func receive(_ chunk: Data, end: Bool, limit: Int) throws -> Data? {
        buffer.append(chunk)
        if head == nil {
            guard let divider = buffer.range(of: Self.separator) else {
                guard buffer.count <= 8192, !end else { throw RoomHelperError.invalidResponse }
                return nil
            }
            guard divider.upperBound <= 8192,
                  let text = String(data: buffer[..<divider.lowerBound], encoding: .ascii) else {
                throw RoomHelperError.invalidResponse
            }
            head = try Self.parseHead(text, limit: limit)
            buffer = Data(buffer[divider.upperBound...])
        }
        guard let head, buffer.count <= head.length else { throw RoomHelperError.invalidResponse }
        guard buffer.count == head.length else {
            if end { throw RoomHelperError.invalidResponse }
            return nil
        }
        guard (200..<300).contains(head.status) else {
            let failure = try? JSONDecoder().decode(RoomHelperTransport.Failure.self, from: buffer)
            throw RoomHelperError.http(head.status, failure?.error, RoomHelperTransport.shortDetail(failure?.detail))
        }
        return buffer
    }

    private static func parseHead(_ text: String, limit: Int) throws -> (Int, Int) {
        let lines = text.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(statusLine[0]),
              statusLine[1].utf8.count == 3, statusLine[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(statusLine[1]), (200...599).contains(status) else { throw RoomHelperError.invalidResponse }
        guard !(300..<400).contains(status) else { throw RoomHelperError.http(status, nil, "The helper returned a redirect.") }
        var length: Int?
        for line in lines.dropFirst() {
            guard line.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw RoomHelperError.invalidResponse }
            let key = line[..<colon].lowercased()
            guard key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  key != "transfer-encoding", key != "content-encoding" else { throw RoomHelperError.invalidResponse }
            if key == "content-length" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(value) else { throw RoomHelperError.invalidResponse }
                length = count
            }
        }
        guard let length else { throw RoomHelperError.invalidResponse }
        guard length <= ((200..<300).contains(status) ? limit : 8192) else { throw RoomHelperError.tooLarge }
        return (status, length)
    }
}

enum RoomHelperTransport {
    static func fingerprint(of certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    static func accepts(_ trust: SecTrust, fingerprint: String) -> Bool {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
        return Self.fingerprint(of: SecCertificateCopyData(leaf) as Data) == fingerprint
    }

    struct Failure: Decodable {
        let error: String?
        let detail: String?
    }

    /// Use only the validated numeric address from Bonjour. Network.framework opens a fresh TLS connection for each request.
    static func send(base: URL, path: String, fingerprint: String, token: String?, body: Data?,
                     timeout: TimeInterval, limit: Int) async throws -> Data {
        guard base.scheme == "https", let rawHost = base.host(percentEncoded: false),
              let portNumber = base.port, let rawPort = UInt16(exactly: portNumber), rawPort != 0,
              let port = NWEndpoint.Port(rawValue: rawPort) else { throw RoomHelperError.offline }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard RoomHelperDiscovery.isLANHost(host) else { throw RoomHelperError.offline }
        let endpoint = NWEndpoint.Host(host)
        switch endpoint {
        case .ipv4, .ipv6: break
        default: throw RoomHelperError.offline
        }
        let fixedPaths = ["v1/pair", "v1/ask", "v1/status"]
        guard fixedPaths.contains(path) || (path.hasPrefix("v1/captions/") && RoomAIValidation.validID(String(path.dropFirst("v1/captions/".count)))) else {
            throw RoomHelperError.invalidResponse
        }
        let authority = host.contains(":") ? "[\(host.prefix { $0 != "%" })]:\(portNumber)" : "\(host):\(portNumber)"
        var headers = ["\(body == nil ? "GET" : "POST") /\(path) HTTP/1.1", "Host: " + authority, "Connection: close", "Accept: application/json"]
        if let token {
            guard (1...512).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RoomHelperError.keychain }
            headers.append("Authorization: Bearer " + token)
        }
        if let body {
            guard body.count <= 192 * 1024 else { throw RoomHelperError.message("The request exceeds the helper’s size limit.") }
            headers += ["Content-Type: application/json", "Content-Length: \(body.count)"]
        }
        var request = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { request.append(body) }
        let exchange = RoomHelperTLSConnection(host: endpoint, port: port, fingerprint: fingerprint)
        return try await exchange.run(request: request, timeout: timeout, limit: limit)
    }

    static func shortDetail(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(260))
    }
}

// All mutable exchange state is confined to queue. Each exchange owns exactly one connection and continuation.
private final class RoomHelperTLSConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FreeTube.helper.tls")
    private let connection: NWConnection
    private let pinCheck = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private var continuation: CheckedContinuation<Data, Error>?
    private var deadline: DispatchWorkItem?
    private var cancelled = false
    private var response = RoomHelperHTTPResponse()

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, fingerprint: String) {
        let tls = NWProtocolTLS.Options()
        let settings = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(settings, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(settings, false)
        sec_protocol_options_set_tls_tickets_enabled(settings, false)
        sec_protocol_options_set_tls_false_start_enabled(settings, false)
        sec_protocol_options_set_verify_block(settings, { [pinCheck] _, presented, complete in
            let trust = sec_trust_copy_ref(presented).takeRetainedValue()
            let matches = RoomHelperTransport.accepts(trust, fingerprint: fingerprint)
            pinCheck.withLock { $0 = matches }
            complete(matches)
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        connection = NWConnection(host: host, port: port, using: parameters)
    }

    func run(request: Data, timeout: TimeInterval, limit: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                queue.async {
                    guard !self.cancelled else { reply.resume(throwing: CancellationError()); return }
                    self.continuation = reply
                    let deadline = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(RoomHelperError.message("The laptop took too long to respond. Check the helper and try again.")))
                    }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self, self.continuation != nil else { return }
                        switch state {
                        case .ready:
                            guard self.pinCheck.withLock({ $0 }) == true else { self.finish(.failure(RoomHelperError.trust)); return }
                            self.connection.requestEstablishmentReport(queue: self.queue) { [weak self] report in
                                guard let self, self.continuation != nil else { return }
                                guard report?.usedProxy == false else { self.finish(.failure(RoomHelperError.offline)); return }
                                self.connection.send(content: request, completion: .contentProcessed { error in
                                    if let error { self.fail(error) }
                                    else { self.receive(limit: limit) }
                                })
                            }
                        case .failed(let error), .waiting(let error): self.fail(error)
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func receive(limit: Int) {
        guard continuation != nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, end, error in
            do {
                if let complete = try self.response.receive(data ?? Data(), end: end, limit: limit) {
                    self.finish(.success(complete))
                } else if let error { self.fail(error) }
                else { self.receive(limit: limit) }
            } catch { self.finish(.failure(error)) }
        }
    }

    private func fail(_ error: NWError) {
        if pinCheck.withLock({ $0 }) == false {
            finish(.failure(RoomHelperError.trust))
        } else if case .tls = error {
            finish(.failure(RoomHelperError.message("The laptop could not establish a secure connection. Check the helper’s TLS configuration.")))
        } else {
            finish(.failure(RoomHelperError.offline))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
