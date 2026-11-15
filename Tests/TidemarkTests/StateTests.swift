import Foundation
import Testing
@testable import TidemarkCore

@Suite struct StateTests {
    @Test func roundTrips() throws {
        let state = SavedState(accounts: [
            Account(id: "a", provider: Claude.id, login: Claude.account.id, name: "Jane", email: "jane@example.com",
                    showPercent: true,
                    snapshot: Usage(limits: [.weekly: Limit(percent: 5, resetsAt: nil)], fetchedAt: Date(timeIntervalSince1970: 9)).snapshot),
        ], fired: ["a|weekly|-|50"])
        let data = try JSONEncoder().encode(state)
        #expect(SavedState.load(data) == state)
    }

    @Test func menuBarChoices() throws {
        let json = """
        {"accounts":[{"id":"a"},{"id":"b","showBars":false},{"id":"c","showBars":false,"showPercent":true},
                     {"id":"d","showBars":"no"},{"id":"e","hiddenInMenuBar":true,"showPercent":true}]}
        """
        let state = try #require(SavedState.load(Data(json.utf8)))
        #expect(state.accounts.map(\.showBars) == [true, false, false, true, false], "bars unless saved without")
        #expect(state.accounts.allSatisfy { $0.showLabels }, "labels unless saved without")
        #expect(state.accounts[4].showPercent == false, "hidden before the two checkboxes: neither")
        #expect(state.accounts.inMenuBar.map(\.id) == ["a", "c", "d"], "in order: bars or percentages")
        #expect(SavedState.load(try JSONEncoder().encode(state)) == state)
        var reordered = Array(state.accounts.reversed())
        #expect(reordered.inMenuBar.map(\.id) == ["d", "c", "a"], "the choice moves with its account")
        for index in reordered.indices { reordered[index].showBars = false; reordered[index].showPercent = false }
        #expect(reordered.inMenuBar.isEmpty)
    }

    @Test func missingFileIsEmpty() {
        #expect(SavedState.load(nil) == SavedState())
    }

    @Test func notStateIsNil() {
        #expect(SavedState.load(Data("garbage".utf8)) == nil)
        #expect(SavedState.load(Data()) == nil)
        #expect(SavedState.load(Data("[1,2]".utf8)) == nil)
    }

    @Test func toleratesOldNewAndBrokenFields() throws {
        let json = """
        {"accounts":[
          {"id":"a","name":"Jane","email":"jane@example.com"},
          {"id":"b","name":5,"showPercent":"yes","usage":{"broken":true},"futureField":[1]},
          {"name":"no id"},
          {"id":"a","name":"Duplicate"},
          42
        ],"fired":"not a set","something":"new"}
        """
        let state = try #require(SavedState.load(Data(json.utf8)))
        #expect(state.accounts.map(\.id) == ["a", "b"])
        #expect(state.accounts[0].name == "Jane")
        #expect(state.accounts[1] == Account(id: "b", provider: Claude.id, login: Claude.account.id, name: ""))
        #expect(state.fired.isEmpty)
    }

    /// A usage response that reports nothing Tidemark shows is kept as such (no rows), unlike a body that isn't one.
    @Test func emptyUsageIsKeptAsNoLimits() throws {
        #expect(throws: (any Error).self) { try Usage.decode(Data("{}".utf8)) }
        #expect(try Usage.decode(Data(#"{"limits":[{"kind":"unknown","percent":3}]}"#.utf8)).isEmpty)
        #expect(!(try Usage.decode(Data(#"{"five_hour":{"utilization":1}}"#.utf8)).isEmpty))
        #expect(!(try Usage.decode(Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1}}"#.utf8)).isEmpty))
    }
}

@Suite struct DueTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstRefreshIsDueNow() {
        #expect(Due.next(lastAttempt: nil, notBefore: .distantPast, interval: 60, now: now) <= now)
    }

    @Test func intervalAfterLastAttempt() {
        #expect(Due.next(lastAttempt: now - 20, notBefore: .distantPast, interval: 60, now: now) == now + 40)
    }

    @Test func backoffWins() {
        #expect(Due.next(lastAttempt: now - 20, notBefore: now + 300, interval: 15, now: now) == now + 300)
        #expect(Due.next(lastAttempt: now - 20, notBefore: now + 5, interval: 60, now: now) == now + 40)
    }

    @Test func clockSetBackDoesNotStall() {
        // the last attempt appears to be a day in the future
        #expect(Due.next(lastAttempt: now + 86400, notBefore: .distantPast, interval: 60, now: now) == now + 60)
    }

    @Test func farFutureBackoffIsBounded() {
        #expect(Due.next(lastAttempt: nil, notBefore: now + 30 * 86400, interval: 60, now: now) == now + Backoff.ceiling)
    }
}
