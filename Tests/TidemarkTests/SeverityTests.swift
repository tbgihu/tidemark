import Foundation
import Testing
@testable import TidemarkCore

@Suite struct SeverityTests {
    @Test(arguments: [
        (0.0, Severity.normal), (50, .normal), (75, .normal), (75.4, .warning), (76, .warning), (90, .warning),
        (95, .warning), (95.5, .critical), (99, .critical), (100, .critical), (130, .critical), (-5, .normal),
    ])
    func gradesByPercentage(_ percent: Double, _ expected: Severity) {
        #expect(Severity(percent: percent) == expected)
    }

    @Test(arguments: [
        ("normal", Severity.normal), ("warning", .warning), ("critical", .critical),
        ("WARNING", .warning), (" critical\n", .critical), ("exceeded", .critical), ("error", .critical),
        ("blocked", .critical), ("rate_limited", .critical), ("caution", .warning), ("ok", .normal),
    ])
    func readsTheServersWord(_ word: String, _ expected: Severity) {
        #expect(Severity(server: word) == expected)
    }

    @Test func unknownMissingOrEmptyWordsAreNotGrades() {
        #expect(Severity(server: nil) == nil)
        #expect(Severity(server: "") == nil)
        #expect(Severity(server: "  ") == nil)
        #expect(Severity(server: "purple") == nil)
    }

    @Test func theServersGradeWinsOverThePercentage() {
        #expect(Severity(server: "warning", percent: 40) == .warning)
        #expect(Severity(server: "normal", percent: 88) == .normal)
        #expect(Severity(server: "critical", percent: 80) == .critical)
    }

    @Test func withoutAGradeThePercentageDecides() {
        #expect(Severity(server: nil, percent: 80) == .warning)
        #expect(Severity(server: "something_new", percent: 97) == .critical)
        #expect(Severity(server: "something_new", percent: 10) == .normal)
    }

    @Test func ordersByUrgencyAndSpeaksOnlyWhenNotNormal() {
        #expect(Severity.normal < .warning && Severity.warning < .critical)
        #expect(Severity.normal.spoken == nil)
        #expect(Severity.warning.spoken == "warning")
        #expect(Severity.critical.spoken == "critical")
    }

    @Test func decodesEachLimitsGrade() throws {
        let usage = try Usage.decode(Data("""
        {"five_hour":{"utilization":48.0,"resets_at":null},"seven_day":{"utilization":81.0},
         "limits":[{"kind":"session","percent":48,"severity":"normal"},
          {"kind":"weekly_all","percent":81,"severity":"warning"},
          {"kind":"weekly_scoped","percent":100,"severity":"critical","scope":{"model":{"display_name":"Fable"}}}]}
        """.utf8))
        #expect(usage[.session]?.reportedSeverity == "normal")
        #expect(usage[.session]?.severity == .normal)
        #expect(usage[.weekly]?.severity == .warning)        // the window's percentage, the row's grade
        #expect(usage[.fable]?.severity == .critical)
    }

    @Test func fallsBackToThePercentageWithoutRowsOrGrades() throws {
        let usage = try Usage.decode(Data("""
        {"five_hour":{"utilization":97},"seven_day":{"utilization":80},
         "limits":[{"kind":"weekly_scoped","percent":20,"severity":42,"scope":{"model":{"display_name":"Fable"}}}]}
        """.utf8))
        #expect(usage[.session]?.reportedSeverity == nil)
        #expect(usage[.session]?.severity == .critical)
        #expect(usage[.weekly]?.severity == .warning)
        #expect(usage[.fable]?.reportedSeverity == nil)      // a grade of the wrong type is ignored, not fatal
        #expect(usage[.fable]?.severity == .normal)
    }

    @Test func aSnapshotWithoutGradesStillDecodes() throws {
        let old = #"{"percent":64,"resetsAt":1000}"#
        let limit = try JSONDecoder().decode(Limit.self, from: Data(old.utf8))
        #expect(limit.reportedSeverity == nil)
        #expect(limit.severity == .normal)
        let graded = Limit(percent: 64, resetsAt: nil, reportedSeverity: "warning")
        #expect(try JSONDecoder().decode(Limit.self, from: JSONEncoder().encode(graded)) == graded)
    }

    @Test func extraUsageTakesTheSpendRowsGrade() throws {
        let usage = try Usage.decode(Data("""
        {"extra_usage":{"is_enabled":true,"monthly_limit":50000,"used_credits":27140,"utilization":54,"currency":"USD"},
         "limits":[{"kind":"spend","group":"daily","percent":99,"severity":"critical","is_active":false},
                   {"kind":"spend","group":"monthly","percent":54,"severity":"warning","is_active":true}]}
        """.utf8))
        #expect(usage.extra?.reportedSeverity == "warning")
        #expect(usage.extra?.severity == .warning)                   // 54 % alone would be normal
    }

    @Test func extraUsageWithoutAGradeUsesItsShareOfTheCap() throws {
        let usage = try Usage.decode(Data("""
        {"extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":980},
         "limits":[{"kind":"spend","group":"monthly","percent":98}]}
        """.utf8))
        #expect(usage.extra?.reportedSeverity == nil)
        #expect(usage.extra?.severity == .critical)
        let monthly = try Usage.decode(Data("""
        {"extra_usage":{"is_enabled":true,"used_credits":5},
         "limits":[{"kind":"spend","group":"weekly","severity":"normal"},{"kind":"spend","group":"monthly","severity":"critical"}]}
        """.utf8))
        #expect(monthly.extra?.severity == .critical)                 // no active row: the monthly one
        let old = #"{"spentMinor":1,"decimals":2}"#
        #expect(try JSONDecoder().decode(ExtraUsage.self, from: Data(old.utf8)).reportedSeverity == nil)
    }
}
