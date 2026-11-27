import Foundation

enum ChannelAccountError: LocalizedError {
    case signedOut, expired, malformed, missingRefreshToken
    case oauth(String)
    case service(Int)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to connect your YouTube account."
        case .expired, .oauth("expired_token"): "This code expired. Request a new code to continue."
        case .malformed: "Google returned an unreadable sign-in response. Try again."
        case .missingRefreshToken: "Google did not grant ongoing access. Sign in again."
        case .oauth("access_denied"): "You declined the sign-in request."
        case .oauth("invalid_client"), .oauth("unauthorized_client"):
            "Google rejected this build’s OAuth client. Check the TV client ID and secret."
        case .oauth("invalid_grant"): "Your Google authorization expired. Sign in again."
        case .oauth("admin_policy_enforced"), .oauth("org_internal"):
            "Your organization restricts access to this app."
        case .oauth("invalid_scope"): "This Google client cannot request read-only YouTube access."
        case .oauth("rate_limit_exceeded"), .service(429): "Google has limited sign-in requests. Try again later."
        case .oauth: "Google could not authorize this request. Try again."
        case .service(let status): "Google sign-in returned HTTP \(status). Try again."
        }
    }
}

struct ChannelDeviceCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: URL
    let expiresIn: TimeInterval
    let interval: TimeInterval?

    static func scanURL(for verificationURL: URL, userCode: String) -> URL {
        guard var link = URLComponents(url: verificationURL, resolvingAgainstBaseURL: false),
              link.scheme == "https", link.host == "www.google.com", link.path == "/device",
              link.query == nil else { return verificationURL }
        link.queryItems = [URLQueryItem(name: "user_code", value: userCode)]
        return link.url ?? verificationURL
    }
}

struct ChannelTokenGrant: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let tokenType: String
    let scope: String?
}

struct ChannelOAuthClient: Sendable {
    static let scope = "https://www.googleapis.com/auth/youtube.readonly"
    let clientID: String
    let clientSecret: String
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    static func configured(in bundle: Bundle) -> Self? {
        func value(for key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.contains("$(") ? nil : value
        }
        guard let id = value(for: "freeTubeGoogleClientID"),
              let secret = value(for: "freeTubeGoogleClientSecret") else { return nil }
        return Self(clientID: id, clientSecret: secret)
    }

    func requestCode() async throws -> ChannelDeviceCode {
        let result: ChannelDeviceCode = try await post("/device/code", ["client_id": clientID, "scope": Self.scope])
        guard !result.deviceCode.isEmpty, !result.userCode.isEmpty, result.expiresIn > 0,
              result.verificationUrl.scheme?.lowercased() == "https", result.verificationUrl.host != nil else {
            throw ChannelAccountError.malformed
        }
        return result
    }

    func exchange(deviceCode: String) async throws -> ChannelTokenGrant {
        try await token(["device_code": deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
    }

    func refresh(_ refreshToken: String) async throws -> ChannelTokenGrant {
        try await token(["refresh_token": refreshToken, "grant_type": "refresh_token"])
    }

    private func token(_ parameters: [String: String]) async throws -> ChannelTokenGrant {
        var fields = parameters
        fields["client_id"] = clientID
        fields["client_secret"] = clientSecret
        let grant: ChannelTokenGrant = try await post("/token", fields)
        guard !grant.accessToken.isEmpty, grant.expiresIn > 0, grant.tokenType.lowercased() == "bearer" else {
            throw ChannelAccountError.malformed
        }
        if let scopes = grant.scope, !scopes.split(separator: " ").contains(Substring(Self.scope)) {
            throw ChannelAccountError.oauth("invalid_scope")
        }
        return grant
    }

    private func post<T: Decodable>(_ path: String, _ fields: [String: String]) async throws -> T {
        let endpoint = URL(string: "https://oauth2.googleapis.com")!.appending(path: String(path.dropFirst()))
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw ChannelAccountError.malformed }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? decoder.decode(GoogleError.self, from: data),
               let code = error.error ?? error.errorCode { throw ChannelAccountError.oauth(code) }
            throw ChannelAccountError.service(response.statusCode)
        }
        guard let result = try? decoder.decode(T.self, from: data) else { throw ChannelAccountError.malformed }
        return result
    }

    private struct GoogleError: Decodable {
        let error: String?
        let errorCode: String?
    }
}
