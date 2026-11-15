import Foundation
import Testing
@testable import TidemarkCore

@Suite struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_788_000_000)        // Sat 2026-08-29 10:40 UTC

    /// Two intervals, never under ten minutes.
    @Test func windowIsTwoIntervalsAtLeastTenMinutes() {
        #expect(Freshness.window(interval: 15) == 600)
        #expect(Freshness.window(interval: 60) == 600)
        #expect(Freshness.window(interval: 300) == 600)
        #expect(Freshness.window(interval: 301) == 602)
        #expect(Freshness.window(interval: 3600) == 7200)
        // Always beyond the point where data turns late, so "late" is a real state for every step.
        for interval in Interval.steps { #expect(Freshness.window(interval: interval) > interval + Freshness.grace) }
    }

    @Test func ageBoundaries() {
        func age(_ seconds: TimeInterval, _ interval: TimeInterval = 60) -> Freshness.Age {
            Freshness.age(now - seconds, interval: interval, now: now)
        }
        #expect(age(0) == .current)
        #expect(age(120) == .current)                         // interval + grace: still current
        #expect(age(120.5) == .late)
        #expect(age(600) == .late)                            // the window itself: still shown
        #expect(age(600.5) == .expired)
        #expect(age(3600, 3600) == .current)
        #expect(age(3661, 3600) == .late)
        #expect(age(7200, 3600) == .late)
        #expect(age(7201, 3600) == .expired)
        // From the future: a little is a clock nudge; beyond the window it can't be dated.
        #expect(age(-30) == .current)
        #expect(age(-600) == .current)
        #expect(age(-601) == .expired)
    }

    @Test func nextChangeIsTheNextBoundary() throws {
        let fetched = now - 30
        let late = try #require(Freshness.nextChange(fetched, interval: 60, now: now))
        #expect(abs(late.timeIntervalSince(fetched + 120)) < 0.01)
        #expect(Freshness.age(fetched, interval: 60, now: late) == .late)
        let expiry = try #require(Freshness.nextChange(fetched, interval: 60, now: late))
        #expect(abs(expiry.timeIntervalSince(fetched + 600)) < 0.01)
        #expect(Freshness.age(fetched, interval: 60, now: expiry) == .expired)
        #expect(Freshness.nextChange(fetched, interval: 60, now: expiry) == nil)
    }
}

@Suite struct ShownSnapshotTests {
    let now = Date(timeIntervalSince1970: 1_788_000_000)

    func usage(fetched: TimeInterval = 30, session: Date? = nil) -> Snapshot {
        Usage(limits: [.session: Limit(percent: 83, resetsAt: session ?? now + 3600),
                       .weekly: Limit(percent: 77, resetsAt: now + 86400),
                       .fable: Limit(percent: 0, resetsAt: now + 86400)],
              extra: ExtraUsage(spentMinor: 1450, limitMinor: 3000, currency: "USD", decimals: 2),
              fetchedAt: now - fetched).snapshot
    }

    @Test func currentDataIsShownAsIs() throws {
        let shown = try #require(ShownSnapshot(usage(), authenticated: true, interval: 60, now: now))
        #expect(shown.rows.map(\.meter.id) == ["session", "weekly", "fable"])
        #expect(shown.rows.map(\.current?.rounded) == [83, 77, 0])
        #expect(shown.figures.map(\.amount) == [14.5] && !shown.late && !shown.isEmpty)
    }

    /// Rule 1: signed out, key rejected, waiting for the keychain, no tokens: nothing at all, however fresh.
    @Test func notAuthenticatedShowsNothing() {
        #expect(ShownSnapshot(usage(fetched: 0), authenticated: false, interval: 60, now: now) == nil)
        #expect(ShownSnapshot.nextChange(usage(), authenticated: false, interval: 60, now: now) == nil)
        #expect(ShownSnapshot(nil, authenticated: true, interval: 60, now: now) == nil)
    }

    /// Rule 2: a meter whose reset has passed keeps its row but loses its value; the boundary itself counts as reset.
    @Test func passedResetWithholdsTheValue() throws {
        for reset in [now - 1, now] {
            let shown = try #require(ShownSnapshot(usage(fetched: 30, session: reset), authenticated: true, interval: 60, now: now))
            #expect(shown.rows.first?.value == .reset(reset))
            #expect(shown.rows.first?.current == nil)
            #expect(shown.rows.dropFirst().map(\.current?.rounded) == [77, 0])
        }
        let before = try #require(ShownSnapshot(usage(session: now + 1), authenticated: true, interval: 60, now: now))
        #expect(before.rows.first?.current?.rounded == 83)
        // Nor is "Resets now" ever written for it.
        #expect(Format.reset(now, now: now) == nil)
        #expect(Format.reset(now - 1, now: now) == nil)
    }

    /// Rule 3: within one interval (plus grace) as is; then late; beyond the window nothing.
    @Test func ageDecidesShownLateOrHidden() {
        #expect(ShownSnapshot(usage(fetched: 120), authenticated: true, interval: 60, now: now)?.late == false)
        #expect(ShownSnapshot(usage(fetched: 121), authenticated: true, interval: 60, now: now)?.late == true)
        #expect(ShownSnapshot(usage(fetched: 600), authenticated: true, interval: 60, now: now)?.late == true)
        #expect(ShownSnapshot(usage(fetched: 601), authenticated: true, interval: 60, now: now) == nil)
        #expect(ShownSnapshot(usage(fetched: 3000), authenticated: true, interval: 3600, now: now)?.late == false)
        #expect(ShownSnapshot(usage(fetched: 7201), authenticated: true, interval: 3600, now: now) == nil)
    }

    /// Rule 4: a snapshot saved long ago (as read at launch) shows nothing, and neither does one whose reset passed
    /// while Tidemark wasn't running, even if it is otherwise fresh.
    @Test func launchSnapshot() throws {
        let saved = usage(fetched: 86400, session: now - 3600)
        let account = Account(id: "a", provider: Claude.id, login: Claude.account.id, name: "A", snapshot: saved)
        let data = try JSONEncoder().encode(SavedState(accounts: [account]))
        let loaded = try #require(SavedState.load(data)?.accounts.first?.snapshot)
        #expect(loaded == saved)
        #expect(ShownSnapshot(loaded, authenticated: true, interval: 60, now: now) == nil)
        let recent = try #require(ShownSnapshot(usage(fetched: 200, session: now - 60), authenticated: true, interval: 60, now: now))
        #expect(recent.rows.first?.current == nil && recent.late)
    }

    @Test func noLimitsReportedStaysEmpty() throws {
        let shown = try #require(ShownSnapshot(Snapshot(fetchedAt: now), authenticated: true, interval: 60, now: now))
        #expect(shown.isEmpty)
    }

    @Test func nextChangeIncludesResets() throws {
        let fetched = usage(fetched: 30, session: now + 45)
        #expect(ShownSnapshot.nextChange(fetched, authenticated: true, interval: 60, now: now) == now + 45)
        let late = try #require(ShownSnapshot.nextChange(fetched, authenticated: true, interval: 60, now: now + 45))
        #expect(abs(late.timeIntervalSince(now + 90)) < 0.01)        // fetched + interval + grace
    }
}

@Suite struct MenuBarLayoutTests {
    let now = Date(timeIntervalSince1970: 1_788_000_000)

    func usage(fetched: TimeInterval = 30, kinds: [LimitKind] = [.session, .weekly, .fable]) -> Snapshot {
        Usage(limits: Dictionary(uniqueKeysWithValues: kinds.map { ($0, Limit(percent: 83, resetsAt: now + 3600)) }),
              fetchedAt: now - fetched).snapshot
    }

    @Test func signedOutKeepsTheRowsButNotTheValues() {
        let layout = ShownSnapshot.menuBar(usage(kinds: [.fable, .session]), authenticated: false, interval: 60, now: now)
        #expect(layout == .unavailable(labels: ["5h", "w(F)"], figure: nil))
    }

    @Test func staleBeyondTheWindowKeepsTheRows() {
        let all = ShownSnapshot.MenuBar.unavailable(labels: ["5h", "w(A)", "w(F)"], figure: nil)
        #expect(ShownSnapshot.menuBar(usage(fetched: 600), authenticated: true, interval: 60, now: now) != all)
        #expect(ShownSnapshot.menuBar(usage(fetched: 601), authenticated: true, interval: 60, now: now) == all)
    }

    @Test func neverFetchedHasNoLayout() {
        #expect(ShownSnapshot.menuBar(nil, authenticated: false, interval: 60, now: now) == .none)
        #expect(ShownSnapshot.menuBar(nil, authenticated: true, interval: 60, now: now) == .none)
        #expect(ShownSnapshot.menuBar(usage(kinds: []), authenticated: false, interval: 60, now: now) == .none)
    }

    @Test func currentDataIsLive() {
        guard case .live(let shown) = ShownSnapshot.menuBar(usage(), authenticated: true, interval: 60, now: now) else {
            return #expect(Bool(false))
        }
        #expect(shown.rows.count == 3)
    }

    func costs(fetched: TimeInterval) -> Snapshot {
        Snapshot(money: CostLedger.figures(month: 41_237, today: 1_200, monthStart: CostCalendar.month(now),
                                           day: CostCalendar.day(now)), fetchedAt: now - fetched)
    }

    @Test func organisationKeepsAPlaceholder() {
        let placeholder = ShownSnapshot.MenuBar.unavailable(labels: [], figure: costs(fetched: 0).headline)
        #expect(ShownSnapshot.menuBar(costs(fetched: 0), authenticated: false, interval: 300, now: now) == placeholder)
        #expect(ShownSnapshot.menuBar(costs(fetched: 601), authenticated: true, interval: 300, now: now) == placeholder)
        if case .live = ShownSnapshot.menuBar(costs(fetched: 0), authenticated: true, interval: 300, now: now) {} else {
            #expect(Bool(false))
        }
        #expect(Format.placeholder(currency: "USD") == "$–")
    }
}

@Suite struct ShownCostTests {
    let now = Date(timeIntervalSince1970: 1_788_000_000)        // Sat 2026-08-29 10:40 UTC

    func costs(fetched: TimeInterval, month: Date? = nil, day: Date? = nil) -> Snapshot {
        Snapshot(money: CostLedger.figures(month: 41_237, today: 1_200, monthStart: month ?? CostCalendar.month(now),
                                           day: day ?? CostCalendar.day(now)), fetchedAt: now - fetched)
    }

    /// Rule 5: a rejected key or data beyond the window shows no figures; organisations refresh at least every
    /// 5 minutes, so their window is at least 10 minutes.
    @Test func organisationRules() throws {
        #expect(ShownSnapshot(costs(fetched: 0), authenticated: false, interval: 300, now: now) == nil)
        let current = try #require(ShownSnapshot(costs(fetched: 360), authenticated: true, interval: 300, now: now))
        #expect(current.figures.map(\.amount) == [Decimal(string: "412.37"), 12] && !current.late)
        #expect(current.headline?.money.id == "month")
        #expect(ShownSnapshot(costs(fetched: 361), authenticated: true, interval: 300, now: now)?.late == true)
        #expect(ShownSnapshot(costs(fetched: 600), authenticated: true, interval: 300, now: now) != nil)
        #expect(ShownSnapshot(costs(fetched: 601), authenticated: true, interval: 300, now: now) == nil)
    }

    /// The headline's period over: nothing; another figure's: that figure alone is withheld.
    @Test func anotherMonthOrDayIsNotShown() throws {
        let earlier = now - 40 * 86400
        #expect(ShownSnapshot(costs(fetched: 0, month: CostCalendar.month(earlier), day: CostCalendar.day(earlier)),
                              authenticated: true, interval: 300, now: now) == nil)
        let yesterday = costs(fetched: 60, day: CostCalendar.day(now) - 86400)
        let shown = try #require(ShownSnapshot(yesterday, authenticated: true, interval: 300, now: now))
        #expect(shown.figures.map(\.amount) == [Decimal(string: "412.37"), nil])
    }

    @Test func nextChangeIsNoLaterThanMidnightUTC() {
        let midnight = CostCalendar.add(days: 1, to: CostCalendar.day(now))
        let late = now - 30 + 360
        #expect(ShownSnapshot.nextChange(costs(fetched: 30), authenticated: true, interval: 300, now: now)
                .map { abs($0.timeIntervalSince(late)) < 0.01 } == true)
        #expect(ShownSnapshot.nextChange(costs(fetched: 30), authenticated: true, interval: 300, now: midnight - 1) == midnight)
        #expect(ShownSnapshot.nextChange(costs(fetched: 30), authenticated: false, interval: 300, now: now) == nil)
    }
}

@Suite struct ResetScheduleTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    /// Rule 2: due just after a reset the data predates, earlier than the interval would be.
    @Test func dueJustAfterAReset() {
        let reset = now + 100
        #expect(Due.next(lastAttempt: now - 10, notBefore: .distantPast, interval: 600, resets: [reset], jitter: 5, now: now)
                == reset + 5)
        // The interval comes first when it is sooner.
        #expect(Due.next(lastAttempt: now - 10, notBefore: .distantPast, interval: 60, resets: [reset], jitter: 5, now: now)
                == now + 50)
    }

    @Test func backoffStillWins() {
        let reset = now + 100
        #expect(Due.next(lastAttempt: now - 10, notBefore: now + 900, interval: 600, resets: [reset], jitter: 5, now: now)
                == now + 900)
    }

    /// Once tried after the reset (the attempt failed, so the data still predates it), only the interval counts.
    @Test func aResetIsTriedOnce() {
        let reset = now - 50
        #expect(Due.next(lastAttempt: now - 40, notBefore: .distantPast, interval: 600, resets: [reset], jitter: 5, now: now)
                == now + 560)
        #expect(Due.next(lastAttempt: now - 60, notBefore: .distantPast, interval: 600, resets: [reset], jitter: 5, now: now)
                == reset + 5)
    }

    @Test func onlyResetsTheDataPredates() {
        let usage = Usage(limits: [.session: Limit(percent: 1, resetsAt: now + 10), .weekly: Limit(percent: 1, resetsAt: now - 10),
                                   .fable: Limit(percent: 1, resetsAt: nil)], fetchedAt: now)
        #expect(usage.snapshot.resets == [now + 10])
    }

    @Test func jitterIsAFewStableSeconds() {
        let ids = (0..<200).map { "account-\($0)" }
        let values = ids.map { Due.jitter(account: $0) }
        #expect(values.allSatisfy { (2...10).contains($0) })
        #expect(Set(values).count > 100)
        #expect(ids.map { Due.jitter(account: $0) } == values)
    }
}
