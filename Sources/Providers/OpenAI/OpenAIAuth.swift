import Foundation

// ChatGPT accounts sign in at auth.openai.com with the device-code flow that OpenAI's Codex clients use (its client
// id): Tidemark asks for a user code, the user enters it at auth.openai.com/codex/device, and once approved the poll
// hands back an authorization code with its PKCE verifier, exchanged for tokens like any authorization code. Refresh
// tokens rotate on every use: the renewed credential replaces the old one at once (`Model.renew`, one refresh per
// account at a time), and a refresh token that is reused, expired or revoked means signing in again.

enum ChatGPTAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    static let pollURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    /// The redirect URI the device flow's authorization code is bound to.
    static let deviceRedirect = "https://auth.openai.com/deviceauth/callback"

    /// Credential fields, from the ID token's claims: never the token itself.
    enum Field {
        static let id = "id", account = "account", email = "email", name = "name"
    }

    static let flow = DeviceCodeFlow(
        start: { http throws(FetchFailure) in
            let request = jsonRequest(userCodeURL, ["client_id": clientID])
            return try await http.decode(request) { try userCode($0) }
        },
        poll: { code, http throws(FetchFailure) in try await poll(code, http: http) },
        refresh: { credential, http throws(FetchFailure) in try await refresh(credential, http: http) })

    // MARK: Device code

    /// `POST /api/accounts/deviceauth/usercode`: `{device_auth_id, user_code, interval: "5", expires_at}`.
    static func userCode(_ data: Data, now: Date = Date()) throws -> DeviceCode {
        struct Raw: Decodable {
            let device_auth_id: String
            let user_code: String?
            let usercode: String?
            let interval: Wire.Number?
            let expires_at: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let user = raw.user_code ?? raw.usercode, !user.isEmpty, !raw.device_auth_id.isEmpty else {
            throw FetchFailure.unreadable
        }
        // The code lasts 15 minutes; a stated expiry is taken only when it is sensible.
        let stated = raw.expires_at.flatMap(ISO8601.date).flatMap { $0 > now && $0 < now + 3600 ? $0 : nil }
        return DeviceCode(deviceCode: raw.device_auth_id, userCode: user, verificationURL: verificationURL,
                          interval: min(max(raw.interval?.double ?? 5, 1), 60), expiresAt: stated ?? now + 900)
    }

    /// The authorization codes an approved poll handed out, kept until their exchange succeeds: the poll endpoint
    /// gives one out once, so a failed exchange (offline, a server error) is retried with it rather than lost.
    private actor Approved {
        var codes: [String: AuthorizationCode] = [:]
        func set(_ id: String, _ code: AuthorizationCode?) { codes[id] = code }
        func get(_ id: String) -> AuthorizationCode? { codes[id] }
    }
    private static let approved = Approved()

    struct AuthorizationCode: Sendable, Equatable {
        let code: String
        let verifier: String
    }

    /// One poll of `POST /api/accounts/deviceauth/token`: 403 or 404 while the user hasn't approved yet; then an
    /// authorization code and its PKCE verifier, exchanged here.
    static func poll(_ device: DeviceCode, http: HTTP) async throws(FetchFailure) -> DevicePoll {
        if let code = await approved.get(device.deviceCode) { return try await exchange(code, device: device, http: http) }
        let request = jsonRequest(pollURL, ["device_auth_id": device.deviceCode, "user_code": device.userCode])
        let (data, response) = try await http.send(request)
        switch try pollResult(status: response.statusCode, body: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After")) {
        case .approved(let code):
            await approved.set(device.deviceCode, code)
            return try await exchange(code, device: device, http: http)
        case .waiting(let poll):
            return poll
        }
    }

    enum PollResult: Equatable { case approved(AuthorizationCode), waiting(DevicePoll) }

    static func pollResult(status: Int, body: Data, retryAfter: String? = nil) throws(FetchFailure) -> PollResult {
        switch status {
        case 200..<300:
            struct Raw: Decodable { let authorization_code: String; let code_verifier: String }
            guard let raw = try? JSONDecoder().decode(Raw.self, from: body), !raw.authorization_code.isEmpty,
                  !raw.code_verifier.isEmpty else { throw .unreadable }
            return .approved(AuthorizationCode(code: raw.authorization_code, verifier: raw.code_verifier))
        case 403, 404:
            // "deviceauth_authorization_pending" while waiting; anything saying the code ended stops the sheet.
            let code = errorCode(body)?.lowercased() ?? ""
            if code.contains("expired") { return .waiting(.expired) }
            if code.contains("denied") || code.contains("declined") || code.contains("rejected") { return .waiting(.denied) }
            return .waiting(.pending)
        case 429: throw .rateLimited(Backoff.retryAfter(retryAfter))
        default: throw .server(status)
        }
    }

    private static func exchange(_ code: AuthorizationCode, device: DeviceCode, http: HTTP) async throws(FetchFailure) -> DevicePoll {
        let credential = try await token([
            "grant_type": "authorization_code", "client_id": clientID, "code": code.code,
            "redirect_uri": deviceRedirect, "code_verifier": code.verifier,
        ], json: false, previous: nil, http: http)
        await approved.set(device.deviceCode, nil)
        return .approved(credential)
    }

    // MARK: Tokens

    /// Renews a credential. The refresh token rotates: the answer's replaces it, and the ID token's claims (when a
    /// new one comes) replace the identity fields.
    static func refresh(_ credential: Credential, http: HTTP) async throws(FetchFailure) -> Credential {
        guard let refresh = credential.refresh else { throw .signInRequired }
        return try await token(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh],
                               json: true, previous: credential, http: http)
    }

    /// One request to the token endpoint: form-encoded for the code exchange, JSON for a refresh, as Codex sends them.
    private static func token(_ body: [String: String], json: Bool, previous: Credential?,
                              http: HTTP) async throws(FetchFailure) -> Credential {
        var request: URLRequest
        if json {
            request = jsonRequest(tokenURL, body)
        } else {
            request = URLRequest(tokenURL, method: "POST")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(OAuth.form(body).utf8)
        }
        let (data, response) = try await http.send(request)
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            if rejectsGrant(status: status, body: data) { throw .signInRequired }
            if status == 429 { throw .rateLimited(Backoff.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))) }
            throw .server(status)
        }
        do { return try credential(data, previous: previous) } catch { throw .unreadable }
    }

    /// Whether a token endpoint's refusal means only signing in again helps, as Codex judges it: any 401, a refresh
    /// token reported expired, reused or revoked, or a 400 `invalid_grant`. Other refusals (a proxy's page, a 5xx)
    /// keep the refresh token, which may still work.
    static func rejectsGrant(status: Int, body: Data) -> Bool {
        if status == 401 { return true }
        guard (400..<500).contains(status), let code = errorCode(body)?.lowercased() else { return false }
        if ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code) { return true }
        return status == 400 && code == "invalid_grant"
    }

    /// The error code of an OpenAI or OAuth error body: `{"error":"invalid_grant"}`, `{"error":{"code":…}}` or
    /// `{"code":…}`.
    static func errorCode(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let code = (object["error"] as? [String: Any])?["code"] as? String, !code.isEmpty { return code }
        return (object["code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A token response: `{id_token, access_token, refresh_token}`. The access token is a JWT whose `exp` says when
    /// it expires (`expires_in` when it doesn't); a refresh that omits a refresh token or an ID token keeps the
    /// previous one's.
    static func credential(_ data: Data, previous: Credential?, now: Date = Date()) throws -> Credential {
        struct Raw: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
            let expires_in: Wire.Number?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard !raw.access_token.isEmpty, let refresh = raw.refresh_token.flatMap({ $0.isEmpty ? nil : $0 }) ?? previous?.refresh
        else { throw FetchFailure.unreadable }
        let expiry = OpenAI.JWT.expiry(raw.access_token) ?? raw.expires_in.map { now + $0.double }
        var fields = previous?.fields ?? [:]
        if let claims = raw.id_token.flatMap(Claims.init(idToken:)) { fields.merge(claims.fields) { _, new in new } }
        guard fields[Field.id] != nil else { throw FetchFailure.unreadable }      // no ID token ever: nobody to show
        return Credential(secret: raw.access_token, refresh: refresh, expiresAt: expiry, fields: fields)
    }

    /// Who a credential belongs to, from the claims kept with it.
    static func identity(_ credential: Credential) throws(FetchFailure) -> Identity {
        guard let id = credential.fields[Field.id] else { throw .signInRequired }
        let email = credential.fields[Field.email] ?? ""
        let name = credential.fields[Field.name] ?? (email.isEmpty ? "ChatGPT account" : email)
        return Identity(id: id, name: name, email: email)
    }

    private static func jsonRequest(_ url: URL, _ body: [String: String]) -> URLRequest {
        var request = URLRequest(url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: ID token claims

    /// The claims of an ID token Tidemark keeps: who the user is and which ChatGPT workspace the tokens are for. The
    /// token comes straight from auth.openai.com over TLS, so its claims are read without checking its signature.
    struct Claims: Equatable {
        var id: String
        var account: String?
        var email: String?
        var name: String?

        init?(idToken: String) {
            guard let payload = OpenAI.JWT.payload(idToken) else { return nil }
            let auth = payload["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            let profile = payload["https://api.openai.com/profile"] as? [String: Any] ?? [:]
            func text(_ value: Any?) -> String? {
                (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
            account = text(auth["chatgpt_account_id"])
            email = text(payload["email"]) ?? text(profile["email"])
            name = text(payload["name"])
            // One person in one workspace: the same user in a personal and a team workspace is two accounts.
            let user = text(auth["chatgpt_user_id"]) ?? text(auth["user_id"]) ?? text(payload["sub"])
            if let membership = text(auth["chatgpt_account_user_id"]) {
                id = membership
            } else if let joined = [user, account].compactMap({ $0 }).joined(separator: "/").nonEmpty {
                id = joined
            } else {
                return nil
            }
        }

        var fields: [String: String] {
            var fields = [Field.id: id]
            fields[Field.account] = account
            fields[Field.email] = email
            fields[Field.name] = name
            return fields
        }
    }
}

extension OpenAI {
    /// The unverified payload of a JSON Web Token.
    enum JWT {
        static func payload(_ token: String) -> [String: Any]? {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let data = Data(base64Encoded: base64) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        /// The `exp` claim.
        static func expiry(_ token: String) -> Date? {
            guard let exp = (payload(token)?["exp"] as? NSNumber)?.doubleValue, exp > 0 else { return nil }
            return Date(timeIntervalSince1970: exp)
        }
    }
}

private extension String {
    /// Nil when empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
