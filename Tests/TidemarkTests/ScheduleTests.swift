import Foundation
import Testing
@testable import TidemarkCore

@Suite struct ScheduleTests {
    @Test func intervalSteps() {
        #expect(Interval.steps == [15, 30, 60, 120, 300, 600, 900, 1800, 3600])
        #expect(Interval.defaultValue == 300)
        #expect(Interval.index(of: 60) == 2)
        #expect(Interval.index(of: 1) == 0)
        #expect(Interval.index(of: 100_000) == 8)
        #expect(Interval.index(of: 500) == 5)
        #expect(Interval.steps.map(Interval.label) == ["15 s", "30 s", "1 min", "2 min", "5 min", "10 min", "15 min", "30 min", "60 min"])
    }

    @Test func storedInterval() {
        #expect(Interval.stored(nil, chosen: nil) == 300)
        #expect(Interval.stored(60, chosen: nil) == 300, "an unflagged 60 s was the old default, never a choice")
        #expect(Interval.stored(60, chosen: true) == 60)
        #expect(Interval.stored(900, chosen: nil) == 900)
        #expect(Interval.stored(15, chosen: true) == 15)
        #expect(Interval.stored(500, chosen: true) == 600)
        #expect(Interval.stored(0, chosen: true) == 300)
    }

    @Test func providersSafeInterval() {
        let usage = Claude.provider.pace(Claude.account), costs = Claude.provider.pace(Claude.console)
        #expect(usage.mayBeRateLimited(at: 120))
        #expect(!usage.mayBeRateLimited(at: 300))
        #expect(!costs.mayBeRateLimited(at: 15), "costs are never read faster than allowed")
        #expect(costs.effective(15) == 300 && usage.effective(15) == 15)
        #expect(Pace.mayBeRateLimited(at: 60, by: []), "without accounts, the default pace decides")
        #expect(!Pace.mayBeRateLimited(at: 60, by: [costs]))
        #expect(Pace.mayBeRateLimited(at: 60, by: [costs, usage]), "the strictest decides")
        #expect(!Pace.mayBeRateLimited(at: Interval.defaultValue, by: [usage, costs]))
        #expect(Claude.provider.company == "Anthropic")
    }

    @Test func brandColor() {
        let terracotta = BrandColor(hex: 0xD97757)
        #expect(terracotta.red == 217 / 255 && terracotta.green == 119 / 255 && terracotta.blue == 87 / 255)
        #expect(Claude.provider.brandColor == terracotta, "organisations and accounts share Claude's colour")
    }

    @Test func ladder() {
        #expect((1...6).map { Backoff.delay(failures: $0, retryAfter: nil) } == [60, 120, 300, 900, 900, 900])
        #expect(Backoff.delay(failures: 0, retryAfter: nil) == 60)
    }

    @Test func retryAfterWinsAndIsBounded() {
        #expect(Backoff.delay(failures: 3, retryAfter: 42) == 42)
        #expect(Backoff.delay(failures: 1, retryAfter: 0) == 1)
        #expect(Backoff.delay(failures: 1, retryAfter: 86400) == 3600)
    }

    @Test func parsesRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_445_412_480)          // Wed, 21 Oct 2015 07:28:00 GMT
        #expect(Backoff.retryAfter("120", now: now) == 120)
        #expect(Backoff.retryAfter(" 7 ", now: now) == 7)
        #expect(Backoff.retryAfter("Wed, 21 Oct 2015 07:30:00 GMT", now: now) == 120)
        #expect(Backoff.retryAfter("Wednesday, 21-Oct-15 07:29:00 GMT", now: now) == 60)
        #expect(Backoff.retryAfter("Wed Oct 21 07:28:30 2015", now: now) == 30)
        #expect(Backoff.retryAfter("Wed, 21 Oct 2015 07:00:00 GMT", now: now) == 0)
        #expect(Backoff.retryAfter("-5", now: now) == 0)
        #expect(Backoff.retryAfter("soon", now: now) == nil)
        #expect(Backoff.retryAfter("", now: now) == nil)
        #expect(Backoff.retryAfter(nil, now: now) == nil)
    }
}
