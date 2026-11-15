import Foundation

/// GitHub Copilot: a GitHub account signed in with the device flow of Tidemark's own OAuth App, whose monthly
/// Copilot quotas (premium requests, chat, code completions) Tidemark shows.
enum Copilot {
    static let id = "copilot"

    static let provider = Provider(
        id: id, name: "Copilot", company: "GitHub", brandColor: BrandColor(hex: 0x8957E5),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [account])

    /// Tidemark's GitHub OAuth App. A client id is public (the device flow has no secret); a fork registers its own
    /// app and builds with `TIDEMARK_GITHUB_CLIENT_ID=… make build`, which sets `TidemarkGitHubClientID` in Info.plist.
    static let defaultClientID = "Ov23liMerDW15JXKO3eD"

    static let clientID: String = {
        let override = Bundle.main.object(forInfoDictionaryKey: "TidemarkGitHubClientID") as? String
        return override.flatMap { $0.isEmpty ? nil : $0 } ?? defaultClientID
    }()

    static let deviceURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let userURL = URL(string: "https://api.github.com/user")!
    static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!

    static let account = Login(
        id: "account", title: "GitHub Account", subtitle: "Sign in to see your Copilot quotas", symbol: "person.crop.circle",
        auth: .deviceCode(GitHubDevice.flow(clientID: clientID)), secretItem: "copilot-tokens",
        history: .meters(CopilotUsage.Quota.allCases.map { ChartedMeter(id: $0.rawValue, label: $0.chartLabel, title: $0.title) }),
        texts: LoginTexts(
            forbidden: "GitHub didn’t let Tidemark read this account’s Copilot usage.",
            removal: { _, email in
                "Tidemark signs out of \(email) on this Mac and deletes its usage history. Your GitHub account isn’t "
                    + "affected: revoke Tidemark under GitHub Settings → Applications if nothing else uses it."
            }),
        accountID: { "github-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            let request = URLRequest(userURL, headers: ["Authorization": "Bearer \(credential.secret)",
                                                        "Accept": "application/vnd.github+json",
                                                        "X-GitHub-Api-Version": "2022-11-28"])
            let (data, response) = try await http.send(request)
            try GitHubDevice.check(response)
            do { return try GitHubUser.decode(data) } catch { throw .unreadable }
        },
        fetch: { context throws(FetchFailure) in
            let request = URLRequest(usageURL, headers: ["Authorization": "token \(context.credential.secret)"])
            let (data, response) = try await context.http.send(request)
            // The token is good but the account has no Copilot at all.
            if response.statusCode == 404 { return Snapshot(note: Snapshot.noPlan, fetchedAt: context.now) }
            try GitHubDevice.check(response)
            do { return try CopilotUsage.snapshot(data, now: context.now) } catch { throw .unreadable }
        })
}

/// GitHub's OAuth device flow. Its token endpoint answers errors (`authorization_pending`, `bad_refresh_token`) with
/// a 200 and an `error` field, so the standard flow's reading of statuses doesn't fit it.
enum GitHubDevice {
    static func flow(clientID: String, deviceURL: URL = Copilot.deviceURL, tokenURL: URL = Copilot.tokenURL) -> DeviceCodeFlow {
        DeviceCodeFlow(
            start: { http throws(FetchFailure) in
                let (data, response) = try await http.send(form(deviceURL, ["client_id": clientID, "scope": "read:user"]))
                try check(response)
                do { return try DeviceCode.decode(data) } catch { throw .unreadable }
            },
            poll: { code, http throws(FetchFailure) in
                let (data, response) = try await http.send(form(tokenURL, [
                    "client_id": clientID, "device_code": code.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]))
                return try poll(status: response.statusCode, body: data)
            },
            refresh: { credential, http throws(FetchFailure) in
                // Tokens from the device flow are refreshed without a client secret (GitHub's docs, "Refreshing
                // user access tokens"). A refresh token works once: the rotated one replaces it.
                guard let refresh = credential.refresh else { throw .signInRequired }
                let (data, response) = try await http.send(form(tokenURL, [
                    "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh]))
                return try refreshed(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                                     body: data)
            })
    }

    private static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(OAuth.form(fields).utf8)
        return request
    }

    /// A token endpoint's answer: a token, or the OAuth error it names.
    enum Answer: Equatable {
        case token(Credential)
        case error(String)
        case unreadable
    }

    /// An access token, with its refresh token and expiry when the app issues expiring tokens; a long-lived token
    /// (an app without them) has neither, and is never refreshed.
    static func answer(_ data: Data, now: Date = Date()) -> Answer {
        struct Raw: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let error: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return .unreadable }
        if let access = raw.access_token, !access.isEmpty {
            let refresh = raw.refresh_token.flatMap { $0.isEmpty ? nil : $0 }
            return .token(Credential(secret: access, refresh: refresh,
                                     expiresAt: refresh == nil ? nil : now.addingTimeInterval(raw.expires_in ?? 28800)))
        }
        return raw.error.map(Answer.error) ?? .unreadable
    }

    static func poll(status: Int, body: Data, now: Date = Date()) throws(FetchFailure) -> DevicePoll {
        guard (200..<300).contains(status) else { return try DevicePoll.decode(status: status, body: body) }
        switch answer(body, now: now) {
        case .token(let credential): return .approved(credential)
        case .error("authorization_pending"): return .pending
        case .error("slow_down"): return .slowDown
        case .error("access_denied"): return .denied
        case .error("expired_token"), .error("token_expired"): return .expired
        case .error(let error):
            Log.auth.info("GitHub device flow refused: \(error, privacy: .public)")
            throw .server(status)
        case .unreadable: throw .unreadable
        }
    }

    static func refreshed(status: Int, retryAfter: String?, body: Data, now: Date = Date()) throws(FetchFailure) -> Credential {
        guard (200..<300).contains(status) else {
            if OAuth.rejectsGrant(status: status, body: body) { throw .signInRequired }
            if status == 429 { throw .rateLimited(Backoff.retryAfter(retryAfter)) }
            throw .server(status)
        }
        switch answer(body, now: now) {
        case .token(let credential): return credential
        case .error(let error):
            // bad_refresh_token: expired or already used. Any other refusal (incorrect_client_credentials would mean
            // the app wants a secret after all) is just as final: only signing in again helps.
            Log.auth.info("GitHub refused the refresh: \(error, privacy: .public)")
            throw .signInRequired
        case .unreadable: throw .unreadable
        }
    }

    /// GitHub's REST statuses: its primary rate limit is a 403 (or 429) with `x-ratelimit-remaining: 0`, and resets at
    /// the epoch in `x-ratelimit-reset`; a secondary limit sends Retry-After.
    static func check(_ response: HTTPURLResponse, now: Date = Date()) throws(FetchFailure) {
        if response.statusCode == 403 || response.statusCode == 429 {
            if let after = response.value(forHTTPHeaderField: "Retry-After") { throw .rateLimited(Backoff.retryAfter(after)) }
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
                throw .rateLimited(reset.map { max($0 - now.timeIntervalSince1970, 0) })
            }
        }
        try HTTP.check(response)
    }
}

/// Who a GitHub account is, from `GET /user`: its numeric id, its name (or login), and its public email, or its
/// login where it shows none.
enum GitHubUser {
    static func decode(_ data: Data) throws -> Identity {
        struct Raw: Decodable {
            let id: Int64
            let login: String
            let name: String?
            let email: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let name = raw.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let email = raw.email?.trimmingCharacters(in: .whitespaces) ?? ""
        return Identity(id: String(raw.id), name: name.isEmpty ? raw.login : name, email: email.isEmpty ? raw.login : email)
    }
}
