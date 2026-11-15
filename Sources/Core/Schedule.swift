import Foundation

/// The refresh intervals the slider offers.
enum Interval {
    static let steps: [TimeInterval] = [15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    /// Every 5 minutes: what most providers tolerate without rate-limiting (`Pace`).
    static let defaultValue: TimeInterval = 300

    /// The interval to use from the stored one. A value saved with `chosen` was picked in Settings and is kept. One
    /// saved without the flag was too, except 60 s: builds that saved the interval without the flag saved their
    /// 1-minute default even when untouched, and that follows the default.
    static func stored(_ value: TimeInterval?, chosen: Bool?) -> TimeInterval {
        guard let value, value > 0, chosen == true || (chosen == nil && value != 60) else { return defaultValue }
        return steps[index(of: value)]
    }

    /// The step nearest to `seconds`, so a stored value that is no longer offered still maps to the slider.
    static func index(of seconds: TimeInterval) -> Int {
        steps.indices.min { abs(steps[$0] - seconds) < abs(steps[$1] - seconds) } ?? 2
    }

    /// "15 s", "1 min", "60 min".
    static func label(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}

/// When an account is next due for a refresh.
enum Due {
    /// The last attempt plus the interval, but not before a backoff ends. A last attempt in the future (the clock
    /// was set back) counts as now, so a clock change can't stall refreshing.
    /// `resets` are the reset times of the meters the data shows, and `jitter` how long after one to refresh (so
    /// clients don't all ask at the same second): a reset not yet tried after makes the account due then, earlier
    /// than the interval would. A backoff still wins.
    static func next(lastAttempt: Date?, notBefore: Date, interval: TimeInterval, resets: [Date] = [],
                     jitter: TimeInterval = 0, now: Date = Date()) -> Date {
        let last = lastAttempt.map { min($0, now) } ?? .distantPast
        let backoff = notBefore.timeIntervalSince(now) > Backoff.ceiling ? now.addingTimeInterval(Backoff.ceiling) : notBefore
        let reset = resets.map { $0.addingTimeInterval(jitter) }.filter { $0 > last }.min()
        return max(min(last.addingTimeInterval(interval), reset ?? .distantFuture), backoff)
    }

    /// How long after a reset an account is refreshed: 2–10 s, the same for an account every time it is asked (an
    /// FNV-1a hash of its id, stable across launches), spread across accounts.
    static func jitter(account: String) -> TimeInterval {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in account.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return 2 + Double(hash % 8001) / 1000
    }
}

/// How long to wait after a failed or rate-limited fetch. The server's `Retry-After` wins; otherwise the wait grows
/// 1, 2, 5, 15 minutes with each failure in a row.
enum Backoff {
    static let ladder: [TimeInterval] = [60, 120, 300, 900]
    /// A `Retry-After` beyond this is taken as this, so a bad header can't silence an account for days.
    static let ceiling: TimeInterval = 3600

    static func delay(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 1), ceiling) }
        return ladder[min(max(failures, 1), ladder.count) - 1]
    }

    /// `Retry-After` as seconds from `now`: either a number of seconds or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite { return max(seconds, 0) }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(date.timeIntervalSince(now), 0) }
        }
        return nil
    }
}
