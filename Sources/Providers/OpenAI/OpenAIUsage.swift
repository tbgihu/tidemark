import Foundation

// ChatGPT accounts: the Codex usage limits of `GET https://chatgpt.com/backend-api/wham/usage`, read leniently and
// shown as meters. A window is named by its length (`limit_window_seconds`), never by its place: plans differ in
// which windows they have (5 hours and a week, a month alone, or none), and any of them may be null.

extension OpenAI {
    /// What a window of a given length is called.
    struct Window: Equatable, Sendable {
        /// The meter's id: stable for history and notifications.
        let id: String
        let title: String
        /// The menu bar's label, at most four characters.
        let label: String
        let noun: String
        /// A window of hours rather than days.
        let short: Bool

        static let fiveHours = Window(id: "5h", title: "5-hour limit", label: "5h", noun: "5-hour limit", short: true)
        static let weekly = Window(id: "weekly", title: "Weekly limit", label: "w", noun: "Weekly limit", short: false)
        static let monthly = Window(id: "monthly", title: "Monthly limit", label: "mo", noun: "Monthly limit", short: false)
        static let daily = Window(id: "daily", title: "Daily limit", label: "day", noun: "Daily limit", short: false)

        /// The window `seconds` long; nil for a length that isn't one.
        init?(seconds: Double?) {
            guard let seconds, seconds > 0 else { return nil }
            let hours = (seconds / 3600).rounded(), days = (seconds / 86400).rounded()
            switch seconds {
            case 18000: self = .fiveHours
            case 86400: self = .daily
            case 604800: self = .weekly
            case 28 * 86400...31 * 86400: self = .monthly
            case ..<86400 where hours >= 1:
                self.init(id: "\(Int(hours))h", title: "\(Int(hours))-hour limit", label: "\(Int(hours))h",
                          noun: "\(Int(hours))-hour limit", short: true)
            case ..<3600:
                let minutes = max(Int((seconds / 60).rounded()), 1)
                self.init(id: "\(minutes)m", title: "\(minutes)-minute limit", label: "\(minutes)m",
                          noun: "\(minutes)-minute limit", short: true)
            default:
                self.init(id: "\(Int(days))d", title: "\(Int(days))-day limit", label: String("\(Int(days))d".prefix(4)),
                          noun: "\(Int(days))-day limit", short: false)
            }
        }

        private init(id: String, title: String, label: String, noun: String, short: Bool) {
            self.id = id
            self.title = title
            self.label = label
            self.noun = noun
            self.short = short
        }
    }

    /// The plan as ChatGPT names it: "go" is "Go", "prolite" "Pro Lite". An unknown one is shown tidied up; "guest"
    /// and "unknown" aren't shown.
    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "guest", "unknown": return nil
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "promax": return "Pro Max"
        case "team": return "Team"
        case "business", "self_serve_business_usage_based", "self_serve_business_prolite": return "Business"
        case "free_workspace": return "Free Workspace"
        case "enterprise", "ent26", "enterprise_cbp_usage_based", "enterprise_cbp_automation": return "Enterprise"
        case "edu", "education": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        case "k12": return "K-12"
        default:
            return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// Decodes `GET /backend-api/wham/usage` into a snapshot. Anything unknown, malformed or null is left out rather
    /// than failing the response: `rate_limit: null` (no limits on the plan) and a single window are ordinary. Only
    /// a body that is not a usage response at all (none of its fields, even as null) throws.
    static func usage(_ data: Data, now: Date = Date()) throws -> Snapshot {
        let raw = try JSONDecoder().decode(UsageResponse.self, from: data)
        guard raw.recognised else { throw FetchFailure.unreadable }
        var meters: [Meter] = []
        var seen = Set<String>()
        func add(_ window: UsageResponse.Window?, prefix: (id: String, title: String)? = nil) {
            guard let window, let percent = window.used_percent?.double,
                  let kind = Window(seconds: window.limit_window_seconds?.double) else { return }
            var id = prefix.map { "\($0.id):\(kind.id)" } ?? kind.id
            if seen.contains(id) { id += "-2" }
            guard seen.insert(id).inserted else { return }
            meters.append(Meter(id: id, title: prefix.map { "\($0.title) · \(kind.title)" } ?? kind.title,
                                label: prefix == nil ? kind.label : String(("+" + kind.label).prefix(4)),
                                noun: prefix.map { "\($0.title) \(kind.noun.lowercased())" } ?? kind.noun,
                                percent: percent, resetsAt: window.reset(now: now), short: kind.short))
        }
        add(raw.rate_limit?.primary_window)
        add(raw.rate_limit?.secondary_window)
        // Limits of other features or models (a model of its own, say), after the account's own.
        for extra in raw.additional_rate_limits ?? [] {
            guard let name = (extra.limit_name ?? extra.metered_feature)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            let prefix = (id: name.lowercased(), title: name)
            add(extra.rate_limit?.primary_window, prefix: prefix)
            add(extra.rate_limit?.secondary_window, prefix: prefix)
        }

        var money: [Money] = []
        // Purchased credits: a count of credits, not money, so shown without a currency.
        if let credits = raw.credits, credits.has_credits == true, credits.unlimited != true,
           let balance = credits.balance {
            money.append(Money(id: "credits", title: "Credits", role: .balance, amount: balance, currency: nil,
                               digits: digits(balance), headline: true))
        }
        // A workspace's monthly cap on the member's credits.
        if let limit = raw.spend_control?.individual_limit, let used = limit.used,
           let cap = limit.limit {
            money.append(Money(id: "credit-limit", title: "Credits used", amount: used, currency: nil,
                               digits: max(digits(used), digits(cap)), limit: cap, limitLabel: "monthly credit limit",
                               reportedSeverity: raw.spend_control?.reached == true ? "exceeded" : nil,
                               end: limit.reset(now: now), headline: money.isEmpty))
        }
        return Snapshot(meters: meters, money: money, plan: planName(raw.plan_type), fetchedAt: now)
    }

    private static func digits(_ value: Decimal) -> Int {
        var value = value, whole = Decimal()
        NSDecimalRound(&whole, &value, 0, .plain)
        return whole == value ? 0 : 2
    }

    /// The wire format. Every field is optional and decodes on its own, so a new value, a changed type or a null
    /// never makes the response unreadable.
    private struct UsageResponse: Decodable {
        let plan_type: String?
        let rate_limit: RateLimit?
        let additional_rate_limits: [Additional]?
        let credits: Credits?
        let spend_control: SpendControl?
        let recognised: Bool

        enum Keys: String, CodingKey {
            case plan_type, rate_limit, additional_rate_limits, credits, spend_control, rate_limit_reached_type
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            recognised = !c.allKeys.isEmpty
            plan_type = try? c.decodeIfPresent(String.self, forKey: .plan_type)
            rate_limit = try? c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
            additional_rate_limits = (try? c.decodeIfPresent([Lenient<Additional>].self, forKey: .additional_rate_limits))?
                .compactMap(\.value)
            credits = try? c.decodeIfPresent(Credits.self, forKey: .credits)
            spend_control = try? c.decodeIfPresent(SpendControl.self, forKey: .spend_control)
        }

        struct RateLimit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?

            enum Keys: String, CodingKey { case primary_window, secondary_window }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                primary_window = try? c.decodeIfPresent(Window.self, forKey: .primary_window)
                secondary_window = try? c.decodeIfPresent(Window.self, forKey: .secondary_window)
            }
        }

        struct Window: Decodable {
            let used_percent: Wire.Number?
            let limit_window_seconds: Wire.Number?
            let reset_after_seconds: Wire.Number?
            let reset_at: Wire.Number?

            enum Keys: String, CodingKey { case used_percent, limit_window_seconds, reset_after_seconds, reset_at }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                used_percent = c.number(.used_percent)
                limit_window_seconds = c.number(.limit_window_seconds)
                reset_after_seconds = c.number(.reset_after_seconds)
                reset_at = c.number(.reset_at)
            }

            func reset(now: Date) -> Date? { OpenAI.reset(at: reset_at?.double, after: reset_after_seconds?.double, now: now) }
        }

        struct Additional: Decodable {
            let limit_name: String?
            let metered_feature: String?
            let rate_limit: RateLimit?

            enum Keys: String, CodingKey { case limit_name, metered_feature, rate_limit }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                limit_name = try? c.decodeIfPresent(String.self, forKey: .limit_name)
                metered_feature = try? c.decodeIfPresent(String.self, forKey: .metered_feature)
                rate_limit = try? c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
            }
        }

        struct Credits: Decodable {
            let has_credits: Bool?
            let unlimited: Bool?
            let balance: Decimal?

            enum Keys: String, CodingKey { case has_credits, unlimited, balance }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                has_credits = try? c.decodeIfPresent(Bool.self, forKey: .has_credits)
                unlimited = try? c.decodeIfPresent(Bool.self, forKey: .unlimited)
                balance = c.number(.balance)?.decimal
            }
        }

        struct SpendControl: Decodable {
            let reached: Bool?
            let individual_limit: Limit?

            enum Keys: String, CodingKey { case reached, individual_limit }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                reached = try? c.decodeIfPresent(Bool.self, forKey: .reached)
                individual_limit = try? c.decodeIfPresent(Limit.self, forKey: .individual_limit)
            }

            struct Limit: Decodable {
                let limit: Decimal?
                let used: Decimal?
                let reset_at: Wire.Number?
                let reset_after_seconds: Wire.Number?

                enum Keys: String, CodingKey { case limit, used, reset_at, reset_after_seconds }

                init(from decoder: any Decoder) throws {
                    let c = try decoder.container(keyedBy: Keys.self)
                    limit = c.number(.limit)?.decimal
                    used = c.number(.used)?.decimal
                    reset_at = c.number(.reset_at)
                    reset_after_seconds = c.number(.reset_after_seconds)
                }

                func reset(now: Date) -> Date? { OpenAI.reset(at: reset_at?.double, after: reset_after_seconds?.double, now: now) }
            }
        }
    }

    /// A reset time: `reset_at` in Unix seconds (or milliseconds), else `reset_after_seconds` from now.
    static func reset(at: Double?, after: Double?, now: Date) -> Date? {
        if let at = Wire.epoch(at) { return at }
        if let after, after > 0 { return now + after }
        return nil
    }
}
