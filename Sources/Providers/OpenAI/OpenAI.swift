import Foundation

/// OpenAI: ChatGPT accounts, signed in with a device code, whose Codex usage limits Tidemark shows; and API
/// organisations, added with an Admin API key, whose costs it shows.
enum OpenAI {
    static let id = "openai"

    static let provider = Provider(
        id: id, name: "OpenAI", company: "OpenAI", brandColor: BrandColor(hex: 0x10A37F),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [account, organization])

    // MARK: ChatGPT accounts

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static let account = Login(
        id: "chatgpt", title: "ChatGPT Account", subtitle: "Sign in with a code to see its usage limits",
        symbol: "person.crop.circle", auth: .deviceCode(ChatGPTAuth.flow), secretItem: "openai-chatgpt-tokens",
        history: .meters([Window.fiveHours, Window.weekly, Window.monthly].map {
            ChartedMeter(id: $0.id, label: $0.id, title: $0.title)
        }),
        texts: LoginTexts(removal: { _, email in
            "Tidemark signs out of \(email) on this Mac and deletes its usage history. Your ChatGPT account isn’t affected."
        }),
        accountID: { "openai-" + $0 },
        identify: { credential, _ throws(FetchFailure) in try ChatGPTAuth.identity(credential) },
        fetch: { context throws(FetchFailure) in
            do throws(FetchFailure) {
                return try await context.http.decode(usageRequest(context.credential)) { try usage($0, now: context.now) }
            } catch {
                throw error == .forbidden ? .server(403) : error   // a 403 here is an edge's refusal, not of the grant
            }
        })

    static func usageRequest(_ credential: Credential) -> URLRequest {
        var request = URLRequest(usageURL, headers: ["Authorization": "Bearer \(credential.secret)"])
        if let workspace = credential.fields[ChatGPTAuth.Field.account] {
            request.setValue(workspace, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    // MARK: API organisations

    static let organization = Login(
        id: "organization", title: "API Organisation", subtitle: "Add an admin key to see its costs", symbol: "building.2",
        kindLabel: "API organisation", auth: .secret(keyForm),
        // Costs settle over hours: reading them more often than every 15 minutes shows nothing new.
        minimumInterval: 900, secretItem: "openai-admin-keys", reportsMeters: false, history: .dailyCosts, alerts: .never,
        texts: .key("admin key", revokeIn: "the OpenAI platform settings", forbidden: "This key can’t read the organisation’s costs.",
                    costs: true),
        accountID: { "openai-org-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            // Reading today's costs checks the key; the response names the organisation's id when it can.
            let start = CostCalendar.day(Date())
            let request = costsRequest(credential.secret, query: [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "1"),
            ])
            let (data, response) = try await http.send(request)
            try HTTP.check(response)
            do { _ = try CostPage.decode(data) } catch { throw .unreadable }
            let name = APIKey.name(credential, default: "OpenAI organisation")
            if let org = response.value(forHTTPHeaderField: "openai-organization")?.trimmingCharacters(in: .whitespaces),
               org.hasPrefix("org-") {
                return Identity(id: org, name: name)
            }
            // Without it, the key itself: its digest, never the key.
            return Identity(id: "key-" + APIKey.fingerprint(credential.secret), name: name)
        },
        fetch: { context throws(FetchFailure) in
            let range = CostPlan.refresh(now: context.now)
            let days = try await costs(key: context.credential.secret, range: range, now: context.now, http: context.http)
            let ledger = await context.costs.merge(context.account, days, covering: range, now: context.now)
            guard let money = ledger.figures(at: context.now) else { throw .unreadable }
            return Snapshot(money: money, fetchedAt: context.now)
        },
        dailyCosts: { credential, range, http, now throws(FetchFailure) in
            try await costs(key: credential.secret, range: range, now: now, http: http)
        })

    static let keyForm = SecretForm(
        title: "Add an OpenAI API Organisation",
        intro: "Tidemark shows what an OpenAI API organisation spends. Reading costs takes an Admin API key "
            + "(sk-admin-…), which only the organisation’s owners can create, in the platform’s organisation settings.",
        warning: "An admin key has full admin rights over the organisation. Tidemark only reads costs, but create a "
            + "dedicated key for it so you can revoke it on its own.",
        fields: [.init(id: "key", label: "Admin API key", placeholder: "sk-admin-…", kind: .secret),
                 APIKey.nameInput(placeholder: "Optional, such as Production")],
        footnote: "Stored in your Keychain on this Mac only, and sent only to OpenAI.",
        validate: { values in
            keyShape(values["key"] ?? "") == .project
                ? "This is a project or user API key. Costs can only be read with an Admin API key (sk-admin-…)."
                : nil
        },
        explain: { failure in
            switch failure {
            case .unauthorized: "OpenAI didn’t accept this key. Check that it’s an Admin API key that hasn’t been revoked."
            case .forbidden: "This key can’t read the organisation’s costs. It needs to be an Admin API key (sk-admin-…)."
            case .rateLimited: "OpenAI asked to slow down. Try again in a minute."
            default: nil
            }
        })

    private static func costsRequest(_ key: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = query
        return URLRequest(components.url!, headers: ["Authorization": "Bearer \(key)"])
    }

    /// Cents per UTC day over `range` (UTC midnights), following the pages. `end_time` is exclusive, so a range
    /// that is over is asked for exactly; one that reaches past now is left open-ended.
    static func costs(key: String, range: Range<Date>, now: Date, http: HTTP) async throws(FetchFailure) -> [Date: Decimal] {
        var query = [URLQueryItem(name: "start_time", value: String(Int(range.lowerBound.timeIntervalSince1970))),
                     URLQueryItem(name: "bucket_width", value: "1d"),
                     URLQueryItem(name: "limit", value: "31")]
        if range.upperBound <= now {
            query.append(URLQueryItem(name: "end_time", value: String(Int(range.upperBound.timeIntervalSince1970))))
        }
        var days: [Date: Decimal] = [:]
        var page: String?
        for _ in 0..<24 {                                       // a cursor that never ends can't loop forever
            let request = costsRequest(key, query: query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? []))
            let decoded = try await http.decode(request, CostPage.decode)
            for (day, cents) in decoded.days where range.contains(day) { days[day, default: 0] += cents }
            guard let next = decoded.nextPage else { return days }
            page = next
        }
        throw .unreadable
    }
}
