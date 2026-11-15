import Foundation
import Testing
@testable import TidemarkCore

@Suite struct FormatTests {
    let now = Date(timeIntervalSince1970: 1_788_000_000)        // Sat 2026-08-29 10:40 UTC
    let utc = TimeZone(identifier: "UTC")!
    let gb = Locale(identifier: "en_GB")

    @Test func resetWithinADayCountsDown() {
        #expect(Format.reset(now + 2 * 3600 + 13 * 60, now: now) == "Resets in 2 hr 13 min")
        #expect(Format.reset(now + 2 * 3600 + 12 * 60 + 1, now: now) == "Resets in 2 hr 13 min")
        #expect(Format.reset(now + 3 * 3600, now: now) == "Resets in 3 hr")
        #expect(Format.reset(now + 13 * 60, now: now) == "Resets in 13 min")
        #expect(Format.reset(now + 20, now: now) == "Resets in less than 1 min")
        #expect(Format.reset(now - 5, now: now) == nil)            // passed: its value is withheld, never "Resets now"
        #expect(Format.reset(now, now: now) == nil)
        #expect(Format.reset(nil, now: now) == nil)
    }

    @Test func resetLaterShowsWeekdayAndTime() {
        let monday = Date(timeIntervalSince1970: 1_788_210_000)       // Mon 2026-08-31 21:00 UTC
        #expect(Format.reset(monday, now: now, locale: gb, timeZone: utc) == "Resets Mon 21:00")
        let us = Format.reset(monday, now: now, locale: Locale(identifier: "en_US"), timeZone: utc) ?? ""
        #expect(us.hasPrefix("Resets Mon") && us.contains("9:00") && us.contains("PM"))
    }

    @Test func retryingRoundsUpToTheMinute() {
        #expect(Format.retrying(at: now + 32 * 60, now: now, locale: gb, timeZone: utc) == "retrying at 11:12")
        #expect(Format.retrying(at: now + 31 * 60 + 1, now: now, locale: gb, timeZone: utc) == "retrying at 11:12")
        #expect(Format.retrying(at: now + 14 * 3600, now: now, locale: gb, timeZone: utc) == "retrying Sun 00:40")
    }

    @Test func failureSaysWhenItIsRetried() {
        let updated = now - 4 * 60
        #expect(Format.failure("Rate-limited by Anthropic.", retry: now + 32 * 60, updated: updated, now: now,
                               locale: gb, timeZone: utc) == "Rate-limited by Anthropic · retrying at 11:12 · Updated 4 min ago")
        #expect(Format.failure("Offline.", retry: now - 1, updated: nil, now: now, locale: gb, timeZone: utc) == "Offline")
        #expect(Format.failure("Offline.", retry: nil, updated: updated, now: now) == "Offline · Updated 4 min ago")
    }

    @Test func resetPassedSaysWhen() {
        #expect(Format.resetPassed(now - 60, now: now, locale: gb, timeZone: utc) == "Reset at 10:39")
        #expect(Format.resetPassed(now - 86400, now: now, locale: gb, timeZone: utc) == "Reset Fri 10:40")
    }

    /// Every amount goes through one formatter, in its own currency: USD is always a plain "$" (as organisation
    /// costs), any other currency as the locale writes it.
    @Test(arguments: [("de_CH", "$14.50"), ("en_CA", "$14.50"), ("en_US", "$14.50"), ("de_DE", "$14,50"),
                      ("fr_FR", "$14,50"), ("en_AU", "$14.50")])
    func dollarsArePlainEverywhere(_ identifier: String, _ expected: String) {
        let locale = Locale(identifier: identifier)
        #expect(Format.money(Decimal(string: "14.5")!, currency: "USD", digits: 2, locale: locale) == expected)
        #expect(Format.money(Decimal(string: "14.5")!, currency: "usd", digits: 2, locale: locale) == expected)
        #expect(Format.money(cents: 1450, locale: locale) == expected)
        let extra = ExtraUsage(spentMinor: 1450, limitMinor: 3000, currency: "USD", decimals: 2)
        #expect(extra.format(extra.spent, locale: locale) == expected)
    }

    @Test func otherCurrenciesKeepTheirOwnSymbol() {
        let ie = Locale(identifier: "en_IE")
        #expect(Format.money(Decimal(string: "12.4")!, currency: "EUR", digits: 2, locale: ie) == "€12.40")
        let de = Format.money(Decimal(string: "12.4")!, currency: "EUR", digits: 2, locale: Locale(identifier: "de_DE"))
        #expect(de.contains("12,40") && de.contains("€") && !de.contains("$"))
        let gbp = Format.money(Decimal(string: "3")!, currency: "GBP", digits: 2, locale: gb)
        #expect(gbp == "£3.00")
        let jpy = Format.money(500, currency: "JPY", digits: 0, locale: Locale(identifier: "ja_JP"))
        #expect(jpy.contains("500") && !jpy.contains("$") && !jpy.contains("."))
        #expect(Format.money(Decimal(string: "7.5")!, currency: nil, digits: 2, locale: gb) == "7.50")
        #expect(Format.money(Decimal(string: "7.5")!, currency: " ", digits: 2, locale: gb) == "7.50")
        #expect(Format.money(-5, currency: "USD", digits: 2, locale: Locale(identifier: "en_US")) == "-$5.00")
    }

    @Test func weekdayTimeIn24HourLocale() {
        let date = Date(timeIntervalSince1970: 1_789_160_400)          // Fri 2026-09-11 21:00 UTC
        #expect(Format.weekdayTime(date, locale: gb, timeZone: utc) == "Fri 21:00")
    }

    @Test func updated() {
        #expect(Format.updated(now - 10, now: now) == "Updated just now")
        #expect(Format.updated(now - 4 * 60 - 5, now: now) == "Updated 4 min ago")
        #expect(Format.updated(now - 2 * 3600, now: now) == "Updated 2 hr ago")
        #expect(Format.updated(now + 30, now: now) == "Updated just now")
        #expect(Format.updated(now - 3 * 86400, now: now, locale: gb, timeZone: utc).hasPrefix("Updated "))
    }
}
