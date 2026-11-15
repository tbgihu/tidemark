import Foundation
import Testing
@testable import TidemarkCore

@Suite struct UsageTests {
    private func decode(_ json: String) throws -> Usage { try Usage.decode(Data(json.utf8)) }

    @Test func labels() {
        #expect(LimitKind.allCases.map(\.menuBarLabel) == ["5h", "w(A)", "w(F)"])
        #expect(LimitKind.allCases.map(\.title) == ["Current session", "Weekly · All models", "Weekly · Fable"])
    }

    @Test func decodesTheDocumentedResponse() throws {
        let usage = try decode("""
        {"five_hour":{"utilization":48.0,"resets_at":"2026-09-05T12:59:59.966454+00:00"},
         "seven_day":{"utilization":64.0,"resets_at":"2026-09-11T20:59:59.966479+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,
         "limits":[{"kind":"session","group":"session","percent":48,"severity":"normal","resets_at":"2026-09-05T12:59:59.966454+00:00","scope":null,"is_active":true},
          {"kind":"weekly_all","group":"weekly","percent":64,"resets_at":"2026-09-11T20:59:59.966479+00:00","scope":null},
          {"kind":"weekly_scoped","percent":75,"severity":"warning","resets_at":"2026-09-11T20:59:59Z","scope":{"model":{"display_name":"Fable"}}}],
         "nimbus_quill":{}, "tangelo":null}
        """)
        #expect(usage[.session]?.percent == 48)
        #expect(usage[.weekly]?.percent == 64)
        #expect(usage[.fable]?.percent == 75)
        let reset = try #require(usage[.session]?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_788_613_199.966) < 0.01)
        #expect(usage[.fable]?.resetsAt == Date(timeIntervalSince1970: 1_789_160_399))
        #expect(usage.extra == nil)
    }

    @Test func fallsBackToLimitsArray() throws {
        let usage = try decode("""
        {"five_hour":null,"limits":[{"kind":"session","percent":12.5,"resets_at":null},
          {"kind":"weekly_all","percent":3}]}
        """)
        #expect(usage[.session] == Limit(percent: 12.5, resetsAt: nil))
        #expect(usage[.weekly]?.percent == 3)
        #expect(usage[.fable] == nil)
    }

    @Test func fableDetectionIsCaseInsensitiveAndSkipsOtherModels() throws {
        let usage = try decode("""
        {"limits":[{"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Sonnet"}}},
                   {"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":"FABLE"}}}]}
        """)
        #expect(usage[.fable]?.percent == 20)
        let none = try decode(#"{"limits":[{"kind":"weekly_scoped","percent":10,"scope":{"model":{"display_name":"Sonnet"}}}]}"#)
        #expect(none[.fable] == nil)
    }

    @Test func toleratesUnknownKeysKindsAndWrongTypes() throws {
        let usage = try decode("""
        {"five_hour":{"utilization":"lots","resets_at":5},"seven_day":{"utilization":1},
         "limits":[{"kind":"brand_new","percent":99},42,null,{"kind":"weekly_scoped","percent":"x","scope":{"model":{"display_name":"Fable"}}},
                   {"kind":"session","percent":7,"resets_at":"not a date"}],
         "future":{"anything":[1,2,3]}}
        """)
        #expect(usage[.session] == Limit(percent: 7, resetsAt: nil))
        #expect(usage[.weekly] == Limit(percent: 1, resetsAt: nil))
        #expect(usage[.fable] == nil)
    }

    @Test func aRecognisedResponseWithoutLimitsHasNone() throws {
        #expect(try decode(#"{"limits":"nope"}"#).isEmpty)
        #expect(try decode(#"{"five_hour":null,"seven_day":null,"limits":[],"extra_usage":null}"#).isEmpty)
    }

    /// Not a usage response at all (an error body, say): the last good values stay.
    @Test func anUnrecognisedObjectThrows() {
        #expect(throws: (any Error).self) { try decode("{}") }
        #expect(throws: (any Error).self) { try decode(#"{"error":{"type":"overloaded_error"}}"#) }
        #expect(throws: (any Error).self) { try decode("[]") }
    }

    @Test func notJSONThrows() {
        #expect(throws: (any Error).self) { try decode("<html>") }
    }

    @Test func clampsAndRounds() {
        #expect(Limit(percent: 104, resetsAt: nil).rounded == 100)
        #expect(Limit(percent: -3, resetsAt: nil).rounded == 0)
        #expect(Limit(percent: 47.5, resetsAt: nil).rounded == 48)
    }

    @Test(arguments: [
        "2026-09-05T12:59:59.966454+00:00", "2026-09-05T12:59:59.966+00:00", "2026-09-05T12:59:59+00:00",
        "2026-09-05T12:59:59Z", "2026-09-05T14:59:59.966454+02:00", "2026-09-05T12:59:59.9Z",
    ])
    func parsesTimestamps(_ string: String) throws {
        let date = try #require(ISO8601.date(string))
        #expect(abs(date.timeIntervalSince1970 - 1_788_613_199.5) <= 0.5)
    }

    @Test func rejectsBadTimestamps() {
        #expect(ISO8601.date("") == nil)
        #expect(ISO8601.date("yesterday") == nil)
    }

    @Test func snapshotRoundTrips() throws {
        let usage = Usage(limits: [.weekly: Limit(percent: 64, resetsAt: Date(timeIntervalSince1970: 1000))],
                          extra: ExtraUsage(spentMinor: 1240, limitMinor: 5000, currency: "EUR", decimals: 2),
                          fetchedAt: Date(timeIntervalSince1970: 500))
        let data = try JSONEncoder().encode(usage)
        #expect(try JSONDecoder().decode(Usage.self, from: data) == usage)
    }
}

@Suite struct ExtraUsageTests {
    private func decode(_ extra: String) throws -> ExtraUsage? {
        try Usage.decode(Data(#"{"five_hour":null,"extra_usage":\#(extra)}"#.utf8)).extra
    }

    @Test func enabledWithMonthlyLimit() throws {
        let extra = try #require(try decode("""
        {"is_enabled":true,"monthly_limit":5000,"used_credits":1240.0,"utilization":24.8,"currency":"EUR",
         "decimal_places":2,"disabled_reason":null,"daily":null,"something_new":{"a":1}}
        """))
        #expect(extra.spent == Decimal(string: "12.4"))
        #expect(extra.limit == 50)
        #expect(extra.fraction == 0.248)
        let locale = Locale(identifier: "en_IE")
        #expect(extra.format(extra.spent, locale: locale) == "€12.40")
        #expect(extra.format(50, locale: locale) == "€50.00")
    }

    @Test func enabledWithoutLimit() throws {
        let extra = try #require(try decode(#"{"is_enabled":true,"monthly_limit":null,"used_credits":2981,"currency":"USD"}"#))
        #expect(extra.limit == nil)
        #expect(extra.fraction == nil)
        #expect(extra.format(extra.spent, locale: Locale(identifier: "en_US")) == "$29.81")
    }

    @Test func zeroLimitMeansNoCapAndOverspendClamps() throws {
        #expect(try decode(#"{"is_enabled":true,"monthly_limit":0,"used_credits":0}"#)?.limit == nil)
        #expect(try decode(#"{"is_enabled":true,"monthly_limit":1000,"used_credits":2000}"#)?.fraction == 1)
    }

    @Test func zeroDecimalCurrency() throws {
        let extra = try #require(try decode(#"{"is_enabled":true,"used_credits":500,"currency":"JPY","decimal_places":0}"#))
        #expect(extra.spent == 500)
        #expect(extra.format(extra.spent, locale: Locale(identifier: "ja_JP")).contains("500"))
    }

    @Test func hiddenWhenDisabledMissingOrMalformed() throws {
        #expect(try decode(#"{"is_enabled":false,"monthly_limit":1000,"used_credits":500}"#) == nil)
        #expect(try decode(#"{"is_enabled":true,"monthly_limit":1000}"#) == nil)
        #expect(try decode("null") == nil)
        #expect(try decode(#""on""#) == nil)
        #expect(try decode(#"{"is_enabled":"yes","used_credits":5}"#) == nil)
        #expect(try Usage.decode(Data(#"{"extra_usage":null}"#.utf8)).extra == nil)
    }
}

/// Only the limits an account currently reports are shown: no row, no empty bar, no "0%" for one it lacks.
@Suite struct LimitVisibilityTests {
    private func decode(_ json: String) throws -> Usage { try Usage.decode(Data(json.utf8)) }
    private func kinds(_ json: String) throws -> [LimitKind] { try decode(json).reported.map(\.kind) }

    @Test func aPlanWithoutAFiveHourWindow() throws {
        #expect(try kinds(#"{"seven_day":{"utilization":20},"limits":[{"kind":"weekly_all","percent":20}]}"#) == [.weekly])
        #expect(try kinds(#"{"five_hour":null,"seven_day":{"utilization":20}}"#) == [.weekly])
    }

    @Test func aNullUtilizationIsNotAZero() throws {
        #expect(try kinds(#"{"five_hour":{"utilization":null,"resets_at":null},"seven_day":{"utilization":0}}"#) == [.weekly])
        #expect(try kinds(#"{"limits":[{"kind":"session","percent":null},{"kind":"weekly_all","percent":0}]}"#) == [.weekly])
        #expect(try decode(#"{"seven_day":{"utilization":0}}"#)[.weekly]?.percent == 0, "a reported 0% is still a limit")
    }

    @Test func noFableRowWithoutAFableScopedLimit() throws {
        #expect(try kinds(#"{"five_hour":{"utilization":5},"seven_day":{"utilization":6}}"#) == [.session, .weekly])
        #expect(try kinds(#"{"limits":[{"kind":"weekly_scoped","percent":30,"scope":{"model":{"display_name":"Opus"}}}]}"#)
                .isEmpty)
        #expect(try kinds(#"{"limits":[{"kind":"weekly_scoped","percent":30,"scope":null}]}"#).isEmpty)
        #expect(try kinds(#"{"limits":[{"kind":"weekly_scoped","percent":null,"scope":{"model":{"display_name":"Fable"}}}]}"#)
                .isEmpty)
    }

    @Test(arguments: [
        #"{"five_hour":{"utilization":1},"extra_usage":null}"#,
        #"{"five_hour":{"utilization":1},"extra_usage":{"is_enabled":false,"used_credits":500,"monthly_limit":1000}}"#,
        #"{"five_hour":{"utilization":1},"extra_usage":{"is_enabled":true,"used_credits":null}}"#,
        #"{"five_hour":{"utilization":1}}"#,
    ])
    func extraUsageIsHiddenUnlessEnabledAndReported(_ json: String) throws {
        #expect(try decode(json).extra == nil)
    }

    /// A field dropped or renamed later: the limit is gone from the fresh response, so from everything built on it.
    @Test func aLimitThatDisappearsIsGone() throws {
        let before = try decode("""
            {"five_hour":{"utilization":10},"seven_day":{"utilization":20},
             "limits":[{"kind":"weekly_scoped","percent":30,"scope":{"model":{"display_name":"Fable"}}}],
             "extra_usage":{"is_enabled":true,"used_credits":100}}
            """)
        #expect(before.reported.map(\.kind) == [.session, .weekly, .fable] && before.extra != nil)
        let after = try decode(#"{"five_hour_v2":{"utilization":10},"seven_day":{"utilization":21},"limits":[]}"#)
        #expect(after.reported.map(\.kind) == [.weekly])
        #expect(after.extra == nil)
        // History records only what was reported: a missing limit is "not reported", not 0.
        let sample = History.Sample(after.snapshot, charted: Claude.account.history.charted)
        #expect(sample.values == [nil, 21, nil])
        // Notifications only for reported limits.
        var fired = Set<String>()
        let high = try decode(#"{"seven_day":{"utilization":95}}"#)
        #expect(Alerts.evaluate(account: "a", snapshot: high.snapshot, fired: &fired).map(\.meter) == ["weekly"])
    }

    @Test func anAccountWithNoLimitsRecordsNoHistory() throws {
        let none = try decode(#"{"five_hour":null,"seven_day":null}"#)
        #expect(none.isEmpty && none.reported.isEmpty)
        #expect(none.snapshot.isEmpty)
        #expect(!History.shouldAppend(History.Sample(none.snapshot, charted: Claude.account.history.charted), after: nil))
    }

    @Test func aSavedSnapshotKeepsOnlyWhatWasReported() throws {
        let usage = try decode(#"{"seven_day":{"utilization":20}}"#)
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(usage.snapshot))
        #expect(restored.meters.map(\.id) == ["weekly"] && restored == usage.snapshot)
    }
}
