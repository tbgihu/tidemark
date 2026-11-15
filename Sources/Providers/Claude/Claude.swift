import Foundation

/// Claude: subscription accounts, signed in with OAuth, whose usage limits Tidemark shows; and Console
/// organisations, added with an Admin API key, whose costs it shows.
enum Claude {
    static let id = "claude"

    static let provider = Provider(
        id: id, name: "Claude", company: "Anthropic", brandColor: BrandColor(hex: 0xD97757),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [account, console])

    // MARK: Claude accounts

    static let oauth = OAuthPKCE(
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        authorize: URL(string: "https://claude.com/cai/oauth/authorize")!,
        token: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        // Least privilege: reading the profile and usage. The broader set is a fallback, used only if the server
        // rejects the first; Tidemark never calls an inference endpoint.
        scopes: ["user:profile", "user:profile user:inference"],
        manualRedirect: "https://platform.claude.com/oauth/code/callback",
        extraQuery: [URLQueryItem(name: "code", value: "true")],
        jsonBody: true, sendsState: true)

    static let account = Login(
        id: "account", title: "Claude Account", subtitle: "Sign in to see its usage limits",
        symbol: "person.crop.circle", auth: .oauth(oauth), secretItem: "oauth-tokens",
        history: .meters(LimitKind.allCases.map { ChartedMeter(id: $0.id, label: $0.shortLabel, title: $0.title) }),
        texts: LoginTexts(removal: { _, email in
            "Tidemark signs out of \(email) on this Mac and deletes its usage history. Your Claude account isn’t affected."
        }),
        identify: { credential, http throws(FetchFailure) in
            let profile = try await http.decode(oauthRequest("profile", credential), Profile.decode)
            return Identity(id: profile.id, name: profile.name, email: profile.email)
        },
        fetch: { context throws(FetchFailure) in
            do throws(FetchFailure) {
                return try await context.http.decode(oauthRequest("usage", context.credential)) { try Usage.decode($0) }.snapshot
            } catch {
                throw error == .forbidden ? .server(403) : error   // not a refusal of the grant: retried like any server error
            }
        })

    private static func oauthRequest(_ endpoint: String, _ credential: Credential) -> URLRequest {
        URLRequest(URL(string: "https://api.anthropic.com/api/oauth/\(endpoint)")!,
                   headers: ["Authorization": "Bearer \(credential.secret)", "anthropic-beta": "oauth-2025-04-20"])
    }

    // MARK: Console organisations

    /// Organisation ids carry this prefix, so they never collide with a Claude account's.
    static let organizationPrefix = "org-"

    static let console = Login(
        id: "console", title: "Console Organisation", subtitle: "Add an admin key to see its costs", symbol: "building.2",
        kindLabel: "API organisation", auth: .secret(keyForm),
        // Costs settle over minutes and lag hours: reading them more often than every 5 minutes shows nothing new.
        minimumInterval: 300, secretItem: "admin-api-keys", reportsMeters: false, history: .dailyCosts, alerts: .never,
        texts: .key("admin key", revokeIn: "the Claude Console", forbidden: "This key can’t read the organisation’s costs.",
                    costs: true),
        accountID: { organizationPrefix + $0 },
        identify: { credential, http throws(FetchFailure) in
            let organization = try await http.decode(adminRequest("organizations/me", credential.secret), Organization.decode)
            return Identity(id: organization.id, name: organization.name)
        },
        fetch: { context throws(FetchFailure) in
            let range = CostPlan.refresh(now: context.now)
            let days = try await costs(key: context.credential.secret, range: range, now: context.now, http: context.http)
            let ledger = await context.costs.merge(context.account, days, covering: range, now: context.now)
            guard let money = ledger.figures(at: context.now) else { throw .unreadable }
            return Snapshot(money: money, fetchedAt: Date())
        },
        dailyCosts: { credential, range, http, now throws(FetchFailure) in
            try await costs(key: credential.secret, range: range, now: now, http: http)
        })

    static let keyForm = SecretForm(
        title: "Add a Console Organisation",
        intro: "Tidemark shows what a Claude API organisation spends. Reading costs takes an Admin API key "
            + "(sk-ant-admin…), which only the organisation’s admins can create, in the Claude Console.",
        warning: "An admin key has full admin rights over the organisation. Tidemark only reads costs, but create a "
            + "dedicated key for it, with an expiry if you can, so you can revoke it on its own.",
        fields: [.init(id: "key", label: "Admin API key", placeholder: "sk-ant-admin01-…", kind: .secret)],
        footnote: "Stored in your Keychain on this Mac only, and sent only to Anthropic.",
        validate: { values in
            AdminKey.shape(values["key"] ?? "") == .workspace
                ? "This is a workspace API key (sk-ant-api…). Costs can only be read with an Admin API key (sk-ant-admin…)."
                : nil
        },
        explain: { failure in
            switch failure {
            case .unauthorized: "Anthropic didn’t accept this key. Check that it’s an Admin API key that hasn’t been revoked or expired."
            case .forbidden: "This key can’t read the organisation. It needs to be an Admin API key (sk-ant-admin…)."
            case .rateLimited: "Anthropic asked to slow down. Try again in a minute."
            default: nil
            }
        })

    private static let adminVersion = "2023-06-01"

    private static func adminRequest(_ path: String, _ key: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(string: "https://api.anthropic.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        return URLRequest(components.url!, headers: ["x-api-key": key, "anthropic-version": adminVersion])
    }

    /// Cents per UTC day over `range` (UTC midnights), from the cost report, following its pages. The day after the
    /// range is asked for too, so the range's last day surely ends before `ending_at`; it is left out unless it has
    /// begun. Nothing later than now is asked for.
    static func costs(key: String, range: Range<Date>, now: Date, http: HTTP) async throws(FetchFailure) -> [Date: Decimal] {
        let iso = Date.ISO8601FormatStyle()
        var query = [URLQueryItem(name: "starting_at", value: range.lowerBound.formatted(iso)),
                     URLQueryItem(name: "bucket_width", value: "1d"),
                     URLQueryItem(name: "limit", value: "31")]
        let ending = CostCalendar.add(days: 1, to: range.upperBound)
        if ending <= now { query.append(URLQueryItem(name: "ending_at", value: ending.formatted(iso))) }
        var days: [Date: Decimal] = [:]
        var page: String?
        for _ in 0..<24 {                                       // a cursor that never ends can't loop forever
            // A cursor belongs to its query: every page repeats it exactly, with the cursor added.
            let request = adminRequest("organizations/cost_report", key,
                                       query: query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? []))
            let decoded = try await http.decode(request, CostPage.decode)
            for (day, cents) in decoded.days where range.contains(day) { days[day, default: 0] += cents }
            guard let next = decoded.nextPage else { return days }
            page = next
        }
        throw .unreadable
    }
}

/// Who a Claude account is, from `GET /api/oauth/profile`.
struct Profile: Equatable, Sendable {
    let id: String
    let name: String
    let email: String

    static func decode(_ data: Data) throws -> Profile {
        struct Raw: Decodable {
            struct Account: Decodable {
                let uuid: String
                let full_name: String?
                let display_name: String?
                let email: String?
                let email_address: String?
            }
            let account: Account
        }
        let account = try JSONDecoder().decode(Raw.self, from: data).account
        let email = account.email ?? account.email_address ?? ""
        let name = [account.full_name, account.display_name].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? email
        return Profile(id: account.uuid, name: name, email: email)
    }
}
