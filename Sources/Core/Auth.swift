import CryptoKit
import Foundation

/// How an account signs in. Each kind has one native sheet in Settings; the provider supplies only what differs.
enum Auth: Sendable {
    /// OAuth 2.0 authorization code with PKCE, in an ephemeral browser window, redirected to a loopback port.
    case oauth(OAuthPKCE)
    /// OAuth 2.0 device authorization (RFC 8628): a code to enter at a verification URL, polled until approved.
    case deviceCode(DeviceCodeFlow)
    /// A pasted secret (an API or admin key) with optional extra fields.
    case secret(SecretForm)
    /// Sign-in in an in-app web view, keeping one named cookie. The web view and its per-account, isolated data
    /// store exist only while signing in.
    case web(WebLogin)

    /// Renews an expiring credential, for the kinds that issue refresh tokens.
    var refresh: (@Sendable (Credential, HTTP) async throws(FetchFailure) -> Credential)? {
        switch self {
        case .oauth(let config): { credential, http throws(FetchFailure) in try await config.refresh(credential, http: http) }
        case .deviceCode(let flow): flow.refresh
        case .secret, .web: nil
        }
    }
}

// MARK: OAuth with PKCE

/// An OAuth 2.0 authorization-code server, used with PKCE and a loopback redirect.
struct OAuthPKCE: Sendable {
    let clientID: String
    let authorize: URL
    let token: URL
    /// Tried in order: a later, broader set only if the server refuses the one before (`invalid_scope`).
    let scopes: [String]
    /// A page that shows the code to paste, for when no loopback port can be opened.
    var manualRedirect: String? = nil
    /// Added to the authorization URL before the standard parameters.
    var extraQuery: [URLQueryItem] = []
    /// The token endpoint takes JSON rather than a form.
    var jsonBody = false
    /// Sent along with the state in the exchange (some servers want it).
    var sendsState = false

    /// A PKCE verifier and `state`, fresh for every sign-in.
    struct Attempt: Sendable {
        let verifier: String
        let state: String
        var challenge: String { OAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

        init(verifier: String = OAuth.randomToken(), state: String = OAuth.randomToken()) {
            self.verifier = verifier
            self.state = state
        }
    }

    func authorizeURL(_ attempt: Attempt, redirect: String, scope: String) -> URL {
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = extraQuery + [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: attempt.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: attempt.state),
        ]
        return components.url!
    }

    func exchangeBody(code: String, attempt: Attempt, redirect: String) -> [String: String] {
        var body = ["grant_type": "authorization_code", "code": code, "client_id": clientID, "redirect_uri": redirect,
                    "code_verifier": attempt.verifier]
        if sendsState { body["state"] = attempt.state }
        return body
    }

    func refreshBody(_ refreshToken: String) -> [String: String] {
        ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
    }

    /// Exchanges an authorization code.
    func exchange(code: String, attempt: Attempt, redirect: String, http: HTTP) async throws(FetchFailure) -> Credential {
        try await OAuth.token(url: token, body: exchangeBody(code: code, attempt: attempt, redirect: redirect), json: jsonBody,
                              previousRefresh: nil, http: http)
    }

    /// Renews a credential with its refresh token. A rejected grant means signing in again.
    func refresh(_ credential: Credential, http: HTTP) async throws(FetchFailure) -> Credential {
        guard let refresh = credential.refresh else { throw .signInRequired }
        var renewed = try await OAuth.token(url: token, body: refreshBody(refresh), json: jsonBody, previousRefresh: refresh,
                                            http: http)
        renewed.fields = credential.fields
        return renewed
    }
}

/// OAuth helpers shared by every server.
enum OAuth {
    /// What came back to the redirect URI.
    enum Callback: Equatable, Sendable {
        case code(String)
        /// The server's `error`, such as `access_denied` or `invalid_scope`.
        case denied(String)
        /// The state didn't match: not a response to this sign-in.
        case foreign
    }

    /// Reads the query of a redirect to `/callback`.
    static func callback(query: String?, expecting state: String) -> Callback {
        let items = URLComponents(string: "?" + (query ?? ""))?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let received = value("state"), constantTimeEqual(received, state) else { return .foreign }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        return .denied(value("error") ?? "no_code")
    }

    /// Reads the "code#state" that a manual redirect page shows.
    static func pasted(_ text: String, expecting state: String) -> Callback {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard parts.count == 2, constantTimeEqual(String(parts[1]), state), !parts[0].isEmpty else { return .foreign }
        return .code(String(parts[0]))
    }

    /// Whether a token endpoint answer means the grant itself was refused (an OAuth error object such as
    /// `invalid_grant`), so only signing in again helps. A 400 or 403 without one (a proxy's or firewall's page) is a
    /// server problem to retry: treating it as a refusal would throw away a refresh token that still works.
    static func rejectsGrant(status: Int, body: Data) -> Bool {
        switch status {
        case 401: return true
        case 400, 403:
            struct Error: Decodable { let error: String }
            return (try? JSONDecoder().decode(Error.self, from: body)) != nil
        default: return false
        }
    }

    /// Decodes a token endpoint's response. A refresh may omit the refresh token, which then stays as it was.
    static func credential(_ data: Data, previousRefresh: String? = nil, now: Date = Date()) throws -> Credential {
        struct Raw: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let refresh = raw.refresh_token ?? previousRefresh else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no refresh token"))
        }
        return Credential(secret: raw.access_token, refresh: refresh, expiresAt: now.addingTimeInterval(raw.expires_in ?? 3600))
    }

    /// One request to a token endpoint.
    static func token(url: URL, body: [String: String], json: Bool, previousRefresh: String?,
                      http: HTTP) async throws(FetchFailure) -> Credential {
        var request = URLRequest(url, method: "POST")
        if json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form(body).utf8)
        }
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300:
            do { return try credential(data, previousRefresh: previousRefresh) } catch { throw .unreadable }
        case let status where rejectsGrant(status: status, body: data): throw .signInRequired
        case 429: throw .rateLimited(Backoff.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default: throw .server(response.statusCode)
        }
    }

    /// `application/x-www-form-urlencoded`, keys sorted so a body is reproducible.
    static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)="
                + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: Device code

/// OAuth 2.0 device authorization: the provider hands out a short code, the user enters it at a URL in any browser,
/// and Tidemark polls until it is approved, denied or expired.
struct DeviceCodeFlow: Sendable {
    let start: @Sendable (HTTP) async throws(FetchFailure) -> DeviceCode
    let poll: @Sendable (DeviceCode, HTTP) async throws(FetchFailure) -> DevicePoll
    var refresh: (@Sendable (Credential, HTTP) async throws(FetchFailure) -> Credential)? = nil

    /// The standard flow (RFC 8628) against `deviceURL` and `tokenURL`.
    static func standard(clientID: String, deviceURL: URL, tokenURL: URL, scope: String, refreshes: Bool = true) -> DeviceCodeFlow {
        let refresh: @Sendable (Credential, HTTP) async throws(FetchFailure) -> Credential = { credential, http throws(FetchFailure) in
            guard let refresh = credential.refresh else { throw .signInRequired }
            return try await OAuth.token(url: tokenURL, body: ["grant_type": "refresh_token", "refresh_token": refresh,
                                                               "client_id": clientID],
                                         json: false, previousRefresh: refresh, http: http)
        }
        return DeviceCodeFlow(
            start: { http throws(FetchFailure) in
                var request = URLRequest(deviceURL, method: "POST")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(OAuth.form(["client_id": clientID, "scope": scope]).utf8)
                return try await http.decode(request) { try DeviceCode.decode($0) }
            },
            poll: { code, http throws(FetchFailure) in
                var request = URLRequest(tokenURL, method: "POST")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(OAuth.form(["client_id": clientID, "device_code": code.deviceCode,
                                                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]).utf8)
                let (data, response) = try await http.send(request)
                return try DevicePoll.decode(status: response.statusCode, body: data)
            },
            refresh: refreshes ? refresh : nil)
    }
}

/// What the device authorization endpoint handed out.
struct DeviceCode: Equatable, Sendable {
    /// Sent with every poll; never shown.
    let deviceCode: String
    /// What the user types: "WDJB-MJHT".
    let userCode: String
    let verificationURL: URL
    /// The URL with the code filled in, when the provider offers one.
    var completeURL: URL? = nil
    /// Seconds between polls.
    var interval: TimeInterval = 5
    var expiresAt: Date

    static func decode(_ data: Data, now: Date = Date()) throws -> DeviceCode {
        struct Raw: Decodable {
            let device_code: String
            let user_code: String
            let verification_uri: String?
            let verification_url: String?
            let verification_uri_complete: String?
            let interval: Double?
            let expires_in: Double?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let link = (raw.verification_uri ?? raw.verification_url).flatMap(URL.init(string:)), link.scheme == "https"
        else { throw FetchFailure.unreadable }
        return DeviceCode(deviceCode: raw.device_code, userCode: raw.user_code, verificationURL: link,
                          completeURL: raw.verification_uri_complete.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                          interval: max(raw.interval ?? 5, 1), expiresAt: now.addingTimeInterval(raw.expires_in ?? 900))
    }
}

/// One poll's answer.
enum DevicePoll: Equatable, Sendable {
    case pending
    /// Poll less often: 5 seconds more, as RFC 8628 says.
    case slowDown
    case approved(Credential)
    case denied
    case expired

    static func decode(status: Int, body: Data) throws(FetchFailure) -> DevicePoll {
        if (200..<300).contains(status) {
            do { return .approved(try OAuth.credential(body)) } catch { throw .unreadable }
        }
        struct Raw: Decodable { let error: String }
        guard let error = try? JSONDecoder().decode(Raw.self, from: body).error else {
            throw status == 429 ? .rateLimited(nil) : .server(status)
        }
        switch error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default: throw .server(status)
        }
    }
}

// MARK: Pasted secrets

/// A sheet asking for a secret and any extra fields, checked with the provider (`Login.identify`) before anything is
/// saved.
struct SecretForm: Sendable {
    /// "Add a Console Organisation".
    let title: String
    /// Why the secret is needed and where to get it.
    let intro: String
    /// Shown with a warning sign: what the secret allows.
    var warning: String? = nil
    let fields: [Field]
    /// Under the fields.
    var footnote = "Stored in your Keychain on this Mac only."
    /// A problem Tidemark can tell without asking the provider (a key of the wrong kind), from the cleaned values.
    var validate: @Sendable ([String: String]) -> String? = { _ in nil }
    /// What a failed check means, for the sheet.
    var explain: @Sendable (FetchFailure) -> String? = { _ in nil }

    struct Field: Sendable, Identifiable {
        enum Kind: Sendable {
            /// A secret, in a secure field. The first is the credential's secret; a further one (an optional second
            /// key) is kept with the other fields, in the Keychain all the same.
            case secret
            case text
            /// A pop-up: (value, title) pairs, the first chosen by default.
            case choice([(value: String, title: String)])
        }
        let id: String
        let label: String
        var placeholder = ""
        let kind: Kind
        var optional = false
    }

    /// Whitespace isn't part of a key: pasted line breaks and spaces are dropped from the secret and trimmed from
    /// the other fields.
    static func clean(_ text: String, secret: Bool) -> String {
        secret ? text.filter { !$0.isWhitespace && !$0.isNewline } : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The credential the values make: the first secret field's value, the others as fields.
    func credential(_ values: [String: String]) -> Credential {
        let first = fields.first { if case .secret = $0.kind { true } else { false } }?.id
        var secret = "", extra: [String: String] = [:]
        for field in fields {
            guard let value = values[field.id], !value.isEmpty else { continue }
            if field.id == first { secret = value } else { extra[field.id] = value }
        }
        return Credential(secret: secret, fields: extra)
    }
}

// MARK: Web sign-in

/// Sign-in in an in-app web view, keeping the value of one cookie as the credential. The web view's data store is
/// isolated per account (`WKWebsiteDataStore(forIdentifier:)`, its id kept in the credential's `webStore` field), so
/// no other app's or account's cookies are ever seen.
struct WebLogin: Sendable {
    /// Where sign-in starts.
    let start: URL
    /// The cookie to keep.
    let cookie: String
    /// The cookie's domain, without a leading dot: "example.com" also matches "app.example.com".
    let domain: String
    /// Under the sheet's title: what to know before signing in (a way of signing in that can't work in it).
    var note: String? = nil

    /// The credential field holding the account's data store id.
    static let storeField = "webStore"

    func matches(name: String, domain cookieDomain: String) -> Bool {
        let host = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return name == cookie && (host == domain || host.hasSuffix("." + domain))
    }
}
