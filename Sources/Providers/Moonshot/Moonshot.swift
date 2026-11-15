import Foundation

/// Moonshot AI's Kimi: Kimi Code subscriptions, whose 5-hour, weekly and monthly limits Tidemark shows, and Moonshot
/// API (Open Platform) accounts, whose balance it shows. Both are added with an API key issued for one region,
/// International or China, which picks the host.
enum Moonshot {
    static let id = "moonshot"

    static let provider = Provider(
        id: id, name: "Kimi", company: "Moonshot AI", brandColor: BrandColor(hex: 0xA89418),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [code, api])

    private static func request(_ host: String, _ path: String, _ credential: Credential) -> URLRequest {
        URLRequest(URL(string: "https://\(host)\(path)")!, headers: ["Authorization": "Bearer \(credential.secret)"])
    }

    // MARK: Kimi Code

    static func codeRequest(_ credential: Credential) -> URLRequest {
        request(APIKey.Region(credential).codeHost, "/coding/v1/usages", credential)
    }

    static let code = Login(
        id: "code", title: "Kimi Code", subtitle: "Add an API key to see its usage limits", symbol: "chevron.left.forwardslash.chevron.right",
        kindLabel: "Kimi Code", auth: .secret(SecretForm(
            title: "Add a Kimi Code Key",
            intro: "Tidemark shows a Kimi Code subscription’s 5-hour, weekly and monthly limits. Create an API key in "
                + "the Kimi Code console (kimi.ai for International, kimi.com for China) and choose the region it was "
                + "issued for.",
            fields: [.init(id: "key", label: "API key", placeholder: "sk-kimi-…", kind: .secret), APIKey.Region.input,
                     APIKey.nameInput(placeholder: "Optional, such as Work")],
            footnote: "Stored in your Keychain on this Mac only, and sent only to Moonshot AI.",
            explain: { failure in
                switch failure {
                case .unauthorized: "Kimi didn’t accept this key. Check that it’s a Kimi Code key issued for the region chosen."
                case .forbidden: "This key can’t read Kimi Code usage."
                case .rateLimited: "Kimi asked to slow down. Try again in a minute."
                default: nil
                }
            })),
        secretItem: "kimi-code-keys",
        history: .meters([ChartedMeter(id: "session", label: "5h", title: "5-hour limit"),
                          ChartedMeter(id: "weekly", label: "weekly", title: "Weekly limit"),
                          ChartedMeter(id: "monthly", label: "monthly", title: "Monthly usage")]),
        texts: .key(revokeIn: "the Kimi Code console"),
        accountID: { "kimi-code-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try KimiCode.snapshot(try await http.data(codeRequest(credential)), now: Date())
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "Kimi Code"))
        },
        fetch: { context throws(FetchFailure) in
            try KimiCode.snapshot(try await context.http.data(codeRequest(context.credential)), now: context.now)
        })

    // MARK: Moonshot API

    static func balanceRequest(_ credential: Credential) -> URLRequest {
        request(APIKey.Region(credential).apiHost, "/v1/users/me/balance", credential)
    }

    static let api = Login(
        id: "api", title: "Moonshot API", subtitle: "Add an API key to see its balance", symbol: "key",
        kindLabel: "Moonshot API", auth: .secret(SecretForm(
            title: "Add a Moonshot API Key",
            intro: "Tidemark shows a Moonshot (Kimi Open Platform) account’s balance. Paste an API key from "
                + "platform.moonshot.ai (International, in US dollars) or platform.moonshot.cn (China, in yuan) and "
                + "choose the region it was issued for.",
            fields: [.init(id: "key", label: "API key", placeholder: "sk-…", kind: .secret), APIKey.Region.input,
                     APIKey.nameInput(placeholder: "Optional, such as Research")],
            footnote: "Stored in your Keychain on this Mac only, and sent only to Moonshot AI.",
            explain: { failure in
                switch failure {
                case .unauthorized: "Moonshot didn’t accept this key. Check that it was issued for the region chosen."
                case .rateLimited: "Moonshot asked to slow down. Try again in a minute."
                default: nil
                }
            })),
        // A balance changes only with spending and top-ups: reading it more often shows nothing new.
        minimumInterval: 900, secretItem: "moonshot-api-keys", reportsMeters: false, alerts: .never,
        texts: .key(revokeIn: "the Moonshot platform"),
        accountID: { "moonshot-api-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try MoonshotBalance.snapshot(try await http.data(balanceRequest(credential)),
                                             currency: APIKey.Region(credential).currency, now: Date())
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "Moonshot API"))
        },
        fetch: { context throws(FetchFailure) in
            try MoonshotBalance.snapshot(try await context.http.data(balanceRequest(context.credential)),
                                         currency: APIKey.Region(context.credential).currency, now: context.now)
        })
}

extension APIKey.Region {
    /// Kimi Code: kimi.ai serves the international product, kimi.com the Chinese one.
    var codeHost: String { self == .china ? "api.kimi.com" : "api.kimi.ai" }
    var apiHost: String { self == .china ? "api.moonshot.cn" : "api.moonshot.ai" }
    /// Open Platform balances are in the region's currency, without conversion.
    var currency: String { self == .china ? "CNY" : "USD" }
}
