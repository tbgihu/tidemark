#if DEBUG
import Foundation

/// A fake second provider for the sample mode of debug builds (`--sample`): every kind of sign-in and of snapshot,
/// without a network or a Keychain. Never part of a release build.
enum Example {
    static let id = "example"

    static let provider = Provider(
        id: id, name: "Example", company: "Example", brandColor: BrandColor(hex: 0x3478F6),
        order: Registry.order(of: id), recommendedMinimumInterval: 60, logins: [account, key, web])

    static let account = Login(
        id: "account", title: "Example Account", subtitle: "Enter a code in your browser", symbol: "person.crop.circle",
        auth: .deviceCode(DeviceCodeFlow(
            start: { _ in
                DeviceCode(deviceCode: "sample", userCode: "TIDE-MARK", verificationURL: URL(string: "https://example.com/device")!,
                           interval: 1, expiresAt: Date() + 600)
            },
            poll: { _, _ in .approved(Credential(secret: "sample-device-token", refresh: "sample-refresh",
                                                 expiresAt: Date() + 3600)) },
            refresh: { credential, _ in Credential(secret: credential.secret, refresh: credential.refresh, expiresAt: Date() + 3600) })),
        secretItem: "example-account", history: .meters(charted),
        identify: { _, _ in Identity(id: "robin", name: "Robin Example", email: "robin@example.com") },
        fetch: { context in snapshot(context.account, now: context.now) })

    static let key = Login(
        id: "key", title: "API Key", subtitle: "Paste a key", symbol: "key", auth: .secret(SecretForm(
            title: "Add an Example API Key", intro: "Paste an API key from the Example dashboard.",
            fields: [.init(id: "key", label: "API key", placeholder: "ex-…", kind: .secret),
                     .init(id: "team", label: "Team ID", placeholder: "team_…", kind: .text, optional: true),
                     .init(id: "region", label: "Region", kind: .choice([("us", "United States"), ("eu", "Europe")]))],
            validate: { $0["key"]?.hasPrefix("ex-") == false ? "Example keys start with ex-." : nil })),
        secretItem: "example-key", history: .meters(charted),
        accountID: { "example-key-" + $0 },
        identify: { credential, _ in
            Identity(id: String(credential.secret.hashValue.magnitude % 100_000),
                     name: "Team " + (credential.fields["team"] ?? "Example"))
        },
        fetch: { context in snapshot(context.account, now: context.now) })

    static let web = Login(
        id: "web", title: "Web Session", subtitle: "Sign in on the website", symbol: "globe",
        auth: .web(WebLogin(start: URL(string: "about:blank")!, cookie: "session", domain: "example.com")),
        secretItem: "example-web",
        accountID: { "example-web-" + $0 },
        identify: { _, _ in Identity(id: "web", name: "Example Web") },
        fetch: { context in snapshot(context.account, now: context.now) })

    private static let charted = [ChartedMeter(id: "daily", label: "daily", title: "Daily requests"),
                                  ChartedMeter(id: "monthly", label: "monthly", title: "Monthly spend")]

    /// What a refresh "reads".
    static func snapshot(_ account: String, now: Date) -> Snapshot {
        if account == "robin" {
            return Snapshot(money: [Money(id: "balance", title: "Credit balance", role: .balance, amount: 8.4,
                                          currency: "USD", headline: true)],
                            plan: "Pay as you go", fetchedAt: now)
        }
        return Snapshot(meters: [
            Meter(id: "daily", title: "Daily requests", label: "day", percent: 34, resetsAt: now + 9 * 3600, short: true),
            Meter(id: "monthly", title: "Monthly spend", label: "mo", percent: 81, resetsAt: now + 17 * 86400),
        ], money: [Money(id: "credits", title: "Credits left", role: .balance, amount: 42.1, currency: "USD")],
                        plan: "Team", fetchedAt: now)
    }

    /// The sample accounts.
    static func accounts(now: Date) -> [Account] {
        [Account(id: "example-key-1", provider: id, login: key.id, name: "Example Team", email: "",
                 snapshot: snapshot("example-key-1", now: now - 20)),
         Account(id: "robin", provider: id, login: account.id, name: "Robin Example", email: "robin@example.com",
                 snapshot: snapshot("robin", now: now - 60))]
    }
}
#endif
