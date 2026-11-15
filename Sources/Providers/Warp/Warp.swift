import Foundation

/// Warp: the AI credits a user's plan allows until its next refresh, and bonus credits left, from Warp's GraphQL API
/// with a user API key.
enum Warp {
    static let id = "warp"

    static let provider = Provider(
        id: id, name: "Warp", company: "Warp", brandColor: BrandColor(hex: 0x1FA2C6),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [key])

    static let key = Login(
        id: "key", title: "API Key", subtitle: "Add a key to see its AI credits", symbol: "key",
        kindLabel: "API key", auth: .secret(form),
        // Credits are counted per request and refresh monthly: every 10 minutes is plenty.
        minimumInterval: 600, secretItem: "warp-api-keys",
        history: .meters([ChartedMeter(id: "credits", label: "credits", title: "Credits")]),
        texts: .key(revokeIn: "Warp’s settings", forbidden: "This key can’t read its credits."),
        accountID: { "warp-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try await http.decode(request(credential.secret), Limits.decode)
            return Identity(id: APIKey.fingerprint(credential.secret),
                            name: APIKey.name(credential, default: "Warp " + APIKey.hint(credential.secret)))
        },
        fetch: { context throws(FetchFailure) in
            try await context.http.decode(request(context.credential.secret), Limits.decode).snapshot(now: context.now)
        })

    static let form = SecretForm(
        title: "Add a Warp API Key",
        intro: "Tidemark shows how many of your plan’s AI credits you’ve used and your bonus credits. Create an API key "
            + "in Warp (Settings → Platform → API Keys).",
        fields: [.init(id: "key", label: "API key", placeholder: "wk-…", kind: .secret),
                 APIKey.nameInput(placeholder: "Optional, such as Work")],
        footnote: "Stored in your Keychain on this Mac only, and sent only to Warp.",
        validate: { $0["key"]?.hasPrefix("wk-") == false ? "Warp API keys start with wk-." : nil },
        explain: { failure in
            switch failure {
            case .unauthorized: "Warp didn’t accept this key. Check that it hasn’t been deleted or expired."
            case .rateLimited: "Warp asked to slow down. Try again in a minute."
            default: nil
            }
        })

    static let query = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            __typename
            ... on UserOutput {
              user {
                requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh }
                bonusGrants { requestCreditsGranted requestCreditsRemaining expiration }
                workspaces { bonusGrantsInfo { grants { requestCreditsGranted requestCreditsRemaining expiration } } }
              }
            }
          }
        }
        """

    static let osVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    static func request(_ key: String) -> URLRequest {
        let os = ["category": "macOS", "name": "macOS", "version": osVersion]
        var request = URLRequest(URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!, method: "POST", headers: [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "x-warp-client-id": "warp-app",
            "x-warp-os-category": os["category"]!,
            "x-warp-os-name": os["name"]!,
            "x-warp-os-version": osVersion,
            // Warp's edge rate-limits (429) any User-Agent that doesn't look like its own app's, whatever the key:
            // this is the one header where Tidemark can't name itself.
            "User-Agent": "Warp/1.0",
        ])
        let body: [String: Any] = ["operationName": "GetRequestLimitInfo", "query": query,
                                   "variables": ["requestContext": ["clientContext": [String: String](), "osContext": os]]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    /// The credits answer: the plan's allowance since its last refresh, and every bonus grant, the user's and its
    /// workspaces'. Units are credits.
    struct Limits: Equatable {
        var unlimited = false
        var limit: Int?
        var used: Int?
        var refresh: Date?
        var bonusRemaining: Int?

        func snapshot(now: Date) -> Snapshot {
            var meters: [Meter] = []
            if !unlimited, let limit, limit > 0, let used {
                meters.append(Meter(id: "credits", title: "Credits", label: "mo", noun: "Credit limit",
                                    percent: Double(used) / Double(limit) * 100, resetsAt: refresh))
            }
            var money: [Money] = []
            if let bonusRemaining {
                money.append(Money(id: "bonus", title: "Bonus credits left", role: .credit, amount: Decimal(bonusRemaining),
                                   currency: nil, digits: 0, headline: true))
            }
            return Snapshot(meters: meters, money: money, plan: unlimited ? "Unlimited" : nil, fetchedAt: Date())
        }

        /// A GraphQL error, or a `user` that isn't a `UserOutput`, is unreadable; inside it every field is optional.
        static func decode(_ data: Data) throws -> Limits {
            struct Raw: Decodable {
                let data: DataBody?
                let errors: [Lenient<Ignored>]?
                struct DataBody: Decodable { let user: Outer? }
                struct Outer: Decodable { let __typename: String?; let user: User? }
                struct User: Decodable {
                    let requestLimitInfo: Info?
                    let bonusGrants: [Lenient<Grant>]?
                    let workspaces: [Lenient<Workspace>]?
                }
                struct Info: Decodable {
                    let isUnlimited: Bool?
                    let nextRefreshTime: String?
                    let requestLimit: Wire.Number?
                    let requestsUsedSinceLastRefresh: Wire.Number?
                }
                struct Grant: Decodable { let requestCreditsRemaining: Wire.Number? }
                struct Workspace: Decodable {
                    let bonusGrantsInfo: Info?
                    struct Info: Decodable { let grants: [Lenient<Grant>]? }
                }
                struct Ignored: Decodable {}
            }
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            guard raw.errors?.isEmpty ?? true, let outer = raw.data?.user,
                  outer.__typename == nil || outer.__typename == "UserOutput", let user = outer.user else { throw Unreadable() }
            let info = user.requestLimitInfo
            let grants = (user.bonusGrants ?? []).compactMap(\.value)
                + (user.workspaces ?? []).compactMap(\.value).flatMap { ($0.bonusGrantsInfo?.grants ?? []).compactMap(\.value) }
            let remaining = grants.compactMap { $0.requestCreditsRemaining?.int }
            return Limits(unlimited: info?.isUnlimited == true, limit: info?.requestLimit?.int,
                          used: info?.requestsUsedSinceLastRefresh?.int, refresh: info?.nextRefreshTime.flatMap(ISO8601.date),
                          bonusRemaining: remaining.isEmpty ? nil : remaining.reduce(0, +))
        }
    }

    struct Unreadable: Error {}
}
