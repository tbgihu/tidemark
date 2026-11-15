import Foundation

/// OpenRouter: an API key's spending limit and what it spent today, this week and this month, from `GET /api/v1/key`;
/// with an optional management key, the account's credit balance too, from `GET /api/v1/credits`.
enum OpenRouter {
    static let id = "openrouter"

    static let provider = Provider(
        id: id, name: "OpenRouter", company: "OpenRouter", brandColor: BrandColor(hex: 0xD0609A),
        order: Registry.order(of: id), recommendedMinimumInterval: 60, logins: [key])

    static let key = Login(
        id: "key", title: "API Key", subtitle: "Add a key to see its limit and spend", symbol: "key",
        kindLabel: "API key", auth: .secret(form), secretItem: "openrouter-api-keys",
        history: .meters([ChartedMeter(id: "limit", label: "limit", title: "Key limit")]),
        texts: .key(revokeIn: "OpenRouter’s settings"),
        accountID: { "openrouter-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            let key = try await http.decode(request("key", credential.secret), Key.decode)
            if let management = credential.fields["management"] {
                _ = try await http.decode(request("credits", management), Credits.decode)
            }
            return Identity(id: APIKey.fingerprint(credential.secret),
                            name: APIKey.name(credential, default: key.label ?? APIKey.hint(credential.secret)))
        },
        fetch: { context throws(FetchFailure) in
            let key = try await context.http.decode(request("key", context.credential.secret), Key.decode)
            var snapshot = key.snapshot(now: context.now)
            if let management = context.credential.fields["management"] {
                // The balance only adds to the key's figures: a failure hides it, unless OpenRouter asked to slow down.
                do throws(FetchFailure) {
                    let credits = try await context.http.decode(request("credits", management), Credits.decode)
                    snapshot.money.insert(credits.money, at: 0)
                    for index in snapshot.money.indices { snapshot.money[index].headline = index == 0 }
                } catch {
                    if case .rateLimited = error { throw error }
                }
            }
            return snapshot
        })

    static let form = SecretForm(
        title: "Add an OpenRouter API Key",
        intro: "Tidemark shows an OpenRouter key’s spending limit and what it spent today, this week and this month. "
            + "Paste the key from openrouter.ai (Settings → API Keys). Add a management key to see the account’s "
            + "credit balance too.",
        fields: [.init(id: "key", label: "API key", placeholder: "sk-or-v1-…", kind: .secret),
                 .init(id: "management", label: "Management key", placeholder: "sk-or-v1-…", kind: .secret, optional: true),
                 APIKey.nameInput(placeholder: "Optional, such as Work")],
        footnote: "Stored in your Keychain on this Mac only, and sent only to OpenRouter.",
        explain: { failure in
            switch failure {
            case .unauthorized: "OpenRouter didn’t accept this key. Check the API key, and the management key if you entered one."
            case .forbidden: "The management key can’t read credits. Leave it empty to see the key’s usage alone."
            case .rateLimited: "OpenRouter asked to slow down. Try again in a minute."
            default: nil
            }
        })

    static func request(_ endpoint: String, _ key: String) -> URLRequest {
        URLRequest(URL(string: "https://openrouter.ai/api/v1/\(endpoint)")!, headers: ["Authorization": "Bearer \(key)"])
    }

    // MARK: Responses

    /// `GET /api/v1/key`: the key's label, limit and usage, in USD. Usage periods are UTC: the day, the week from
    /// Monday and the month.
    struct Key: Equatable {
        var label: String?
        var limit: Decimal?
        var limitRemaining: Decimal?
        /// "daily", "weekly", "monthly", or nil for a limit that never resets.
        var limitReset: String?
        /// The key's own budget's reset, when `budgets` names one.
        var budgetReset: Date?
        var usage: Decimal?
        var daily: Decimal?
        var weekly: Decimal?
        var monthly: Decimal?
        var freeTier = false

        static func decode(_ data: Data) throws -> Key {
            struct Raw: Decodable { let data: Body }
            struct Body: Decodable {
                let key: Key
                enum Keys: String, CodingKey {
                    case label, limit, limit_remaining, limit_reset, usage, usage_daily, usage_weekly, usage_monthly
                    case is_free_tier, budgets
                }
                struct Budget: Decodable {
                    let limit_usd: Wire.Number?
                    let resets_at: String?
                    let scope: String?
                }
                init(from decoder: any Decoder) throws {
                    let c = try decoder.container(keyedBy: Keys.self)
                    let label = (try? c.decodeIfPresent(String.self, forKey: .label))?.trimmingCharacters(in: .whitespaces)
                    let limit = c.number(.limit)?.decimal
                    let budgets = ((try? c.decodeIfPresent([Lenient<Budget>].self, forKey: .budgets)) ?? []).compactMap(\.value)
                    // The key's own limit is the budget layer whose cap is that limit; a `key` scope wins.
                    let own = budgets.first { $0.scope == "key" && $0.resets_at != nil }
                        ?? budgets.first { limit != nil && $0.limit_usd?.decimal == limit && $0.resets_at != nil }
                    key = Key(label: label?.isEmpty == false ? label : nil, limit: limit,
                              limitRemaining: c.number(.limit_remaining)?.decimal,
                              limitReset: try? c.decodeIfPresent(String.self, forKey: .limit_reset),
                              budgetReset: own?.resets_at.flatMap(ISO8601.date), usage: c.number(.usage)?.decimal,
                              daily: c.number(.usage_daily)?.decimal, weekly: c.number(.usage_weekly)?.decimal,
                              monthly: c.number(.usage_monthly)?.decimal,
                              freeTier: (try? c.decodeIfPresent(Bool.self, forKey: .is_free_tier)) == true)
                }
            }
            return try JSONDecoder().decode(Raw.self, from: data).data.key
        }

        func snapshot(now: Date) -> Snapshot {
            let day = CostCalendar.day(now)
            let week = Self.week(now), month = CostCalendar.month(now)
            let nextDay = CostCalendar.add(days: 1, to: day), nextWeek = CostCalendar.add(days: 7, to: week)
            let nextMonth = CostCalendar.utc.date(byAdding: .month, value: 1, to: month) ?? nextDay
            var meters: [Meter] = []
            if let limit, limit > 0 {
                let period: (label: String, title: String, used: Decimal?, end: Date?) = switch limitReset {
                case "daily": ("day", "Daily key limit", daily, nextDay)
                case "weekly": ("w", "Weekly key limit", weekly, nextWeek)
                case "monthly": ("mo", "Monthly key limit", monthly, nextMonth)
                default: ("key", "Key limit", usage, nil)
                }
                let used = limitRemaining.map { limit - $0 } ?? period.used
                if let used {
                    meters.append(Meter(id: "limit", title: period.title, label: period.label,
                                        percent: NSDecimalNumber(decimal: used / limit * 100).doubleValue,
                                        resetsAt: budgetReset ?? period.end))
                }
            }
            var money: [Money] = []
            if let monthly {
                money.append(Money(id: "month", title: "Spent this month", amount: monthly, currency: "USD", start: month,
                                   end: nextMonth, partial: true, headline: true))
            }
            if let weekly {
                money.append(Money(id: "week", title: "This week", amount: weekly, currency: "USD", start: week, end: nextWeek,
                                   partial: true))
            }
            if let daily {
                money.append(Money(id: "today", title: "Today", amount: daily, currency: "USD", start: day, end: nextDay,
                                   partial: true))
            }
            return Snapshot(meters: meters, money: money, plan: freeTier ? "Free" : nil, fetchedAt: Date())
        }

        /// The start of the UTC week (from Monday) `date` is in.
        static func week(_ date: Date) -> Date {
            let day = CostCalendar.day(date)
            let weekday = CostCalendar.utc.component(.weekday, from: day)      // 1 is Sunday
            return CostCalendar.add(days: -((weekday + 5) % 7), to: day)
        }
    }

    /// `GET /api/v1/credits` (a management key): every credit bought, and every credit used, in USD.
    struct Credits: Equatable {
        let total: Decimal
        let used: Decimal

        var money: Money { Money(id: "balance", title: "Credit balance", role: .balance, amount: total - used, currency: "USD") }

        static func decode(_ data: Data) throws -> Credits {
            struct Raw: Decodable {
                let data: Body
                struct Body: Decodable { let total_credits: Wire.Number; let total_usage: Wire.Number }
            }
            let body = try JSONDecoder().decode(Raw.self, from: data).data
            return Credits(total: body.total_credits.decimal, used: body.total_usage.decimal)
        }
    }
}
