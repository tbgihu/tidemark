import Foundation

// Claude subscriptions: the limits of `GET /api/oauth/usage`, read leniently, then shown as meters.

/// The three limits Tidemark shows, in the order the menu bar stacks them.
enum LimitKind: String, Codable, CaseIterable, Sendable {
    case session, weekly, fable

    /// The menu bar's row label: weekly limits are "w", with the models they cover, (A)ll or (F)able.
    var menuBarLabel: String {
        switch self {
        case .session: "5h"
        case .weekly: "w(A)"
        case .fable: "w(F)"
        }
    }

    /// The History chart's label, and the meter's id (its key in history, notifications and their state).
    var id: String { rawValue }

    /// The History chart's label.
    var shortLabel: String {
        switch self {
        case .session: "5h"
        case .weekly: "weekly"
        case .fable: "fable"
        }
    }

    /// The label in the usage panel, as on Claude's own usage page.
    var title: String {
        switch self {
        case .session: "Current session"
        case .weekly: "Weekly · All models"
        case .fable: "Weekly · Fable"
        }
    }

    /// How a notification names the limit.
    var noun: String {
        switch self {
        case .session: "Session limit"
        case .weekly: "Weekly limit"
        case .fable: "Fable weekly limit"
        }
    }
}

/// One limit's state: how much of it is used, 0–100, when it starts over, and the server's grade of it, as sent
/// ("normal", "warning", "critical"; see `Severity`).
struct Limit: Codable, Equatable, Sendable {
    var percent: Double
    var resetsAt: Date?
    var reportedSeverity: String? = nil

    /// The percentage as shown, never below 0 or above 100.
    var clamped: Double { min(max(percent, 0), 100) }
    var rounded: Int { Int(clamped.rounded()) }
}

/// Extra usage: pay-as-you-go spending beyond the plan's limits. Amounts are in the currency's minor units
/// (`decimal_places` of them, 2 for cents), as the API reports them. The server grades the spending like a limit,
/// in the `limits[]` row of kind "spend".
struct ExtraUsage: Codable, Equatable, Sendable {
    var spentMinor: Double
    var limitMinor: Double?
    var currency: String?
    var decimals: Int
    var reportedSeverity: String? = nil

    /// How close the spending is to its cap: the server's grade when it gave one Tidemark understands, otherwise
    /// from the share of the cap spent. Nil without either.
    var severity: Severity? {
        if let fraction { return Severity(server: reportedSeverity, percent: fraction * 100) }
        return Severity(server: reportedSeverity)
    }

    var spent: Decimal { major(spentMinor) }
    /// The monthly cap, when one is set.
    var limit: Decimal? { limitMinor.flatMap { $0 > 0 ? major($0) : nil } }
    /// The share of the cap that is spent, 0–1, when there is a cap.
    var fraction: Double? { limitMinor.flatMap { $0 > 0 ? min(max(spentMinor / $0, 0), 1) : nil } }

    private func major(_ minor: Double) -> Decimal {
        (Decimal(minor) / pow(10, decimals)).rounded(decimals)
    }

    /// `amount` in the account's own currency, through the shared formatter ("€12.40", "$14.50"). Without a
    /// currency, just the number.
    func format(_ amount: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        Format.money(amount, currency: currency, digits: decimals, locale: locale)
    }
}

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self, result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

/// What the usage endpoint reported at one moment. A limit that is absent is not shown.
struct Usage: Codable, Equatable, Sendable {
    var limits: [LimitKind: Limit]
    /// Present only when extra usage is turned on for the account.
    var extra: ExtraUsage? = nil
    var fetchedAt: Date

    subscript(kind: LimitKind) -> Limit? { limits[kind] }

    /// The limits reported, in the menu bar's order: one row each, and none for a limit not reported.
    var reported: [(kind: LimitKind, limit: Limit)] {
        LimitKind.allCases.compactMap { kind in limits[kind].map { (kind, $0) } }
    }

    /// No limit and no extra usage: the account currently reports none (shown as such, never as empty bars).
    var isEmpty: Bool { limits.isEmpty && extra == nil }

    /// Decodes `GET /api/oauth/usage`. The endpoint is unofficial, so anything unknown or malformed is skipped rather
    /// than failing the whole response. A response is the whole truth: a limit it doesn't report (absent, `null`, a
    /// `null` utilization, extra usage turned off) is not shown, whatever an earlier one said. Only a body that is not
    /// a usage response at all (none of its fields, even as `null`) throws, so the last good values stay.
    static func decode(_ data: Data, at date: Date = Date()) throws -> Usage {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.recognised else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a usage response")) }
        var limits: [LimitKind: Limit] = [:]
        let entries = raw.limits ?? []
        // `five_hour` and `seven_day` carry no grade: it comes from the matching `limits[]` row whichever gave the percentage.
        let session = entries.first(where: { $0.kind == "session" })
        if var window = raw.five_hour?.limit ?? session?.limit {
            window.reportedSeverity = session?.severity
            limits[.session] = window
        }
        let weekly = entries.first(where: { $0.kind == "weekly_all" })
        if var window = raw.seven_day?.limit ?? weekly?.limit {
            window.reportedSeverity = weekly?.severity
            limits[.weekly] = window
        }
        if let fable = entries.first(where: {
            $0.kind == "weekly_scoped" && $0.scope?.model?.display_name?.caseInsensitiveCompare("Fable") == .orderedSame
        })?.limit {
            limits[.fable] = fable
        }
        var extra = raw.extra_usage?.extra
        // The spending's grade: the active "spend" row, else the monthly one (the cap extra usage reports), else any.
        let spend = entries.filter { $0.kind == "spend" }
        extra?.reportedSeverity = (spend.first { $0.is_active == true } ?? spend.first { $0.group == "monthly" }
            ?? spend.first)?.severity
        return Usage(limits: limits, extra: extra, fetchedAt: date)
    }

    // The wire format. Every field is optional and each element decodes on its own (`Lenient`), so a new kind, a
    // changed type or a null never makes the response unreadable.
    private struct Raw: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Entry]?
        let extra_usage: Extra?
        /// Whether any field Tidemark knows is there, even as `null`.
        let recognised: Bool

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            recognised = !c.allKeys.isEmpty
            five_hour = try? c.decodeIfPresent(Window.self, forKey: .five_hour)
            seven_day = try? c.decodeIfPresent(Window.self, forKey: .seven_day)
            limits = (try? c.decodeIfPresent([Lenient<Entry>].self, forKey: .limits))?.compactMap(\.value)
            extra_usage = try? c.decodeIfPresent(Extra.self, forKey: .extra_usage)
        }
        enum Keys: String, CodingKey { case five_hour, seven_day, limits, extra_usage }
    }

    private struct Extra: Decodable {
        let is_enabled: Bool?
        let monthly_limit: Double?
        let used_credits: Double?
        let currency: String?
        let decimal_places: Int?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            is_enabled = try? c.decodeIfPresent(Bool.self, forKey: .is_enabled)
            monthly_limit = try? c.decodeIfPresent(Double.self, forKey: .monthly_limit)
            used_credits = try? c.decodeIfPresent(Double.self, forKey: .used_credits)
            currency = try? c.decodeIfPresent(String.self, forKey: .currency)
            decimal_places = try? c.decodeIfPresent(Int.self, forKey: .decimal_places)
        }
        enum Keys: String, CodingKey { case is_enabled, monthly_limit, used_credits, currency, decimal_places }

        var extra: ExtraUsage? {
            guard is_enabled == true, let used_credits else { return nil }
            return ExtraUsage(spentMinor: used_credits, limitMinor: monthly_limit, currency: currency,
                              decimals: min(max(decimal_places ?? 2, 0), 4))
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
        var limit: Limit? { utilization.map { Limit(percent: $0, resetsAt: resets_at.flatMap(ISO8601.date)) } }
    }

    private struct Entry: Decodable {
        let kind: String?
        let group: String?
        let is_active: Bool?
        let percent: Double?
        let resets_at: String?
        let severity: String?
        let scope: Scope?
        var limit: Limit? {
            percent.map { Limit(percent: $0, resetsAt: resets_at.flatMap(ISO8601.date), reportedSeverity: severity) }
        }

        struct Scope: Decodable { let model: Model? }
        struct Model: Decodable { let display_name: String? }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            group = try? c.decodeIfPresent(String.self, forKey: .group)
            is_active = try? c.decodeIfPresent(Bool.self, forKey: .is_active)
            percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            resets_at = try? c.decodeIfPresent(String.self, forKey: .resets_at)
            severity = try? c.decodeIfPresent(String.self, forKey: .severity)
            scope = try? c.decodeIfPresent(Scope.self, forKey: .scope)
        }
        enum Keys: String, CodingKey { case kind, group, is_active, percent, resets_at, severity, scope }
    }
}


extension Usage {
    /// The usage as meters (in the menu bar's order) and, when extra usage is on, its spending as money.
    var snapshot: Snapshot {
        Snapshot(meters: reported.map { kind, limit in
            Meter(id: kind.id, title: kind.title, label: kind.menuBarLabel, noun: kind.noun, percent: limit.percent,
                  resetsAt: limit.resetsAt, reportedSeverity: limit.reportedSeverity, short: kind == .session)
        }, money: extra.map { [$0.money] } ?? [], fetchedAt: fetchedAt)
    }
}

extension ExtraUsage {
    var money: Money {
        Money(id: "extra", title: "Extra usage", amount: spent, currency: currency, digits: decimals, limit: limit,
              limitLabel: "monthly limit", reportedSeverity: reportedSeverity)
    }
}

extension Limit {
    /// How close this limit is to running out.
    var severity: Severity { Severity(server: reportedSeverity, percent: percent) }
}
