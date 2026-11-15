import Foundation

/// ElevenLabs: the share of the subscription's credits (characters) used this period, and its tier, read with an API
/// key that has the User (read) permission.
enum ElevenLabs {
    static let id = "elevenlabs"

    static let provider = Provider(
        id: id, name: "ElevenLabs", company: "ElevenLabs", brandColor: BrandColor(hex: 0xA57FAF),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [key])

    static func request(_ credential: Credential) -> URLRequest {
        URLRequest(URL(string: "https://api.elevenlabs.io/v1/user/subscription")!, headers: ["xi-api-key": credential.secret])
    }

    static let key = Login(
        id: "key", title: "API Key", subtitle: "Add an API key to see its credits", symbol: "key",
        kindLabel: "ElevenLabs", auth: .secret(SecretForm(
            title: "Add an ElevenLabs API Key",
            intro: "Tidemark shows how much of an ElevenLabs subscription’s credits are used this period. Create an API "
                + "key at elevenlabs.io/app/settings/api-keys with access to User set to Read; it needs no other access.",
            fields: [.init(id: "key", label: "API key", placeholder: "sk_…", kind: .secret),
                     APIKey.nameInput(placeholder: "Optional, such as Studio")],
            footnote: "Stored in your Keychain on this Mac only, and sent only to ElevenLabs.",
            explain: { failure in
                switch failure {
                case .unauthorized: "ElevenLabs didn’t accept this key. Check that it hasn’t been deleted."
                case .forbidden: "This key can’t read the subscription. Give it Read access to User."
                case .rateLimited: "ElevenLabs asked to slow down. Try again in a minute."
                default: nil
                }
            })),
        // Credits are counted per billing period: reading them more often than every 15 minutes shows little new.
        minimumInterval: 900, secretItem: "elevenlabs-api-keys",
        history: .meters([ChartedMeter(id: "credits", label: "credits", title: "Credits")]),
        texts: .key(revokeIn: "ElevenLabs’ settings", forbidden: "This key can’t read the subscription: it needs Read access to User."),
        accountID: { "elevenlabs-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try ElevenLabsSubscription.snapshot(try await data(request(credential), http), now: Date())
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "ElevenLabs"))
        },
        fetch: { context throws(FetchFailure) in
            try ElevenLabsSubscription.snapshot(try await data(request(context.credential), context.http), now: context.now)
        })

    /// The body of a 2xx answer. A key without the permission is refused with 401 or 403 and a `detail.status` of
    /// `missing_permissions`: that is `.forbidden`, not a key to re-enter.
    static func data(_ request: URLRequest, _ http: HTTP) async throws(FetchFailure) -> Data {
        let (data, response) = try await http.send(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            struct Refusal: Decodable {
                struct Detail: Decodable { let status: String?; let code: String? }
                let detail: Detail?
            }
            let detail = (try? JSONDecoder().decode(Refusal.self, from: data))?.detail
            let reasons = [detail?.status, detail?.code].compactMap { $0?.lowercased() }
            if reasons.contains(where: { $0 == "missing_permissions" || $0 == "insufficient_permissions" }) { throw .forbidden }
        }
        try HTTP.check(response)
        return data
    }
}

/// `GET /v1/user/subscription`: `character_count` of `character_limit` credits used, until
/// `next_character_count_reset_unix` (seconds); `tier` ("creator") and `status` ("active").
enum ElevenLabsSubscription {
    static func snapshot(_ data: Data, now: Date) throws(FetchFailure) -> Snapshot {
        struct Raw: Decodable {
            let used: Double?, limit: Double?, reset: Date?, tier: String?, status: String?
            let isSubscription: Bool
            private enum Keys: String, CodingKey { case character_count, character_limit, next_character_count_reset_unix, tier, status }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                used = c.number(.character_count)?.double
                limit = c.number(.character_limit)?.double
                reset = Wire.epoch(c.number(.next_character_count_reset_unix)?.double)
                tier = c.text(.tier)
                status = c.text(.status)
                isSubscription = [.character_count, .character_limit, .tier].contains { c.contains($0) }
            }
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.isSubscription else { throw .unreadable }
        var meters: [Meter] = []
        if let used = raw.used, let limit = raw.limit, let percent = Wire.percent(used: used, of: limit) {
            meters.append(Meter(id: "credits", title: "Credits", label: "mo", noun: "Credit limit", percent: percent,
                                resetsAt: raw.reset))
        }
        return Snapshot(meters: meters, plan: plan(tier: raw.tier, status: raw.status), fetchedAt: now)
    }

    /// "creator" as "Creator", "growing_business" as "Growing Business"; a status other than active after it.
    static func plan(tier: String?, status: String?) -> String? {
        func words(_ text: String) -> String { text.replacingOccurrences(of: "_", with: " ").capitalized }
        let state = status.flatMap { $0.lowercased() == "active" ? nil : words($0) }
        guard let tier else { return state }
        return state.map { "\(words(tier)) · \($0)" } ?? words(tier)
    }
}
