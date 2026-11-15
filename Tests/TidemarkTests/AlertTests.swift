import Foundation
import Testing
@testable import TidemarkCore

@Suite struct AlertTests {
    let reset = Date(timeIntervalSince1970: 1_789_160_400)

    private func usage(_ kind: LimitKind, _ percent: Double, resetsAt: Date? = nil) -> Snapshot {
        Usage(limits: [kind: Limit(percent: percent, resetsAt: resetsAt ?? reset)], fetchedAt: .now).snapshot
    }

    private func meter(_ kind: LimitKind) -> Meter { usage(kind, 0)[meter: kind.id]! }

    /// Claude's thresholds are the standard policy: a short window notifies later.
    @Test func thresholds() {
        #expect(AlertPolicy.standard.thresholds(meter(.session)) == [75, 90, 98])
        #expect(AlertPolicy.standard.thresholds(meter(.weekly)) == [50, 75, 90, 98])
        #expect(AlertPolicy.standard.thresholds(meter(.fable)) == [50, 75, 90, 98])
        #expect(Claude.account.alerts == .standard)
        #expect(Claude.console.alerts.thresholds(meter(.weekly)).isEmpty)
    }

    @Test func anyProvidersMeters() {
        var fired = Set<String>()
        let snapshot = Snapshot(meters: [Meter(id: "daily", title: "Daily requests", label: "d", percent: 80, short: true),
                                         Meter(id: "monthly", title: "Monthly spend", label: "m", percent: 60)], fetchedAt: .now)
        let due = Alerts.evaluate(account: "x", snapshot: snapshot, fired: &fired)
        #expect(due.map(\.meter) == ["daily", "monthly"] && due.map(\.threshold) == [75, 50])
        #expect(due.map(\.noun) == ["Daily requests", "Monthly spend"], "named by title without a noun")
    }

    @Test func belowEveryThresholdSendsNothing() {
        var fired = Set<String>()
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.session, 74.9), fired: &fired).isEmpty)
        #expect(fired.isEmpty)
    }

    @Test func onlyTheHighestCrossedThresholdIsSent() {
        var fired = Set<String>()
        let due = Alerts.evaluate(account: "a", snapshot: usage(.weekly, 92), fired: &fired)
        #expect(due == [Alerts.Due(meter: "weekly", noun: "Weekly limit", threshold: 90, resetsAt: reset)])
        #expect(fired.count == 3)
    }

    @Test func eachThresholdOncePerWindow() {
        var fired = Set<String>()
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 55), fired: &fired).map(\.threshold) == [50])
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 60), fired: &fired).isEmpty)
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 76), fired: &fired).map(\.threshold) == [75])
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 99), fired: &fired).map(\.threshold) == [98])
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 100), fired: &fired).isEmpty)
        // a new window starts over
        let next = reset + 7 * 86400
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 51, resetsAt: next), fired: &fired).map(\.threshold) == [50])
    }

    @Test func accountsAndLimitsAreIndependent() {
        var fired = Set<String>()
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.fable, 80), fired: &fired).map(\.threshold) == [75])
        #expect(Alerts.evaluate(account: "b", snapshot: usage(.fable, 80), fired: &fired).map(\.threshold) == [75])
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 80), fired: &fired).map(\.threshold) == [75])
        var both = Usage(limits: [.session: Limit(percent: 91, resetsAt: reset), .fable: Limit(percent: 50, resetsAt: reset)],
                         fetchedAt: .now)
        var fresh = Set<String>()
        #expect(Alerts.evaluate(account: "c", snapshot: both.snapshot, fired: &fresh).map(\.meter) == ["session", "fable"])
        both.limits[.session]?.percent = 95
        #expect(Alerts.evaluate(account: "c", snapshot: both.snapshot, fired: &fresh).isEmpty)
    }

    @Test func firedStateSurvivesEncoding() throws {
        var fired = Set<String>()
        _ = Alerts.evaluate(account: "a", snapshot: usage(.weekly, 91), fired: &fired)
        var restored = try JSONDecoder().decode(Set<String>.self, from: JSONEncoder().encode(fired))
        #expect(Alerts.evaluate(account: "a", snapshot: usage(.weekly, 91), fired: &restored).isEmpty)
    }

    @Test func pruneDropsEndedWindows() {
        let old = Alerts.key(account: "a", meter: "weekly", resetsAt: Date(timeIntervalSince1970: 1000), threshold: 50)
        let current = Alerts.key(account: "a", meter: "weekly", resetsAt: reset, threshold: 50)
        let undated = Alerts.key(account: "a", meter: "weekly", resetsAt: nil, threshold: 50)
        #expect(Alerts.prune([old, current, undated], now: reset - 3600) == [current, undated])
    }

    @Test func text() {
        let due = Alerts.Due(meter: "weekly", noun: "Weekly limit", threshold: 90, resetsAt: Date(timeIntervalSince1970: 1_789_160_400))
        let (title, body) = Alerts.text(due, name: "Jane Doe", email: "jane@example.com",
                                        now: Date(timeIntervalSince1970: 1_788_900_000),
                                        locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(title == "Weekly limit 90% used")
        #expect(body == "Jane Doe (jane@example.com) · resets Fri 21:00")
        let soon = Alerts.Due(meter: "session", noun: "Session limit", threshold: 98, resetsAt: Date(timeIntervalSince1970: 1_788_903_600))
        let (sessionTitle, sessionBody) = Alerts.text(soon, name: "", email: "sam@example.org", now: Date(timeIntervalSince1970: 1_788_900_000))
        #expect(sessionTitle == "Session limit 98% used")
        #expect(sessionBody == "sam@example.org · resets in 1 hr")
    }
}
