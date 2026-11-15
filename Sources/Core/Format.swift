import Foundation

/// The texts that describe a time: when a limit resets, and how fresh the data is.
enum Format {
    /// "Resets in 2 hr 13 min" within a day, else "Resets Thu 21:00" in the user's locale and time zone.
    static func reset(_ date: Date?, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                      timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        // Passed: the value it went with is no longer true, so there is nothing to say "resets now" about.
        if seconds <= 0 { return nil }
        if seconds < 24 * 3600 { return "Resets in \(duration(seconds))" }
        return "Resets \(weekdayTime(date, locale: locale, timeZone: timeZone))"
    }

    /// "Reset at 21:00", or "Reset Thu 21:00" when it was not today: a limit whose value is withheld since then.
    static func resetPassed(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                            timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.isDate(date, inSameDayAs: now) else { return "Reset " + weekdayTime(date, locale: locale, timeZone: timeZone) }
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
            .hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return "Reset at " + date.formatted(style)
    }

    /// "Thu 21:00": the weekday and the time, as the locale writes them.
    static func weekdayTime(_ date: Date, locale: Locale = .autoupdatingCurrent,
                            timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
        style = style.weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return date.formatted(style)
    }

    /// "2 hr 13 min", "13 min", "less than 1 min". Minutes are rounded up, so a reset is never announced early.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "less than 1 min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "Updated just now", "Updated 4 min ago", "Updated 2 hr ago", "Updated Thu 21:00".
    static func updated(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                        timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        if seconds < 24 * 3600 { return "Updated \(Int(seconds / 3600)) hr ago" }
        return "Updated \(weekdayTime(date, locale: locale, timeZone: timeZone))"
    }

    /// "Rate-limited by Anthropic · retrying at 19:12 · Updated 4 min ago": what went wrong, when it is tried again
    /// (only while that is still ahead), and how old the data shown is.
    static func failure(_ message: String, retry: Date?, updated: Date?, now: Date = Date(),
                        locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var parts = [message.hasSuffix(".") ? String(message.dropLast()) : message]
        if let retry, retry > now { parts.append(retrying(at: retry, now: now, locale: locale, timeZone: timeZone)) }
        if let updated { parts.append(self.updated(updated, now: now, locale: locale, timeZone: timeZone)) }
        return parts.joined(separator: " · ")
    }

    /// "retrying at 19:12", or "retrying Thu 19:12" when it is not today. Minutes round up, so it is never early.
    static func retrying(at date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                         timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let minute = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.isDate(minute, inSameDayAs: now) else {
            return "retrying " + weekdayTime(minute, locale: locale, timeZone: timeZone)
        }
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
            .hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return "retrying at " + minute.formatted(style)
    }

    /// "48%".
    static func percent(_ value: Int) -> String { "\(value)%" }

    // MARK: Money

    /// "$1,234.56": cents of USD, to the cent. The Admin API reports US dollars only, so the symbol is always "$",
    /// never a locale's "US$" or "1.234,56 $": only grouping and the decimal separator follow the locale.
    static func money(cents: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        money(dollars(cents), currency: "USD", digits: 2, locale: locale)
    }

    /// Any amount Tidemark shows, in its own currency (ISO 4217 code), to `digits` decimals. US dollars are always
    /// "$" before the number, as for organisation costs, so the same currency looks the same everywhere in the panel;
    /// any other currency is written as the locale writes it ("€12.40", "12,40 €"). Without a currency, the number.
    static func money(_ amount: Decimal, currency: String?, digits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let digits = max(digits, 0)
        let number = Decimal.FormatStyle(locale: locale).precision(.fractionLength(digits))
        guard let currency = currency?.trimmingCharacters(in: .whitespaces).uppercased(), !currency.isEmpty else {
            return amount.formatted(number)
        }
        if currency == "USD" { return dollar(amount.formatted(number)) }
        return amount.formatted(.currency(code: currency).locale(locale).precision(.fractionLength(digits)))
    }

    /// The menu bar's figure: "$4.37" under 10, "$412" under 10,000, then "$12K". US dollars always with "$", other
    /// currencies as the locale writes them, a bare number without one. Rounded down, so it never shows more than
    /// there is.
    static func compactMoney(_ amount: Decimal, currency: String?, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Decimal.FormatStyle(locale: locale).rounded(rule: .down)
        let number: String
        if amount < 10 { number = amount.formatted(style.precision(.fractionLength(2))) }
        else if amount < 10_000 { number = amount.formatted(style.precision(.fractionLength(0))) }
        else { number = amount.formatted(style.notation(.compactName).precision(.significantDigits(2...3))) }
        guard let code = currency?.trimmingCharacters(in: .whitespaces).uppercased(), !code.isEmpty else { return number }
        if code == "USD" { return dollar(number) }
        let symbol = Locale(identifier: locale.identifier + "@currency=" + code).currencySymbol ?? code
        return symbol + number
    }

    /// The menu bar's figure in cents of USD.
    static func compactMoney(cents: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        compactMoney(dollars(cents), currency: "USD", locale: locale)
    }

    /// In place of a figure that can't be shown: "$–".
    static func placeholder(currency: String?) -> String {
        guard let code = currency?.uppercased(), !code.isEmpty else { return "–" }
        if code == "USD" { return "$–" }
        return (Locale(identifier: "en@currency=" + code).currencySymbol ?? code) + "–"
    }

    /// "$" before a formatted number, after its minus sign.
    private static func dollar(_ number: String) -> String {
        guard let first = number.first, first == "-" || first == "\u{2212}" else { return "$" + number }
        return String(first) + "$" + number.dropFirst()
    }

    private static func dollars(_ cents: Decimal) -> Decimal { cents / 100 }

    /// "since 1 Nov, 01:00": when a UTC month or day began, in the user's time zone.
    static func since(_ date: Date, day: Bool, locale: Locale = .autoupdatingCurrent,
                      timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
        style = day ? style.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
                    : style.day().month(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
        return "since " + date.formatted(style)
    }

    /// "as of 18:30", or "as of Thu 18:30" when it is not from today.
    static func asOf(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                     timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timeZone)
                .hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
            return "as of " + date.formatted(style)
        }
        return "as of " + weekdayTime(date, locale: locale, timeZone: timeZone)
    }
}

/// ISO 8601 timestamps as the API writes them, with or without fractional seconds (microseconds included).
enum ISO8601 {
    static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: fractional) { return date }
        if let date = try? Date(string, strategy: plain) { return date }
        // Foundation's parser takes at most milliseconds on some systems: retry with the fraction cut to three digits.
        guard let dot = string.firstIndex(of: "."), let end = string[dot...].firstIndex(where: { !$0.isNumber && $0 != "." })
        else { return nil }
        let digits = string[string.index(after: dot)..<end]
        let trimmed = string[..<dot] + "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0) + string[end...]
        return try? Date(String(trimmed), strategy: fractional)
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()
}
