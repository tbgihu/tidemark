import Foundation

/// OpenCode: an API key, for the workspace's OpenCode Go limits (a rolling 5-hour window, a week and a month) when
/// it subscribes to Go, and its pay-as-you-go credits: the balance left and what the last 30 days spent.
enum OpenCode {
    static let id = "opencode"

    static let provider = Provider(
        id: id, name: "OpenCode", company: "OpenCode", brandColor: BrandColor(hex: 0x869C1C),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [apiKey])

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// The Console's own API, which takes the same key: the credit balance and recent spend.
    static let billingURL = URL(string: "https://opencode.ai/console/api/billing/status")!
    static let spendURL = URL(string: "https://opencode.ai/console/api/usage/summary?range=30d")!

    static let apiKey = Login(
        id: "key", title: "API Key", subtitle: "Add an API key to see Go limits and credits", symbol: "key",
        kindLabel: "OpenCode", auth: .secret(keyForm), secretItem: "opencode-api-keys",
        history: .meters(OpenCodeUsage.Window.allCases.map { ChartedMeter(id: $0.rawValue, label: $0.label, title: $0.title) }),
        texts: .key(revokeIn: "your workspace on opencode.ai", forbidden: "This key can’t read OpenCode usage."),
        accountID: { "opencode-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try await usage(credential.secret, http: http, now: Date())   // checks the key
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "OpenCode"))
        },
        fetch: { context throws(FetchFailure) in try await usage(context.credential.secret, http: context.http, now: context.now) })

    static let keyForm = SecretForm(
        title: "Add an OpenCode API Key",
        intro: "Tidemark shows your OpenCode Go limits and your credits: the balance left and what the last 30 days "
            + "spent. Create an API key in your workspace on opencode.ai and paste it here.",
        fields: [.init(id: "key", label: "API key", placeholder: "sk-…", kind: .secret),
                 APIKey.nameInput(placeholder: "Optional, such as Work")],
        footnote: "Stored in your Keychain on this Mac only, and sent only to OpenCode.",
        explain: { failure in
            switch failure {
            case .unauthorized, .forbidden: "OpenCode didn’t accept this key. Check that it hasn’t been deleted."
            case .rateLimited: "OpenCode asked to slow down. Try again in a minute."
            default: nil
            }
        })

    /// One read: the Go limits, and alongside them the credits, which only add to it. A key OpenCode accepts with
    /// neither Go nor credits is an account with no active plan, not a failure.
    static func usage(_ key: String, http: HTTP, now: Date) async throws(FetchFailure) -> Snapshot {
        async let balance = console(billingURL, key: key, http: http).flatMap(OpenCodeUsage.balance)
        async let spend = console(spendURL, key: key, http: http).flatMap(OpenCodeUsage.spend)
        let request = URLRequest(usageURL, headers: ["Authorization": "Bearer \(key)"])
        let (data, response) = try await http.send(request)
        var snapshot: Snapshot
        if OpenCodeUsage.refusesForWantOfPlan(status: response.statusCode, body: data) {
            snapshot = Snapshot(fetchedAt: now)
        } else {
            try HTTP.check(response)
            do { snapshot = try OpenCodeUsage.snapshot(data, now: now) } catch { throw .unreadable }
        }
        snapshot.money = OpenCodeUsage.money(balance: await balance, spend: await spend, now: now,
                                             headline: snapshot.meters.isEmpty)
        snapshot.note = snapshot.isEmpty ? Snapshot.noPlan : nil
        return snapshot
    }

    /// A Console read with the key, or nil for any answer but a readable one: credits are extra, never a failure.
    private static func console(_ url: URL, key: String, http: HTTP) async -> Data? {
        guard let (data, response) = try? await http.send(URLRequest(url, headers: ["Authorization": "Bearer \(key)"])),
              response.statusCode == 200 else { return nil }
        return data
    }
}
