import Foundation

// What may be shown of an account's saved data at a given moment. Everything Tidemark displays (panel, menu bar,
// VoiceOver) goes through here, so a value is either still true enough to show or not shown at all:
//
// - Not authenticated (signed out, key rejected, waiting for the login keychain, no tokens): nothing.
// - Older than the freshness window, or from a clock far off: nothing.
// - A meter whose reset time has passed, or a figure whose period is over: its value is withheld until a response
//   from after it.
// - Older than one refresh (plus grace) but within the window: shown, marked late.

/// How old saved data may be and still be shown.
enum Freshness {
    /// A refresh is never exactly on time: the timer's tolerance (at most 30 s), the queue's 2 s between accounts
    /// and a request's 30 s timeout. Data this much past one interval has missed a refresh.
    static let grace: TimeInterval = 60
    /// The shortest window. The backoff after a failure is 1, 2, then 5 minutes: ten minutes outlasts the first
    /// three steps (8 min), so one failed refresh, or a short run of them, never blanks the display, while data
    /// that kept failing for longer is withheld.
    static let minimumWindow: TimeInterval = 600

    /// Data older than this is not shown: two intervals (one refresh missed, the next one late), at least ten
    /// minutes. With the 5-minute default that is 10 minutes; with 60 minutes, 2 hours.
    static func window(interval: TimeInterval) -> TimeInterval { max(2 * interval, minimumWindow) }

    enum Age: Equatable, Sendable {
        /// As fresh as refreshing keeps it.
        case current
        /// A refresh was missed: shown, but marked (faded in the menu bar, "Updated N min ago" in the panel).
        case late
        /// Beyond the window: not shown.
        case expired
    }

    /// How old data fetched at `fetchedAt` is at `now`, refreshed every `interval`. Exactly at a boundary it is
    /// still the younger kind. Data from further in the future than the window (the clock was set back a lot)
    /// can't be dated and counts as expired; a little in the future counts as current.
    static func age(_ fetchedAt: Date, interval: TimeInterval, now: Date) -> Age {
        let age = now.timeIntervalSince(fetchedAt)
        let window = window(interval: interval)
        if age > window || age < -window { return .expired }
        return age > interval + grace ? .late : .current
    }

    /// When `age` next changes for data fetched at `fetchedAt`, if it still will.
    static func nextChange(_ fetchedAt: Date, interval: TimeInterval, now: Date) -> Date? {
        let window = window(interval: interval)
        return [fetchedAt.addingTimeInterval(-window), fetchedAt.addingTimeInterval(interval + grace),
                fetchedAt.addingTimeInterval(window)]
            .map { $0.addingTimeInterval(0.001) }                       // just past the boundary, which still counts
            .filter { $0 > now }.min()
    }
}

/// An account's snapshot as it may be shown at one moment.
struct ShownSnapshot: Equatable, Sendable {
    /// One reported meter, in the snapshot's order.
    struct Row: Equatable, Sendable {
        enum Value: Equatable, Sendable {
            case current(Meter)
            /// The meter reset at this time, after the data was fetched: its old value is no longer true.
            case reset(Date)
        }
        let meter: Meter
        let value: Value

        var current: Meter? { if case .current(let meter) = value { meter } else { nil } }
    }

    /// One money figure; `amount` is nil once its period is over.
    struct Figure: Equatable, Sendable {
        let money: Money
        let amount: Decimal?
    }

    var rows: [Row]
    var figures: [Figure]
    var plan: String?
    /// Why nothing is reported, when the provider says.
    var note: String?
    var fetchedAt: Date
    var late: Bool

    /// Nothing was reported.
    var isEmpty: Bool { rows.isEmpty && figures.isEmpty }
    /// The menu bar's figure, while it applies.
    var headline: Figure? { figures.first { $0.money.headline } }

    /// `snapshot` as it may be shown at `now`, or nil when none of it may: the account isn't authenticated, the data
    /// is beyond the freshness window, or its headline figure's period is over (the figure it is read for no longer
    /// applies).
    init?(_ snapshot: Snapshot?, authenticated: Bool, interval: TimeInterval, now: Date) {
        guard authenticated, let snapshot else { return nil }
        let age = Freshness.age(snapshot.fetchedAt, interval: interval, now: now)
        guard age != .expired, snapshot.headline?.current(at: now) ?? true else { return nil }
        rows = snapshot.meters.map { meter in
            if let reset = meter.resetsAt, reset <= now { return Row(meter: meter, value: .reset(reset)) }
            return Row(meter: meter, value: .current(meter))
        }
        figures = snapshot.money.map { Figure(money: $0, amount: $0.current(at: now) ? $0.amount : nil) }
        plan = snapshot.plan
        note = snapshot.note
        fetchedAt = snapshot.fetchedAt
        late = age == .late
    }

    /// What the menu bar draws for an account: its live values, or, when nothing may be shown but the last snapshot
    /// is known, only that snapshot's layout (its meters' labels in order, or a placeholder for its figure), never
    /// its values; or nothing.
    enum MenuBar: Equatable, Sendable {
        case live(ShownSnapshot)
        case unavailable(labels: [String], figure: Money?)
        case none
    }

    static func menuBar(_ snapshot: Snapshot?, authenticated: Bool, interval: TimeInterval, now: Date) -> MenuBar {
        if let shown = ShownSnapshot(snapshot, authenticated: authenticated, interval: interval, now: now) { return .live(shown) }
        guard let snapshot else { return .none }
        let labels = snapshot.meters.map(\.label)
        if !labels.isEmpty { return .unavailable(labels: labels, figure: nil) }
        if let headline = snapshot.headline { return .unavailable(labels: [], figure: headline) }
        return .none
    }

    /// When what is shown of `snapshot` next changes by itself: it turns late or expires, a meter resets, or a
    /// figure's period ends.
    static func nextChange(_ snapshot: Snapshot?, authenticated: Bool, interval: TimeInterval, now: Date) -> Date? {
        guard authenticated, let snapshot else { return nil }
        let ends = snapshot.meters.compactMap(\.resetsAt) + snapshot.money.compactMap(\.end)
        return ([Freshness.nextChange(snapshot.fetchedAt, interval: interval, now: now)].compactMap(\.self)
            + ends.filter { $0 > now }).min()
    }
}
