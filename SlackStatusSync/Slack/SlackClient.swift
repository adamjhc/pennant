import Foundation

public enum SlackRequiredScopes {
    public static let all: Set<String> = [
        "users.profile:read",
        "users.profile:write",
        "dnd:read",
        "dnd:write",
    ]
}

public enum SlackClientError: Error, Equatable, Sendable {
    case invalidTokenFormat
    case missingScopes(Set<String>)
    case apiError(String)
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case transport(String)
    case decoding(String)
    case permanentAuth(String)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport:
            return true
        case .httpStatus(let code):
            return code == 429 || code >= 500
        default:
            return false
        }
    }

    public var redactedDescription: String {
        switch self {
        case .invalidTokenFormat:
            return "invalid_token_format"
        case .missingScopes(let scopes):
            return "missing_scopes:\(scopes.sorted().joined(separator: ","))"
        case .apiError(let code):
            return "api_error:\(code)"
        case .httpStatus(let code):
            return "http_status:\(code)"
        case .rateLimited:
            return "rate_limited"
        case .transport:
            return "transport_error"
        case .decoding:
            return "decoding_error"
        case .permanentAuth(let code):
            return "auth_error:\(code)"
        }
    }
}

public struct SlackAuthTestResult: Equatable, Sendable {
    public var userID: String
    public var team: String
    public var scopes: Set<String>

    public init(userID: String, team: String, scopes: Set<String>) {
        self.userID = userID
        self.team = team
        self.scopes = scopes
    }
}

public protocol SlackClientProtocol: Sendable {
    func authTest(token: String) async throws -> SlackAuthTestResult
    func getProfile(token: String) async throws -> RemoteSlackProfile
    func setStatus(token: String, text: String, emoji: String, expiration: Date) async throws
    func clearStatus(token: String) async throws
    func getDND(token: String) async throws -> RemoteDNDState
    func setSnooze(token: String, numMinutes: Int) async throws -> Date
    func endSnooze(token: String) async throws
}

public final class SlackClient: SlackClientProtocol, @unchecked Sendable {
    private let sessionLock = NSLock()
    private var session: URLSession
    private let ownsSession: Bool
    private let baseURL: URL

    public init(session: URLSession? = nil, baseURL: URL = URL(string: "https://slack.com/api")!) {
        self.session = session ?? Self.makeSession()
        self.ownsSession = session == nil
        self.baseURL = baseURL
    }

    /// Discard connections retained across sleep so the next request negotiates
    /// against the current network path. Injected test sessions are left intact.
    public func resetNetworkSession() {
        guard ownsSession else { return }
        let replacement = Self.makeSession()
        sessionLock.lock()
        let previous = session
        session = replacement
        sessionLock.unlock()
        previous.invalidateAndCancel()
    }

    public static func validateTokenFormat(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("xoxp-") && trimmed.count > 10
    }

    public func verifyToken(_ token: String) async throws -> SlackAuthTestResult {
        guard Self.validateTokenFormat(token) else {
            throw SlackClientError.invalidTokenFormat
        }
        let result = try await authTest(token: token)
        let missing = SlackRequiredScopes.all.subtracting(result.scopes)
        if !missing.isEmpty {
            throw SlackClientError.missingScopes(missing)
        }
        return result
    }

    public func authTest(token: String) async throws -> SlackAuthTestResult {
        let (data, response) = try await post(method: "auth.test", token: token, form: [:])
        let json = try decodeJSON(data)
        try throwIfNotOK(json, response: response)
        let scopes = Self.parseScopes(from: response)
        return SlackAuthTestResult(
            userID: json["user_id"] as? String ?? "",
            team: json["team"] as? String ?? "",
            scopes: scopes
        )
    }

    public func getProfile(token: String) async throws -> RemoteSlackProfile {
        let (data, response) = try await post(method: "users.profile.get", token: token, form: [:])
        let json = try decodeJSON(data)
        try throwIfNotOK(json, response: response)
        let profile = json["profile"] as? [String: Any] ?? [:]
        let exp = profile["status_expiration"] as? Int
        return RemoteSlackProfile(
            statusText: profile["status_text"] as? String ?? "",
            statusEmoji: profile["status_emoji"] as? String ?? "",
            statusExpiration: exp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        )
    }

    public func setStatus(token: String, text: String, emoji: String, expiration: Date) async throws {
        let profile: [String: Any] = [
            "status_text": text,
            "status_emoji": emoji,
            "status_expiration": DecisionEngine.statusExpirationUnix(end: expiration),
        ]
        let profileData = try JSONSerialization.data(withJSONObject: profile)
        let profileString = String(data: profileData, encoding: .utf8) ?? "{}"
        let (data, response) = try await post(
            method: "users.profile.set",
            token: token,
            form: ["profile": profileString]
        )
        let json = try decodeJSON(data)
        try throwIfNotOK(json, response: response)
    }

    public func clearStatus(token: String) async throws {
        try await setStatus(token: token, text: "", emoji: "", expiration: Date(timeIntervalSince1970: 0))
    }

    public func getDND(token: String) async throws -> RemoteDNDState {
        let (data, response) = try await post(method: "dnd.info", token: token, form: [:])
        let json = try decodeJSON(data)
        try throwIfNotOK(json, response: response)
        let enabled = json["snooze_enabled"] as? Bool ?? false
        let end = json["snooze_endtime"] as? Int
        return RemoteDNDState(
            snoozeEnabled: enabled,
            snoozeEnd: enabled ? end.map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        )
    }

    public func setSnooze(token: String, numMinutes: Int) async throws -> Date {
        let (data, response) = try await post(
            method: "dnd.setSnooze",
            token: token,
            form: ["num_minutes": String(max(1, numMinutes))]
        )
        let json = try decodeJSON(data)
        try throwIfNotOK(json, response: response)
        if let end = json["snooze_endtime"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(end))
        }
        return Date().addingTimeInterval(TimeInterval(max(1, numMinutes) * 60))
    }

    public func endSnooze(token: String) async throws {
        let (data, response) = try await post(method: "dnd.endSnooze", token: token, form: [:])
        let json = try decodeJSON(data)
        try throwIfNotOK(json, response: response)
    }

    // MARK: - HTTP

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func currentSession() -> URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return session
    }

    private func post(
        method: String,
        token: String,
        form: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let url = baseURL.appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = form
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let requestStartedAt = Date()
        AppLogger.info("Slack request started method=\(method)", category: "slack")
        do {
            let (data, response) = try await currentSession().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SlackClientError.transport("non_http_response")
            }
            let durationMs = Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
            AppLogger.info(
                "Slack response method=\(method) status=\(http.statusCode) durationMs=\(durationMs)",
                category: "slack"
            )
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw SlackClientError.rateLimited(retryAfter: retry)
            }
            if http.statusCode >= 500 {
                throw SlackClientError.httpStatus(http.statusCode)
            }
            if http.statusCode >= 400 {
                throw SlackClientError.httpStatus(http.statusCode)
            }
            return (data, http)
        } catch let error as SlackClientError {
            AppLogger.error(
                "Slack request failed method=\(method) reason=\(error.redactedDescription)",
                category: "slack"
            )
            throw error
        } catch {
            let errorCode = error as NSError
            AppLogger.error(
                "Slack request failed method=\(method) error=\(errorCode.domain):\(errorCode.code)",
                category: "slack"
            )
            throw SlackClientError.transport(error.localizedDescription)
        }
    }

    private func decodeJSON(_ data: Data) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SlackClientError.decoding("root_not_object")
            }
            return json
        } catch let error as SlackClientError {
            throw error
        } catch {
            throw SlackClientError.decoding(error.localizedDescription)
        }
    }

    private func throwIfNotOK(_ json: [String: Any], response: HTTPURLResponse) throws {
        if json["ok"] as? Bool == true { return }
        let errorCode = json["error"] as? String ?? "unknown_error"
        switch errorCode {
        case "invalid_auth", "token_revoked", "account_inactive", "not_authed", "missing_scope":
            throw SlackClientError.permanentAuth(errorCode)
        default:
            throw SlackClientError.apiError(errorCode)
        }
    }

    public static func parseScopes(from response: HTTPURLResponse) -> Set<String> {
        let header = response.value(forHTTPHeaderField: "X-OAuth-Scopes")
            ?? response.value(forHTTPHeaderField: "x-oauth-scopes")
            ?? ""
        let parts = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(parts.filter { !$0.isEmpty })
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Fake Slack client for tests.
public final class FakeSlackClient: SlackClientProtocol, @unchecked Sendable {
    public var profile = RemoteSlackProfile(statusText: "", statusEmoji: "", statusExpiration: nil)
    public var dnd = RemoteDNDState(snoozeEnabled: false, snoozeEnd: nil)
    public var authResult = SlackAuthTestResult(
        userID: "U1",
        team: "T1",
        scopes: SlackRequiredScopes.all
    )
    public var setStatusCalls: [(String, String, Date)] = []
    public var setSnoozeCalls: [Int] = []
    public var endSnoozeCalls = 0
    public var clearStatusCalls = 0
    public var getDNDError: Error?
    public var setStatusError: Error?
    public var setSnoozeError: Error?
    public var endSnoozeError: Error?
    public var authError: Error?
    public var getProfileError: Error?

    public init() {}

    public func authTest(token: String) async throws -> SlackAuthTestResult {
        if let authError { throw authError }
        return authResult
    }

    public func getProfile(token: String) async throws -> RemoteSlackProfile {
        if let getProfileError { throw getProfileError }
        return profile
    }

    public func setStatus(token: String, text: String, emoji: String, expiration: Date) async throws {
        if let setStatusError { throw setStatusError }
        setStatusCalls.append((text, emoji, expiration))
        profile = RemoteSlackProfile(statusText: text, statusEmoji: emoji, statusExpiration: expiration.timeIntervalSince1970 > 0 ? expiration : nil)
    }

    public func clearStatus(token: String) async throws {
        clearStatusCalls += 1
        try await setStatus(token: token, text: "", emoji: "", expiration: Date(timeIntervalSince1970: 0))
    }

    public func getDND(token: String) async throws -> RemoteDNDState {
        if let getDNDError { throw getDNDError }
        return dnd
    }

    public func setSnooze(token: String, numMinutes: Int) async throws -> Date {
        if let setSnoozeError { throw setSnoozeError }
        setSnoozeCalls.append(numMinutes)
        let end = Date().addingTimeInterval(TimeInterval(numMinutes * 60))
        dnd = RemoteDNDState(snoozeEnabled: true, snoozeEnd: end)
        return end
    }

    public func endSnooze(token: String) async throws {
        if let endSnoozeError { throw endSnoozeError }
        endSnoozeCalls += 1
        dnd = RemoteDNDState(snoozeEnabled: false, snoozeEnd: nil)
    }
}
