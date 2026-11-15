import Foundation

/// Kimi Code's `GET /coding/v1/usages`, read leniently. Two shapes, often together: request counts (`usage` for the
/// week, `limits[]` per rolling window, numbers as strings) and ratio pools (`usages.limit_5h`, `limit_7d`,
/// `limit_month_total`, each a `used_ratio` 0–1). When both describe the same window and reset, the fuller wins.
enum KimiCode {
    static func snapshot(_ data: Data, now: Date) throws(FetchFailure) -> Snapshot {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.isUsage else { throw .unreadable }

        let session = raw.limits.first { $0.minutes == 300 }?.detail
        var meters: [Meter] = []
        if let reading = best(raw.pools?.session, session) {
            meters.append(Meter(id: "session", title: "5-hour limit", label: "5h", noun: "5-hour limit",
                                percent: reading.percent, resetsAt: reading.resetsAt, short: true))
        }
        if let reading = best(raw.pools?.weekly, raw.usage) {
            meters.append(Meter(id: "weekly", title: "Weekly requests", label: "w", noun: "Weekly limit",
                                percent: reading.percent, resetsAt: reading.resetsAt))
        }
        if let reading = raw.pools?.monthly?.reading {
            meters.append(Meter(id: "monthly", title: "Monthly usage", label: "mo", noun: "Monthly usage",
                                percent: reading.percent, resetsAt: reading.resetsAt))
        }
        return Snapshot(meters: meters, plan: raw.plan, note: raw.plan == nil && meters.isEmpty ? Snapshot.noPlan : nil,
                        fetchedAt: now)
    }

    struct Reading: Equatable {
        let percent: Double
        let resetsAt: Date?
    }

    /// The ratio pool's reading, unless the counts for the same reset (within two seconds) say more is used.
    static func best(_ pool: Pool?, _ counts: Counts?) -> Reading? {
        let ratio = pool?.reading, counted = counts?.reading
        guard let ratio else { return counted }
        guard let counted, let a = ratio.resetsAt, let b = counted.resetsAt, abs(a.timeIntervalSince(b)) <= 2 else { return ratio }
        return counted.percent > ratio.percent ? counted : ratio
    }

    // MARK: Wire format

    struct Raw: Decodable {
        var usage: Counts?
        var limits: [Window] = []
        var pools: Pools?
        var plan: String?
        /// Holds any of the fields a usage response has: anything else is not one.
        var isUsage = false

        private enum Keys: String, CodingKey { case usage, limits, usages, user, version }
        private struct User: Decodable {
            struct Membership: Decodable { let level: String? }
            let membership: Membership?
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            usage = try? c.decodeIfPresent(Counts.self, forKey: .usage)
            limits = ((try? c.decodeIfPresent([Lenient<Window>].self, forKey: .limits)) ?? []).compactMap(\.value)
            pools = try? c.decodeIfPresent(Pools.self, forKey: .usages)
            let level = (try? c.decodeIfPresent(User.self, forKey: .user))?.membership?.level
            plan = Self.plan(level, version: c.text(.version))
            isUsage = [.usage, .limits, .usages, .user].contains { c.contains($0) }
        }

        /// Membership levels by their names in Kimi's V1 catalogue; an unknown level as sent, without its prefix.
        static func plan(_ level: String?, version: String?) -> String? {
            guard let level = level?.trimmingCharacters(in: .whitespaces), !level.isEmpty, level != "LEVEL_UNSPECIFIED"
            else { return nil }
            let names = ["LEVEL_FREE": "Adagio", "LEVEL_TRIAL": "Andante", "LEVEL_BASIC": "Moderato",
                         "LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro"]
            if version == nil || version == "GOODS_VERSION_V1", let name = names[level] { return name }
            let bare = level.hasPrefix("LEVEL_") ? String(level.dropFirst(6)) : level
            return bare.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Request counts: `used` is authoritative (it may pass the limit); `remaining` stands in without it.
    struct Counts: Decodable {
        var limit: Double?
        var used: Double?
        var remaining: Double?
        var resetsAt: Date?

        private enum Keys: String, CodingKey { case limit, used, remaining, resetTime, resetAt, reset_time, reset_at }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            limit = c.number(.limit)?.double
            used = c.number(.used)?.double
            remaining = c.number(.remaining)?.double
            resetsAt = [Keys.resetTime, .resetAt, .reset_time, .reset_at].lazy.compactMap { c.text($0) }.first.flatMap(ISO8601.date)
        }

        var reading: Reading? {
            guard let limit, limit > 0 else { return nil }
            let consumed: Double
            if let used, used >= 0 { consumed = used }
            else if let remaining, (0...limit).contains(remaining) { consumed = limit - remaining }
            else { return nil }
            return Wire.percent(used: consumed, of: limit).map { Reading(percent: $0, resetsAt: resetsAt) }
        }
    }

    struct Window: Decodable {
        let minutes: Int?
        let detail: Counts

        private enum Keys: String, CodingKey { case window, detail }
        private struct Span: Decodable { let duration: Wire.Number?; let timeUnit: String? }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            detail = try c.decode(Counts.self, forKey: .detail)
            let span = try? c.decodeIfPresent(Span.self, forKey: .window)
            let factor = ["TIME_UNIT_MINUTE": 1, "MINUTE": 1, "TIME_UNIT_HOUR": 60, "HOUR": 60, "TIME_UNIT_DAY": 1440, "DAY": 1440]
            if let duration = span?.duration?.int, (1...100_000).contains(duration), let unit = span?.timeUnit.flatMap({ factor[$0] }) {
                minutes = duration * unit
            } else {
                minutes = nil
            }
        }
    }

    struct Pools: Decodable {
        let session: Pool?
        let weekly: Pool?
        let monthly: Pool?

        private enum Keys: String, CodingKey { case limit_5h, limit_7d, limit_month_total }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            session = try? c.decodeIfPresent(Pool.self, forKey: .limit_5h)
            weekly = try? c.decodeIfPresent(Pool.self, forKey: .limit_7d)
            monthly = try? c.decodeIfPresent(Pool.self, forKey: .limit_month_total)
        }
    }

    struct Pool: Decodable {
        let usedRatio: Double?
        let resetsAt: Date?

        private enum Keys: String, CodingKey { case used_ratio, reset_time }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            usedRatio = c.number(.used_ratio)?.double
            resetsAt = c.text(.reset_time).flatMap(ISO8601.date)
        }

        var reading: Reading? {
            guard let usedRatio, usedRatio.isFinite, usedRatio >= 0 else { return nil }
            return Reading(percent: min(usedRatio, 1) * 100, resetsAt: resetsAt)
        }
    }
}

/// Moonshot's `GET /v1/users/me/balance`: `data.available_balance` (cash plus vouchers), in the region's currency.
/// Cash can be negative, an amount owed.
enum MoonshotBalance {
    static func snapshot(_ data: Data, currency: String, now: Date) throws(FetchFailure) -> Snapshot {
        struct Raw: Decodable {
            struct Balance: Decodable {
                let available: Decimal?, voucher: Decimal?, cash: Decimal?
                private enum Keys: String, CodingKey { case available_balance, voucher_balance, cash_balance }
                init(from decoder: any Decoder) throws {
                    let c = try decoder.container(keyedBy: Keys.self)
                    available = c.number(.available_balance)?.decimal
                    voucher = c.number(.voucher_balance)?.decimal
                    cash = c.number(.cash_balance)?.decimal
                }
            }
            let data: Balance?
        }
        guard let balance = (try? JSONDecoder().decode(Raw.self, from: data))?.data,
              let available = balance.available ?? balance.cash.map({ $0 + (balance.voucher ?? 0) })
        else { throw .unreadable }
        var money = [Money(id: "balance", title: "Available balance", role: .balance, amount: available, currency: currency,
                           headline: true)]
        if let voucher = balance.voucher, voucher != 0 {
            money.append(Money(id: "vouchers", title: "Vouchers", role: .credit, amount: voucher, currency: currency))
        }
        if let cash = balance.cash, cash < 0 {
            money.append(Money(id: "owed", title: "Owed", role: .spend, amount: -cash, currency: currency))
        }
        return Snapshot(money: money, fetchedAt: now)
    }
}
