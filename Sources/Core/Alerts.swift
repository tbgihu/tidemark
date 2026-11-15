import Foundation

/// The thresholds at which a percent meter notifies.
struct AlertPolicy: Equatable, Sendable {
    /// For a short rolling window (`Meter.short`): it fills and empties within hours, so only late warnings help.
    var short: [Int]
    /// For a day, week or month.
    var long: [Int]

    func thresholds(_ meter: Meter) -> [Int] { meter.short ? short : long }

    /// 75, 90 and 98 % for a short window; 50, 75, 90 and 98 % otherwise.
    static let standard = AlertPolicy(short: [75, 90, 98], long: [50, 75, 90, 98])
    static let never = AlertPolicy(short: [], long: [])
}

/// When to notify about a meter: each threshold once per reset window, and only the highest one when several are
/// crossed at once.
enum Alerts {
    /// Identifies a threshold within one reset window of one account's meter.
    static func key(account: String, meter: String, resetsAt: Date?, threshold: Int) -> String {
        let window = resetsAt.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "-"
        return "\(account)|\(meter)|\(window)|\(threshold)"
    }

    /// A notification that is due.
    struct Due: Equatable, Sendable {
        let meter: String
        /// How the notification names the meter.
        let noun: String
        let threshold: Int
        let resetsAt: Date?
    }

    /// The notifications `snapshot` calls for, and `fired` updated with every threshold now crossed (so a lower one
    /// is never sent after a higher one).
    static func evaluate(account: String, snapshot: Snapshot, policy: AlertPolicy = .standard,
                         fired: inout Set<String>) -> [Due] {
        var due: [Due] = []
        for meter in snapshot.meters {
            let crossed = policy.thresholds(meter).filter { meter.clamped >= Double($0) }
            guard let highest = crossed.last else { continue }
            if !fired.contains(key(account: account, meter: meter.id, resetsAt: meter.resetsAt, threshold: highest)) {
                due.append(Due(meter: meter.id, noun: meter.noun ?? meter.title, threshold: highest, resetsAt: meter.resetsAt))
            }
            for threshold in crossed {
                fired.insert(key(account: account, meter: meter.id, resetsAt: meter.resetsAt, threshold: threshold))
            }
        }
        return due
    }

    /// Drops keys whose reset window has ended (a day of slack, for clocks and late responses).
    static func prune(_ fired: Set<String>, now: Date = Date()) -> Set<String> {
        fired.filter { key in
            let parts = key.split(separator: "|")
            guard parts.count == 4, let seconds = TimeInterval(parts[2]) else { return true }
            return Date(timeIntervalSince1970: seconds).addingTimeInterval(24 * 3600) > now
        }
    }

    /// Title and body: "Weekly limit 90% used", "Jane Doe (jane@example.com) · resets Thu 21:00".
    static func text(_ due: Due, name: String, email: String, now: Date = Date(),
                     locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> (String, String) {
        let title = "\(due.noun) \(Format.percent(due.threshold)) used"
        var who = name.isEmpty ? email : email.isEmpty || email == name ? name : "\(name) (\(email))"
        if let reset = Format.reset(due.resetsAt, now: now, locale: locale, timeZone: timeZone) {
            who += " · " + reset.prefix(1).lowercased() + reset.dropFirst()
        }
        return (title, who)
    }
}
