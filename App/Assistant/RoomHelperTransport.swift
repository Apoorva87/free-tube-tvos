import CryptoKit
import Foundation
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

final class RoomHelperTrustDelegate: NSObject, URLSessionTaskDelegate {
    let fingerprint: String
    let host: String
    let rejected = OSAllocatedUnfairLock(initialState: false)

    init(fingerprint: String, host: String) {
        self.fingerprint = fingerprint
        self.host = host
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        guard accepts(space.serverTrust, from: space.host), let trust = space.serverTrust else {
            rejected.withLock { $0 = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func accepts(_ trust: SecTrust?, from challengeHost: String) -> Bool {
        let peer = challengeHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard peer == host || peer.removingPercentEncoding == host, let trust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
        return RoomHelperTransport.fingerprint(of: SecCertificateCopyData(leaf) as Data) == fingerprint
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum RoomHelperTransport {
    static func fingerprint(of certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    struct Failure: Decodable {
        let error: String?
        let detail: String?
    }

    /// The base URL is constructed exclusively from an address returned by local Bonjour discovery.
    static func send(base: URL, path: String, fingerprint: String, token: String?, body: Data?,
                     timeout: TimeInterval, limit: Int) async throws -> Data {
        guard let host = base.host(percentEncoded: false), base.scheme == "https" else { throw RoomHelperError.offline }
        let numericHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard RoomHelperDiscovery.isLANHost(numericHost) else { throw RoomHelperError.offline }
        let delegate = RoomHelperTrustDelegate(fingerprint: fingerprint, host: numericHost)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }

        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw RoomHelperError.invalidResponse }
                let succeeded = (200..<300).contains(http.statusCode)
                let maxSize = succeeded ? limit : 8192
                guard http.expectedContentLength <= maxSize else { throw RoomHelperError.tooLarge }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maxSize else { throw RoomHelperError.tooLarge }
                    data.append(byte)
                    if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
                }
                try Task.checkCancellation()
                guard succeeded else {
                    let failure = try? JSONDecoder().decode(Failure.self, from: data)
                    throw RoomHelperError.http(http.statusCode, failure?.error, shortDetail(failure?.detail))
                }
                return data
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if delegate.rejected.withLock({ $0 }) { throw RoomHelperError.trust }
            if let network = error as? URLError {
                if network.code == .timedOut {
                    throw RoomHelperError.message("The laptop took too long to respond. Check the helper and try again.")
                }
                throw RoomHelperError.offline
            }
            throw error
        }
    }

    static func shortDetail(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(260))
    }
}
