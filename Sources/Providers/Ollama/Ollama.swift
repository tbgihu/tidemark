import Foundation

/// Ollama Cloud: how much of the plan's included usage is spent, and the balance of purchased credits, read with an
/// API key.
enum Ollama {
    static let id = "ollama"

    // Ollama documents 10 requests a minute per key: once a minute stays well inside it, with room for the user's own.
    static let provider = Provider(
        id: id, name: "Ollama", company: "Ollama", brandColor: BrandColor(hex: 0xA08A78),
        order: Registry.order(of: id), recommendedMinimumInterval: 60, logins: [cloud])

    static func request(_ credential: Credential) -> URLRequest {
        URLRequest(URL(string: "https://ollama.com/api/balance")!, headers: ["Authorization": "Bearer \(credential.secret)"])
    }

    static let cloud = Login(
        id: "cloud", title: "Ollama Cloud", subtitle: "Add an API key to see its usage", symbol: "key",
        kindLabel: "Ollama Cloud", auth: .secret(SecretForm(
            title: "Add an Ollama API Key",
            intro: "Tidemark shows how much of an Ollama Cloud plan’s included usage is spent, and the balance of "
                + "credits bought. Create an API key at ollama.com/settings/keys.",
            fields: [.init(id: "key", label: "API key", placeholder: "Your API key", kind: .secret),
                     APIKey.nameInput(placeholder: "Optional, such as Personal")],
            footnote: "Stored in your Keychain on this Mac only, and sent only to Ollama.",
            explain: { failure in
                switch failure {
                case .unauthorized, .forbidden: "Ollama didn’t accept this key. Check that it hasn’t been revoked."
                case .rateLimited: "Ollama asked to slow down. Try again in a minute."
                default: nil
                }
            })),
        minimumInterval: 60, secretItem: "ollama-api-keys",
        history: .meters([ChartedMeter(id: "monthly", label: "included", title: "Included usage"),
                          ChartedMeter(id: "session", label: "session", title: "Session"),
                          ChartedMeter(id: "weekly", label: "weekly", title: "Weekly")]),
        texts: .key(revokeIn: "Ollama’s settings"),
        accountID: { "ollama-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try OllamaBalance.snapshot(try await http.data(request(credential)), now: Date())
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "Ollama Cloud"))
        },
        fetch: { context throws(FetchFailure) in
            try OllamaBalance.snapshot(try await context.http.data(request(context.credential)), now: context.now)
        })
}

/// `GET https://ollama.com/api/balance`. Current plans: `included.allowance_usd` for the period
/// (`included.period.until`) and `included.balance_usd` left of it; older plans: `included.session` and
/// `included.weekly`, each a `remaining_percent` and `resets_at`, which win when present. `purchased.balance_usd`
/// is credit bought, never part of the allowance. Amounts are numbers or decimal strings.
enum OllamaBalance {
    static func snapshot(_ data: Data, now: Date) throws(FetchFailure) -> Snapshot {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.isBalance else { throw .unreadable }
        var meters: [Meter] = []
        if let included = raw.included {
            let legacy = [included.session.flatMap { $0.meter(id: "session", title: "Session", label: "ses", short: true) },
                          included.weekly.flatMap { $0.meter(id: "weekly", title: "Weekly", label: "w", short: false) }]
                .compactMap { $0 }
            if !legacy.isEmpty || included.session != nil || included.weekly != nil {
                meters = legacy
            } else if let allowance = included.allowance, let balance = included.balance,
                      let percent = Wire.percent(used: Wire.Number(allowance - balance).double, of: Wire.Number(allowance).double) {
                meters = [Meter(id: "monthly", title: "Included usage", label: "mo", noun: "Included usage", percent: percent,
                                resetsAt: included.until)]
            }
        }
        var money: [Money] = []
        if let purchased = raw.purchased {
            money.append(Money(id: "purchased", title: "Purchased credits", role: .balance, amount: purchased, currency: "USD",
                               headline: true))
        }
        let note = raw.plan == nil && raw.included == nil && raw.purchased == nil ? Snapshot.noPlan : nil
        return Snapshot(meters: meters, money: money, plan: raw.plan, note: note, fetchedAt: now)
    }

    // MARK: Wire format

    struct Raw: Decodable {
        let included: Included?
        let purchased: Decimal?
        let plan: String?
        /// Has a field of a balance response, even if null: anything else is not one.
        let isBalance: Bool

        private enum Keys: String, CodingKey { case included, purchased, plan, tier }
        private struct Purchased: Decodable {
            let balance: Decimal?
            private enum Keys: String, CodingKey { case balance_usd }
            init(from decoder: any Decoder) throws { balance = try decoder.container(keyedBy: Keys.self).number(.balance_usd)?.decimal }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            included = try? c.decodeIfPresent(Included.self, forKey: .included)
            purchased = (try? c.decodeIfPresent(Purchased.self, forKey: .purchased))?.balance
            isBalance = c.contains(.included) || c.contains(.purchased)
            plan = (c.text(.plan) ?? c.text(.tier)).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
    }

    struct Included: Decodable {
        let allowance: Decimal?
        let balance: Decimal?
        let until: Date?
        let session: Window?
        let weekly: Window?

        private enum Keys: String, CodingKey { case allowance_usd, balance_usd, period, session, weekly }
        private struct Period: Decodable { let until: String? }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            allowance = c.number(.allowance_usd)?.decimal
            balance = c.number(.balance_usd)?.decimal
            until = (try? c.decodeIfPresent(Period.self, forKey: .period))?.until.flatMap(ISO8601.date)
            session = try? c.decodeIfPresent(Window.self, forKey: .session)
            weekly = try? c.decodeIfPresent(Window.self, forKey: .weekly)
        }
    }

    struct Window: Decodable {
        let remainingPercent: Double?
        let resetsAt: Date?

        private enum Keys: String, CodingKey { case remaining_percent, resets_at }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            remainingPercent = c.number(.remaining_percent)?.double
            resetsAt = c.text(.resets_at).flatMap(ISO8601.date)
        }

        func meter(id: String, title: String, label: String, short: Bool) -> Meter? {
            guard let remainingPercent, (0...100).contains(remainingPercent) else { return nil }
            return Meter(id: id, title: title, label: label, noun: "\(title) limit", percent: 100 - remainingPercent,
                         resetsAt: resetsAt, short: short)
        }
    }
}
