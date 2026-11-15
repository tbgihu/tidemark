import Foundation
import Testing
@testable import TidemarkCore

private func utc(_ text: String) -> Date { ISO8601.date(text)! }
private func day(_ text: String) -> Date { CostCalendar.day(key: text)! }
private func cents(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite struct CostDecodingTests {
    @Test func sumsCentStringsPerDayExactly() throws {
        let page = try CostPage.decode(Data("""
        {"data":[{"starting_at":"2026-11-01T00:00:00Z","ending_at":"2026-11-02T00:00:00Z",
                  "results":[{"amount":"123.78912","currency":"USD","cost_type":"tokens","model":"x"},
                             {"amount":"0.1","currency":"USD"},{"amount":"0.2","currency":"USD"}]},
                 {"starting_at":"2026-11-02T00:00:00Z","ending_at":"2026-11-03T00:00:00Z","results":[]}],
         "has_more":false,"next_page":null}
        """.utf8))
        #expect(page.days[day("2026-11-01")] == cents("124.08912"))   // 0.1 + 0.2 is exactly 0.3 here
        #expect(page.days[day("2026-11-02")] == 0)
        #expect(page.nextPage == nil)
    }

    @Test func readsTheCursor() throws {
        let page = try CostPage.decode(Data("""
        {"data":[],"has_more":true,"next_page":"page_MjAyNS0wNS0xNFQwMDowMDowMFo="}
        """.utf8))
        #expect(page.nextPage == "page_MjAyNS0wNS0xNFQwMDowMDowMFo=")
    }

    @Test(arguments: [
        #"{"data":[{"starting_at":"2026-11-01T00:00:00Z","results":[{"amount":"12abc","currency":"USD"}]}]}"#,
        #"{"data":[{"starting_at":"2026-11-01T00:00:00Z","results":[{"amount":"1e3","currency":"USD"}]}]}"#,
        #"{"data":[{"starting_at":"2026-11-01T00:00:00Z","results":[{"amount":12.5,"currency":"USD"}]}]}"#,
        #"{"data":[{"starting_at":"2026-11-01T00:00:00Z","results":[{"amount":"1","currency":"EUR"}]}]}"#,
        #"{"data":[{"starting_at":"yesterday","results":[]}]}"#,
        #"{"data":[],"has_more":true,"next_page":null}"#,
        #"{"error":{"type":"not_found_error"}}"#,
        "<html>",
    ])
    func refusesWhatWouldShowAWrongAmount(_ json: String) {
        #expect(throws: (any Error).self) { try CostPage.decode(Data(json.utf8)) }
    }

    @Test func parsesOnlyPlainDecimals() {
        #expect(Cents.parse("123.45") == cents("123.45"))
        #expect(Cents.parse("-0.5") == cents("-0.5"))
        #expect(Cents.parse(" 7 ") == 7)
        for bad in ["", ".5", "5.", "1.2.3", "1,5", "NaN", "--1", "1 2", "0x10"] { #expect(Cents.parse(bad) == nil, "\(bad)") }
    }

    @Test func centsRoundTripAsStrings() throws {
        let value = Cents(cents("41234.56789"))
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self) == #""41234.56789""#)
        #expect(try JSONDecoder().decode(Cents.self, from: data) == value)
    }

    @Test func decodesTheOrganisation() throws {
        let org = try Organization.decode(Data(#"{"id":"12345678-1234-5678-1234-567812345678","name":" Acme ","type":"organization"}"#.utf8))
        #expect(org == Organization(id: "12345678-1234-5678-1234-567812345678", name: "Acme"))
        #expect(Claude.console.accountID(org.id) == "org-12345678-1234-5678-1234-567812345678")
        #expect(throws: (any Error).self) { try Organization.decode(Data(#"{"id":"","name":"x"}"#.utf8)) }
        #expect(throws: (any Error).self) { try Organization.decode(Data(#"{"id":"a","type":"user"}"#.utf8)) }
        #expect(try Organization.decode(Data(#"{"id":"a"}"#.utf8)).name == "API organisation")
    }

    @Test func tellsAdminKeysFromWorkspaceKeys() {
        #expect(AdminKey.shape("sk-ant-admin01-abc") == .admin)
        #expect(AdminKey.shape("sk-ant-api03-abc") == .workspace)
        #expect(AdminKey.shape("hello") == .unknown)
        #expect(AdminKey.clean(" sk-ant-admin01-a\nb \t") == "sk-ant-admin01-ab")
    }
}

@Suite struct CostLedgerTests {
    @Test func fillsDaysTheResponseLeftOutWithZero() {
        var ledger = CostLedger()
        ledger.merge([day("2026-11-02"): 500], covering: day("2026-11-01")..<day("2026-11-04"))
        #expect(ledger.series(from: day("2026-10-30"), through: day("2026-11-05")).map(\.cents) == [0, 500, 0])
        #expect(ledger.cents(on: day("2026-11-01")) == 0)
        #expect(ledger.cents(on: day("2026-10-31")) == nil)               // not read: unknown, not zero
    }

    @Test func aRefreshReplacesItsDaysAndKeepsTheRest() {
        var ledger = CostLedger()
        ledger.merge([day("2026-10-20"): 100, day("2026-11-10"): 7], covering: day("2026-10-14")..<day("2026-11-13"))
        ledger.merge([day("2026-11-11"): 9], covering: day("2026-11-10")..<day("2026-11-13"))
        #expect(ledger.cents(on: day("2026-10-20")) == 100)
        #expect(ledger.cents(on: day("2026-11-10")) == 0)                 // re-read and now empty
        #expect(ledger.cents(on: day("2026-11-11")) == 9)
        #expect(ledger.covered == day("2026-10-14")..<day("2026-11-13"))
    }

    @Test func aGapStartsAfresh() {
        var ledger = CostLedger()
        ledger.merge([day("2026-08-02"): 100], covering: day("2026-08-01")..<day("2026-08-05"))
        ledger.merge([day("2026-11-02"): 5], covering: day("2026-11-01")..<day("2026-11-03"))
        #expect(ledger.covered == day("2026-11-01")..<day("2026-11-03"))
        #expect(ledger.cents(on: day("2026-08-02")) == nil)
    }

    @Test func monthToDateAddsUpAcrossBackfillChunks() {
        // Two backfill chunks meet on 2026-11-07, inside the month.
        let now = utc("2026-11-12T15:00:00Z")
        var ledger = CostLedger()
        ledger.merge([day("2026-11-07"): cents("100.5"), day("2026-11-12"): 40], covering: day("2026-11-07")..<day("2026-11-13"))
        ledger.merge([day("2026-10-31"): 99999, day("2026-11-01"): cents("0.25"), day("2026-11-06"): 3],
                     covering: day("2026-10-08")..<day("2026-11-07"))
        let totals = ledger.monthAndToday(at: now)
        #expect(totals?.month == cents("143.75"))                         // 0.25 + 3 + 100.5 + 40; October excluded
        #expect(totals?.today == 40)
        #expect(ledger.figures(at: now)?.first?.start == day("2026-11-01"))
    }

    @Test func noSummaryUntilTheWholeMonthIsRead() {
        let now = utc("2026-11-12T15:00:00Z")
        var ledger = CostLedger()
        ledger.merge([:], covering: day("2026-11-05")..<day("2026-11-13"))
        #expect(ledger.monthAndToday(at: now) == nil && ledger.figures(at: now) == nil)
    }

    @Test func monthsAndDaysAreUTC() throws {
        // 23:30 on 31 October in New York is already November in UTC: November's costs, as Anthropic bills.
        let now = utc("2026-11-01T03:30:00Z")
        #expect(CostCalendar.month(now) == day("2026-11-01"))
        var ledger = CostLedger()
        ledger.merge([day("2026-10-31"): 500, day("2026-11-01"): 20], covering: CostPlan.refresh(now: now))
        let figures = try #require(ledger.figures(at: now))
        #expect(figures.map(\.amount) == [Decimal(string: "0.2"), Decimal(string: "0.2")])
        #expect(figures.map(\.id) == ["month", "today"] && figures[0].headline && figures[1].partial)
        // A saved figure stops applying when the UTC month (or day) changes, whatever the local time.
        #expect(figures[0].current(at: utc("2026-11-30T23:59:00Z")))
        #expect(!figures[0].current(at: utc("2026-12-01T00:00:00Z")))
        #expect(!figures[1].current(at: utc("2026-11-02T00:00:00Z")))
    }

    @Test func refreshCoversTheSettlingDaysAcrossAMonthStart() {
        let range = CostPlan.refresh(now: utc("2026-12-01T08:00:00Z"))
        #expect(range == day("2026-11-29")..<day("2026-12-02"))
        let mid = CostPlan.refresh(now: utc("2026-12-20T08:00:00Z"))
        #expect(mid == day("2026-12-01")..<day("2026-12-21"))
        #expect(CostCalendar.days(from: mid.lowerBound, to: mid.upperBound) <= 31)
    }

    @Test func backfillChunksStopAtAYear() {
        let now = utc("2026-11-12T15:00:00Z")
        var ledger = CostLedger()
        ledger.merge([:], covering: CostPlan.refresh(now: now))
        let chunks = CostPlan.backfill(ledger, from: .distantPast, now: now)
        #expect(chunks.first?.upperBound == day("2026-11-01"))
        #expect(chunks.allSatisfy { CostCalendar.days(from: $0.lowerBound, to: $0.upperBound) <= CostPlan.chunkDays })
        #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.lowerBound == $1.upperBound })   // no gaps
        #expect(chunks.last?.lowerBound == CostCalendar.add(days: -365, to: day("2026-11-13")))
        #expect(CostPlan.backfill(ledger, from: day("2026-11-03"), now: now).isEmpty)
    }

    @Test func persistsAsSmallJSON() throws {
        var ledger = CostLedger()
        ledger.merge([day("2026-11-02"): cents("1234.5")], covering: day("2026-11-01")..<day("2026-11-04"))
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(CostLedger.self, from: data) == ledger)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""2026-11-02":"1234.5""#))
        #expect(try JSONDecoder().decode(CostLedger.self, from: Data(#"{"from":"x"}"#.utf8)).covered == nil)
    }

    @Test func prunesOldDays() {
        var ledger = CostLedger()
        ledger.merge([day("2025-01-02"): 1, day("2026-01-02"): 2], covering: day("2025-01-01")..<day("2026-01-05"))
        ledger.prune(before: day("2026-01-01"))
        #expect(ledger.covered == day("2026-01-01")..<day("2026-01-05"))
        #expect(ledger.cents(on: day("2026-01-02")) == 2)
    }
}

@Suite struct OrganizationStateTests {
    @Test func organisationsRoundTripInState() throws {
        let money = CostLedger.figures(month: cents("41234.5"), today: 1200, monthStart: day("2026-11-01"), day: day("2026-11-12"))
        let state = SavedState(accounts: [
            Account(id: "a", provider: Claude.id, login: Claude.account.id, name: "Jane", email: "jane@example.com"),
            Account(id: "org-1", provider: Claude.id, login: Claude.console.id, name: "Acme", historyExpanded: true,
                    snapshot: Snapshot(money: money, fetchedAt: utc("2026-11-12T15:00:00Z"))),
        ])
        let loaded = try #require(SavedState.load(try JSONEncoder().encode(state)))
        #expect(loaded == state)
        #expect(loaded.accounts[1].snapshot?.headline?.amount == cents("412.345"))
    }

    @Test func organisationsAreReadAtMostEveryFiveMinutes() {
        let pace = Claude.provider.pace(Claude.console)
        #expect(pace.effective(15) == 300)
        #expect(pace.effective(900) == 900)
        #expect(Claude.provider.pace(Claude.account).effective(15) == 15)
    }
}

@Suite struct MoneyFormatTests {
    let us = Locale(identifier: "en_US")

    @Test func panelShowsCents() {
        #expect(Format.money(cents: cents("41237.4"), locale: us) == "$412.37")
        #expect(Format.money(cents: 0, locale: us) == "$0.00")
        #expect(Format.money(cents: 12_345_678, locale: us) == "$123,456.78")
        #expect(Format.money(cents: -500, locale: us) == "-$5.00")
    }

    /// Always "$", never "US$", "$US" or a trailing symbol: only grouping and the decimal separator are the locale's.
    @Test(arguments: [("en_US", "$123,456.78"), ("en_CA", "$123,456.78"), ("en_AU", "$123,456.78"),
                      ("de_DE", "$123.456,78"), ("nl_NL", "$123.456,78"), ("fr_FR", "$123\u{202F}456,78"),
                      ("fr_CA", "$123\u{A0}456,78"), ("en_IN", "$1,23,456.78"), ("ja_JP", "$123,456.78")])
    func theSymbolIsAlwaysTheDollar(_ identifier: String, _ expected: String) {
        let text = Format.money(cents: 12_345_678, locale: Locale(identifier: identifier))
        #expect(text == expected)
        #expect(!text.contains("US") && text.filter { $0 == "$" }.count == 1 && text.hasPrefix("$"))
    }

    @Test func menuBarIsCompactAndNeverRoundsUp() {
        #expect(Format.compactMoney(cents: cents("437.9"), locale: us) == "$4.37")
        #expect(Format.compactMoney(cents: cents("41299"), locale: us) == "$412")
        #expect(Format.compactMoney(cents: 0, locale: us) == "$0.00")
        #expect(Format.compactMoney(cents: 1_234_567, locale: us) == "$12.3K")
        #expect(Format.compactMoney(cents: cents("41299"), locale: Locale(identifier: "de_DE")) == "$412")
        #expect(Format.compactMoney(cents: cents("437.9"), locale: Locale(identifier: "de_DE")) == "$4,37")
        #expect(Format.compactMoney(cents: 412_300, locale: Locale(identifier: "en_CA")) == "$4,123")
        #expect(Format.compactMoney(cents: 1_234_567, locale: Locale(identifier: "en_CA")) == "$12.3K")
        #expect(Format.compactMoney(Decimal(string: "8.409")!, currency: "USD", locale: us) == "$8.40")
        #expect(Format.compactMoney(42, currency: "EUR", locale: us) == "€42")
        #expect(Format.compactMoney(42, currency: nil, locale: us) == "42")
    }

    @Test func saysWhenTheUTCMonthBeganLocally() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let text = Format.since(day("2026-11-01"), day: false, locale: Locale(identifier: "en_GB"), timeZone: berlin)
        #expect(text.hasPrefix("since 1 Nov") && text.contains("1:00"))      // 00:00 UTC is 01:00 in Berlin
    }
}
