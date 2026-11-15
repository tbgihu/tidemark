import Foundation

/// DeepSeek: an API account's balance in each currency it holds, from `GET /user/balance` with an API key.
enum DeepSeek {
    static let id = "deepseek"

    static let provider = Provider(
        id: id, name: "DeepSeek", company: "DeepSeek", brandColor: BrandColor(hex: 0x4D6BFE),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [key])

    static let key = Login(
        id: "key", title: "API Key", subtitle: "Add a key to see the account’s balance", symbol: "key",
        kindLabel: "API account", auth: .secret(form),
        // A balance moves with spending, not by the minute: every 10 minutes is plenty.
        minimumInterval: 600, secretItem: "deepseek-api-keys", reportsMeters: false, alerts: .never,
        texts: .key(revokeIn: "the DeepSeek platform", forbidden: "This key can’t read the account’s balance."),
        accountID: { "deepseek-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try await http.decode(request(credential.secret), Balance.decode)
            return Identity(id: APIKey.fingerprint(credential.secret),
                            name: APIKey.name(credential, default: "DeepSeek " + APIKey.hint(credential.secret)))
        },
        fetch: { context throws(FetchFailure) in
            try await context.http.decode(request(context.credential.secret), Balance.decode).snapshot
        })

    static let form = SecretForm(
        title: "Add a DeepSeek API Key",
        intro: "Tidemark shows a DeepSeek account’s balance. Paste an API key from platform.deepseek.com (API Keys).",
        fields: [.init(id: "key", label: "API key", placeholder: "sk-…", kind: .secret),
                 APIKey.nameInput(placeholder: "Optional, such as Work")],
        footnote: "Stored in your Keychain on this Mac only, and sent only to DeepSeek.",
        explain: { failure in
            switch failure {
            case .unauthorized: "DeepSeek didn’t accept this key. Check that it hasn’t been deleted."
            case .rateLimited: "DeepSeek asked to slow down. Try again in a minute."
            default: nil
            }
        })

    static func request(_ key: String) -> URLRequest {
        URLRequest(URL(string: "https://api.deepseek.com/user/balance")!, headers: ["Authorization": "Bearer \(key)"])
    }

    /// `GET /user/balance`: per currency, the total and the granted and topped-up parts of it (decimal strings).
    struct Balance: Equatable {
        struct Entry: Equatable {
            let currency: String
            let total: Decimal
            var granted: Decimal?
        }
        var entries: [Entry]
        var available: Bool?

        /// The total in each currency, the first the menu bar's figure; granted credit too while there is some.
        var snapshot: Snapshot {
            var money: [Money] = []
            for (index, entry) in entries.enumerated() {
                money.append(Money(id: "balance-" + entry.currency, title: "Balance", role: .balance, amount: entry.total,
                                   currency: entry.currency, headline: index == 0))
                if let granted = entry.granted, granted > 0 {
                    money.append(Money(id: "granted-" + entry.currency, title: "Of which granted", role: .credit,
                                       amount: granted, currency: entry.currency))
                }
            }
            return Snapshot(money: money, plan: available == false ? "Insufficient balance" : nil, fetchedAt: Date())
        }

        static func decode(_ data: Data) throws -> Balance {
            struct Raw: Decodable {
                let is_available: Bool?
                let balance_infos: [Lenient<Info>]
                struct Info: Decodable {
                    let currency: String
                    let total_balance: Wire.Number
                    let granted_balance: Wire.Number?
                }
            }
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            let entries = raw.balance_infos.compactMap(\.value).compactMap { info -> Entry? in
                let currency = info.currency.trimmingCharacters(in: .whitespaces).uppercased()
                guard currency.count == 3 else { return nil }
                return Entry(currency: currency, total: info.total_balance.decimal, granted: info.granted_balance?.decimal)
            }
            return Balance(entries: entries, available: raw.is_available)
        }
    }
}
