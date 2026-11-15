import Foundation

// Daily costs, for logins that read what an organisation spent (`HistoryKind.dailyCosts`). Amounts are USD cents as
// decimal strings and stay `Decimal` from the wire to the screen: money never passes through a binary float.
//
// Time zones: cost reports bucket by UTC day and nothing finer, so a day here is a UTC day and a month a UTC month
// (the month providers bill). A local month can't be built from UTC days without guessing how a boundary day splits.
// The panel says when the month and the day began in local time ("since 1 Nov, 01:00"), so the rule is visible.

/// UTC days and months, the units of the cost report.
enum CostCalendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// The start of the UTC day `date` is in.
    static func day(_ date: Date) -> Date { utc.startOfDay(for: date) }
    /// The start of the UTC month `date` is in.
    static func month(_ date: Date) -> Date { utc.dateInterval(of: .month, for: date)?.start ?? day(date) }
    static func add(days: Int, to date: Date) -> Date { utc.date(byAdding: .day, value: days, to: date) ?? date }
    /// Whole UTC days from `a` to `b`.
    static func days(from a: Date, to b: Date) -> Int { utc.dateComponents([.day], from: day(a), to: day(b)).day ?? 0 }

    /// "2026-11-01", the key of a day in the cost cache.
    static func key(_ day: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func day(key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// An exact amount (cents in a ledger, major units in a `Money`), saved as its decimal string.
struct Cents: Codable, Equatable, Sendable {
    var value: Decimal
    init(_ value: Decimal) { self.value = value }

    /// A decimal string as the API writes amounts: "123.45", "-0.5", "7". Anything else (exponents, spaces inside,
    /// trailing text, which `Decimal(string:)` would quietly cut short) is nil.
    static func parse(_ text: String) -> Decimal? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = body.hasPrefix("-") ? body.dropFirst() : Substring(body)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) })
        else { return nil }
        return Decimal(string: body, locale: Locale(identifier: "en_US_POSIX"))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self.parse(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a decimal amount")
        }
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.description)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// An organisation's daily costs as far as Tidemark has read them: cents per UTC day over one unbroken range of
/// days. A day in the range without an entry cost nothing (the API may leave out empty buckets). Cached on disk as a
/// small JSON file per organisation, a year at most.
struct CostLedger: Codable, Equatable, Sendable {
    /// Cents per day, keyed by the day's start (UTC).
    private(set) var days: [Date: Decimal] = [:]
    /// The days read, from the first (inclusive) to the end (exclusive), both UTC midnights.
    private(set) var covered: Range<Date>?

    static let keepDays = 400

    init() {}

    /// Takes what a request returned for `range`: its days replace what was known, and a day in it the response
    /// left out is zero. A range that neither overlaps nor touches what was read starts the ledger afresh, so it
    /// always covers one unbroken run of days (older days are then read again on demand).
    mutating func merge(_ read: [Date: Decimal], covering range: Range<Date>) {
        let lower = CostCalendar.day(range.lowerBound)
        var upper = CostCalendar.day(range.upperBound)
        if upper < range.upperBound { upper = CostCalendar.add(days: 1, to: upper) }
        guard lower < upper else { return }
        if let covered, lower <= covered.upperBound, upper >= covered.lowerBound {
            self.covered = min(lower, covered.lowerBound)..<max(upper, covered.upperBound)
        } else {
            days = [:]
            covered = lower..<upper
        }
        days = days.filter { !(lower..<upper).contains($0.key) }
        for (day, cents) in read {
            let day = CostCalendar.day(day)
            if (lower..<upper).contains(day), cents != 0 { days[day] = cents }
        }
    }

    /// Forgets days before `start`.
    mutating func prune(before start: Date) {
        let start = CostCalendar.day(start)
        guard let covered, covered.lowerBound < start else { return }
        days = days.filter { $0.key >= start }
        self.covered = start < covered.upperBound ? start..<covered.upperBound : nil
        if self.covered == nil { days = [:] }
    }

    /// A day's cents; nil for a day not read.
    func cents(on day: Date) -> Decimal? {
        let day = CostCalendar.day(day)
        guard covered?.contains(day) == true else { return nil }
        return days[day] ?? 0
    }

    /// Every day from `start` through the day of `end`, as far as read, oldest first, empty days as zero.
    func series(from start: Date, through end: Date) -> [(day: Date, cents: Decimal)] {
        guard let covered else { return [] }
        var day = max(CostCalendar.day(start), covered.lowerBound)
        let last = min(CostCalendar.day(end), CostCalendar.add(days: -1, to: covered.upperBound))
        var result: [(Date, Decimal)] = []
        while day <= last {
            result.append((day, days[day] ?? 0))
            day = CostCalendar.add(days: 1, to: day)
        }
        return result
    }

    /// Cents spent this UTC month and today so far, at `now`. Nil unless the whole month up to today has been read.
    func monthAndToday(at now: Date) -> (month: Decimal, today: Decimal)? {
        let monthStart = CostCalendar.month(now), today = CostCalendar.day(now)
        guard let covered, covered.lowerBound <= monthStart, covered.upperBound > today else { return nil }
        return (series(from: monthStart, through: today).reduce(Decimal(0)) { $0 + $1.cents }, days[today] ?? 0)
    }

    /// Month to date and today so far as money figures (US dollars), the month the menu bar's figure. Nil unless
    /// the whole UTC month up to today has been read.
    func figures(at now: Date) -> [Money]? {
        guard let (month, today) = monthAndToday(at: now) else { return nil }
        return Self.figures(month: month, today: today, monthStart: CostCalendar.month(now), day: CostCalendar.day(now))
    }

    /// Cents spent in the UTC month from `monthStart` and on the UTC day `day`, as money figures.
    static func figures(month: Decimal, today: Decimal, monthStart: Date, day: Date) -> [Money] {
        let nextMonth = CostCalendar.utc.date(byAdding: .month, value: 1, to: monthStart) ?? CostCalendar.add(days: 31, to: monthStart)
        return [
            Money(id: "month", title: "Used this month", amount: month / 100, currency: "USD", start: monthStart,
                  end: nextMonth, headline: true),
            Money(id: "today", title: "Today so far", amount: today / 100, currency: "USD", start: day,
                  end: CostCalendar.add(days: 1, to: day), partial: true),
        ]
    }

    // MARK: Codable: {"from":"2026-10-01","to":"2026-11-13","days":{"2026-10-02":"1234.5"}}

    private enum Keys: String, CodingKey { case from, to, days }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let from = CostCalendar.day(key: try c.decode(String.self, forKey: .from)),
              let to = CostCalendar.day(key: try c.decode(String.self, forKey: .to)), from < to else { return }
        covered = from..<to
        for (key, amount) in (try? c.decode([String: Cents].self, forKey: .days)) ?? [:] {
            if let day = CostCalendar.day(key: key), (from..<to).contains(day) { days[day] = amount.value }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        guard let covered else { return }
        try c.encode(CostCalendar.key(covered.lowerBound), forKey: .from)
        try c.encode(CostCalendar.key(covered.upperBound), forKey: .to)
        try c.encode(Dictionary(uniqueKeysWithValues: days.map { (CostCalendar.key($0.key), Cents($0.value)) }), forKey: .days)
    }
}

/// Which days to ask the cost report for.
enum CostPlan {
    /// How far back the history goes.
    static let maximumDays = 365
    /// Days per backfill request: with the day after it (asked for so the last day surely ends before the
    /// range's end), within a report's usual 31 buckets per page.
    static let chunkDays = 30

    /// A refresh: the UTC month so far, and the two days before today (still settling) even across a month's start.
    static func refresh(now: Date) -> Range<Date> {
        let today = CostCalendar.day(now)
        return min(CostCalendar.month(now), CostCalendar.add(days: -2, to: today))..<CostCalendar.add(days: 1, to: today)
    }

    /// The ranges still to read so `ledger` reaches back to `start` (at most a year), newest first, at most
    /// `chunkDays` each.
    static func backfill(_ ledger: CostLedger, from start: Date, now: Date) -> [Range<Date>] {
        let tomorrow = CostCalendar.add(days: 1, to: CostCalendar.day(now))
        let target = max(CostCalendar.day(start), CostCalendar.add(days: -maximumDays, to: tomorrow))
        let end = ledger.covered?.lowerBound ?? tomorrow
        var chunks: [Range<Date>] = []
        var upper = end
        while upper > target {
            let lower = max(CostCalendar.add(days: -chunkDays, to: upper), target)
            chunks.append(lower..<upper)
            upper = lower
        }
        return chunks
    }
}

