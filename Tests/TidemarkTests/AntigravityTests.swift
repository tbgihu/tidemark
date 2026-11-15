import Foundation
import Testing
@testable import TidemarkCore

@Suite struct AntigravityTests {
    let now = ISO8601.date("2026-11-16T18:30:00Z")!

    static let usage = """
        {"conversation_id":"","status":"SUCCESS","response":"…","duration_seconds":0,"num_turns":0,
         "usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},
         "command":{"name":"usage","data":{"description":"…","groups":[
           {"name":"Gemini Models","description":"Models within this group: Gemini","buckets":[
             {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.25,
              "reset_time":"2026-11-23T18:29:10Z"},
             {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,
              "reset_time":"2026-11-16T23:29:10Z"}]},
           {"name":"Claude and GPT models","buckets":[
             {"id":"3p-weekly","window":"weekly","remaining_fraction":0.9,"reset_time":"2026-11-23T18:29:10Z"},
             {"id":"3p-5h","window":"5h","remaining_fraction":0,"reset_time":"2026-11-16T23:29:10Z"}]}]}}}
        """

    static func credits(_ amount: String) -> String {
        #"{"status":"SUCCESS","num_turns":0,"command":{"name":"credits","data":{"remaining_credits":\#(amount)}}}"#
    }

    func login(_ answers: [String: String], seen: Canned.Seen? = nil) -> Login {
        Antigravity.login { command throws(FetchFailure) in
            seen?.add(URLRequest(url: URL(string: "agy:\(command)")!))
            guard let answer = answers[command] else { throw .signInRequired }
            return Data(answer.utf8)
        }
    }

    func fetch(_ login: Login) async throws(FetchFailure) -> Snapshot {
        try await login.fetch(Canned.context(Canned.http(""), Credential(secret: ""), now: now))
    }

    @Test func readsEveryGroup() async throws {
        let seen = Canned.Seen()
        let snapshot = try await fetch(login(["/usage": Self.usage, "/credits": Self.credits("120")], seen: seen))
        #expect(snapshot.meters.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-weekly", "3p-5h"],
                "Gemini's two first, then the others' weekly limit: the menu bar's three rows")
        #expect(snapshot.meters.map(\.label) == ["5h(G)", "w(G)", "w(C)", "5h(C)"])
        #expect(snapshot.meters.map(\.rounded) == [0, 75, 10, 100], "used, from the fraction remaining")
        #expect(snapshot.meters.map(\.title) == ["Gemini Models · 5-hour limit", "Gemini Models · weekly limit",
                                                 "Claude and GPT models · weekly limit", "Claude and GPT models · 5-hour limit"])
        #expect(snapshot.meters.map(\.short) == [true, false, false, true])
        #expect(snapshot[meter: "gemini-weekly"]?.resetsAt == ISO8601.date("2026-11-23T18:29:10Z"))
        #expect(snapshot.money.map(\.amount) == [120] && snapshot.money.first?.currency == nil)
        #expect(seen.urls == ["agy:/usage", "agy:/credits"], "agy's own commands, nothing else")
    }

    @Test func creditsAreOptional() async throws {
        for credits in [Self.credits("0"), Self.credits("true"), "{}", nil] {
            var answers = ["/usage": Self.usage]
            answers["/credits"] = credits
            let snapshot = try await fetch(login(answers))
            #expect(snapshot.meters.count == 4 && snapshot.money.isEmpty)
        }
    }

    /// Only an answer of agy's own command counts: never one that ran the model, or failed, or answered another.
    @Test func onlyACommandsAnswerIsRead() async {
        let ran = Self.usage.replacingOccurrences(of: #""num_turns":0"#, with: #""num_turns":1"#)
        let failed = Self.usage.replacingOccurrences(of: "SUCCESS", with: "ERROR")
        let other = Self.usage.replacingOccurrences(of: #""name":"usage""#, with: #""name":"help""#)
        for body in [ran, failed, other, "Authentication required. Please visit the URL to log in:", ""] {
            await #expect(throws: FetchFailure.unreadable) { try await fetch(login(["/usage": body])) }
        }
    }

    @Test func noGroupsIsNoPlan() async throws {
        let empty = #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[]}}}"#
        let snapshot = try await fetch(login(["/usage": empty]))
        #expect(snapshot.isEmpty && snapshot.note == Snapshot.noPlan)
    }

    @Test func signedOutOrMissingNeedsTheUser() async throws {
        await #expect(throws: FetchFailure.signInRequired) { try await fetch(login([:])) }
        let identity = try await login(["/usage": Self.usage]).identify(Credential(secret: ""), Canned.http(""))
        #expect(identity == Antigravity.identity)
        #expect(Antigravity.cli.accountID(identity.id) == "antigravity-agy")
        guard case .secret(let form) = Antigravity.cli.auth else { Issue.record("not a form"); return }
        #expect(form.fields.isEmpty && form.intro.contains("agy"), "nothing to enter: the sheet explains and checks")
        #expect(form.explain(.signInRequired)?.contains("install") == true)
    }

    @Test func findsAgyWhereItsInstallerPutsIt() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agy = bin.appending(path: "agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        #expect(AgyCommand.executable(home: home)?.path == agy.path)
    }
}
