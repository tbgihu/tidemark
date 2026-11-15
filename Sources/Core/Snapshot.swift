import Foundation

/// What a provider reported about an account at one moment, in terms every view understands: percent meters, money
/// figures, a plan and who the account is. Saved in state.json, so the menu bar has values the moment Tidemark
/// launches. A refresh replaces it whole: a meter it lacks is not shown, whatever an earlier one said.
struct Snapshot: Codable, Equatable, Sendable {
    var meters: [Meter] = []
    var money: [Money] = []
    /// "Max", "Pro", "Team": shown with the account's name when the provider reports it.
    var plan: String? = nil
    /// Who the account is now, when the response says: its name and email follow it.
    var identity: Identity? = nil
    /// Why an account reports nothing, in the provider's terms ("No active plan"): the panel's status in place of
    /// "No usage limits reported".
    var note: String? = nil
    var fetchedAt: Date

    init(meters: [Meter] = [], money: [Money] = [], plan: String? = nil, identity: Identity? = nil, note: String? = nil,
         fetchedAt: Date) {
        self.meters = meters
        self.money = money
        self.plan = plan
        self.identity = identity
        self.note = note
        self.fetchedAt = fetchedAt
    }

    /// The note of an account with no plan the provider reports usage for.
    static let noPlan = "No active plan"

    /// The note of an account whose plan doesn't include `product`.
    static func unavailable(_ product: String) -> String { "\(product) isn’t available for this plan" }

    /// Nothing reported: the account currently has none (shown as such, never as empty bars).
    var isEmpty: Bool { meters.isEmpty && money.isEmpty }

    subscript(meter id: String) -> Meter? { meters.first { $0.id == id } }

    /// The figure the menu bar shows when there are no meters.
    var headline: Money? { money.first(where: \.headline) }

    /// The reset times in it that it predates: each ends a meter's value, so a refresh is due right after.
    var resets: [Date] { meters.compactMap(\.resetsAt).filter { $0 > fetchedAt } }

    /// Only `fetchedAt` is required: anything else that doesn't decode is left out.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        meters = ((try? c.decodeIfPresent([Lenient<Meter>].self, forKey: .meters)) ?? []).compactMap(\.value)
        money = ((try? c.decodeIfPresent([Lenient<Money>].self, forKey: .money)) ?? []).compactMap(\.value)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        identity = try? c.decodeIfPresent(Identity.self, forKey: .identity)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// A limit as a share used, 0–100: a bar in the menu bar and the panel.
struct Meter: Codable, Equatable, Sendable {
    /// Stable within its login: history, notifications and their keys use it.
    var id: String
    /// The panel's label: "Current session".
    var title: String
    /// The menu bar's row label, a few characters: "5h".
    var label: String
    /// How a notification names it: "Session limit". The title when nil.
    var noun: String? = nil
    var percent: Double
    var resetsAt: Date? = nil
    /// The server's own grade, as sent (see `Severity`).
    var reportedSeverity: String? = nil
    /// A short rolling window (hours, such as a 5-hour session) rather than a day, week or month: it notifies later.
    var short = false

    init(id: String, title: String, label: String, noun: String? = nil, percent: Double, resetsAt: Date? = nil,
         reportedSeverity: String? = nil, short: Bool = false) {
        self.id = id
        self.title = title
        self.label = label
        self.noun = noun
        self.percent = percent
        self.resetsAt = resetsAt
        self.reportedSeverity = reportedSeverity
        self.short = short
    }

    /// The percentage as shown, never below 0 or above 100.
    var clamped: Double { min(max(percent, 0), 100) }
    var rounded: Int { Int(clamped.rounded()) }
    /// How close it is to running out.
    var severity: Severity { Severity(server: reportedSeverity, percent: percent) }

    private enum CodingKeys: String, CodingKey { case id, title, label, noun, percent, resetsAt, reportedSeverity, short }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        percent = try c.decode(Double.self, forKey: .percent)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? id
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? String(id.prefix(3))
        noun = try? c.decodeIfPresent(String.self, forKey: .noun)
        resetsAt = try? c.decodeIfPresent(Date.self, forKey: .resetsAt)
        reportedSeverity = try? c.decodeIfPresent(String.self, forKey: .reportedSeverity)
        short = (try? c.decodeIfPresent(Bool.self, forKey: .short)) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(noun, forKey: .noun)
        try c.encode(percent, forKey: .percent)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encodeIfPresent(reportedSeverity, forKey: .reportedSeverity)
        if short { try c.encode(short, forKey: .short) }
    }
}

/// An amount of money: what was spent (against an optional cap), a balance left, or a credit. Kept as an exact
/// decimal from the wire to the screen, never a binary float.
struct Money: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case spend, balance, credit }

    var id: String
    /// "Extra usage", "Used this month", "Balance".
    var title: String
    var role: Role = .spend
    /// In major units (dollars, not cents).
    var amount: Decimal
    /// ISO 4217; nil for a bare number.
    var currency: String?
    var digits = 2
    /// A cap the amount counts against: drawn as a bar.
    var limit: Decimal? = nil
    /// How the cap is named: "of €50.00 monthly limit".
    var limitLabel: String? = nil
    var reportedSeverity: String? = nil
    /// The period the amount covers. Once it is over the amount no longer applies and is not shown.
    var start: Date? = nil
    var end: Date? = nil
    /// The period is still running, so the amount is still growing.
    var partial = false
    /// The menu bar's figure when the account has no meters.
    var headline = false

    init(id: String, title: String, role: Role = .spend, amount: Decimal, currency: String?, digits: Int = 2,
         limit: Decimal? = nil, limitLabel: String? = nil, reportedSeverity: String? = nil, start: Date? = nil,
         end: Date? = nil, partial: Bool = false, headline: Bool = false) {
        self.id = id
        self.title = title
        self.role = role
        self.amount = amount
        self.currency = currency
        self.digits = digits
        self.limit = limit
        self.limitLabel = limitLabel
        self.reportedSeverity = reportedSeverity
        self.start = start
        self.end = end
        self.partial = partial
        self.headline = headline
    }

    /// The share of the cap that is used, 0–1, when there is a cap.
    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        let share = NSDecimalNumber(decimal: amount / limit).doubleValue
        return min(max(share, 0), 1)
    }

    /// How close the amount is to its cap: the server's grade when it gave one Tidemark understands, otherwise from
    /// the share of the cap used. Nil without either.
    var severity: Severity? {
        if let fraction { return Severity(server: reportedSeverity, percent: fraction * 100) }
        return Severity(server: reportedSeverity)
    }

    /// Whether the amount still applies at `now`.
    func current(at now: Date) -> Bool { end.map { now < $0 } ?? true }

    /// `amount` in its own currency ("€12.40", "$14.50").
    func format(_ value: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        Format.money(value, currency: currency, digits: digits, locale: locale)
    }

    private enum Keys: String, CodingKey {
        case id, title, role, amount, currency, digits, limit, limitLabel, reportedSeverity, start, end, partial, headline
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        amount = try c.decode(Cents.self, forKey: .amount).value
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? id
        role = (try? c.decodeIfPresent(Role.self, forKey: .role)) ?? .spend
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        digits = min(max((try? c.decodeIfPresent(Int.self, forKey: .digits)) ?? 2, 0), 4)
        limit = (try? c.decodeIfPresent(Cents.self, forKey: .limit))?.value
        limitLabel = try? c.decodeIfPresent(String.self, forKey: .limitLabel)
        reportedSeverity = try? c.decodeIfPresent(String.self, forKey: .reportedSeverity)
        start = try? c.decodeIfPresent(Date.self, forKey: .start)
        end = try? c.decodeIfPresent(Date.self, forKey: .end)
        partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)) ?? false
        headline = (try? c.decodeIfPresent(Bool.self, forKey: .headline)) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(role, forKey: .role)
        try c.encode(Cents(amount), forKey: .amount)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encode(digits, forKey: .digits)
        try c.encodeIfPresent(limit.map(Cents.init), forKey: .limit)
        try c.encodeIfPresent(limitLabel, forKey: .limitLabel)
        try c.encodeIfPresent(reportedSeverity, forKey: .reportedSeverity)
        try c.encodeIfPresent(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        if partial { try c.encode(partial, forKey: .partial) }
        if headline { try c.encode(headline, forKey: .headline) }
    }
}

/// Decodes a value, or nil when it doesn't fit, without failing the array it is in.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
