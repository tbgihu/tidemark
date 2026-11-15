import Foundation
import Testing
@testable import TidemarkCore

@Suite struct OpenCodeTests {
    let now = ISO8601.date("2026-11-13T12:00:00Z")!

    func fetch(_ http: HTTP, secret: String = "sk-go") async throws(FetchFailure) -> Snapshot {
        try await OpenCode.apiKey.fetch(Canned.context(http, Credential(secret: secret), now: now))
    }

    @Test func readsEveryWindow() async throws {
        let recorder = Canned.Seen()
        let snapshot = try await fetch(Canned.http("""
            {"usage":{"rolling":{"percent":12.5,"resetsAt":"2026-11-13T14:00:00.000Z"},
                      "weekly":{"percent":"8","resetsAt":1795392000},
                      "monthly":{"percent":0,"resetInSec":86400}}}
            """, seen: recorder))
        #expect(snapshot.meters.map(\.id) == ["rolling", "weekly", "monthly"])
        #expect(snapshot.meters.map(\.label) == ["5h", "w", "mo"])
        #expect(snapshot.meters.map(\.percent) == [12.5, 8, 0], "percent units, 0.5 means half a percent")
        #expect(snapshot.meters.map(\.resetsAt) == [ISO8601.date("2026-11-13T14:00:00Z"),
                                                    Date(timeIntervalSince1970: 1_795_392_000), now + 86400])
        #expect(snapshot.meters.map(\.short) == [true, false, false])
        #expect(snapshot.plan == "Go")
        let request = try #require(recorder.requests.first { $0.url?.path == "/zen/go/v1/usage" })
        #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/usage" && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-go")
        #expect(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-go" },
                "every read uses the key, and only the key")
        #expect(snapshot.money.isEmpty, "a Console answer that isn't billing shows no credits")
    }

    /// The Console's routes for the credits, by path, beside the Go usage.
    func routes(go: (Int, String), billing: (Int, String), spend: (Int, String)) -> HTTP {
        Canned.http(["/zen/go/v1/usage": go, "/console/api/billing/status": billing, "/console/api/usage/summary": spend],
                    route: { $0.url!.path })
    }

    let prepaid = #"{"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":"1234567890"}"#

    @Test func creditsBesideGo() async throws {
        let snapshot = try await fetch(routes(
            go: (200, #"{"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"2026-11-13T14:00:00.000Z"}}}"#),
            billing: (200, prepaid), spend: (200, #"{"totalCostMicroCents":"523000000"}"#)))
        #expect(snapshot.meters.map(\.id) == ["rolling"] && snapshot.plan == "Go" && snapshot.note == nil)
        #expect(snapshot.money.map(\.id) == ["balance", "spend"])
        #expect(snapshot.money.map(\.amount) == [Decimal(string: "12.3456789")!, Decimal(string: "5.23")!])
        #expect(snapshot.money[0].role == .balance && snapshot.money.allSatisfy { $0.currency == "USD" && !$0.headline },
                "with Go limits to draw, no figure takes the menu bar")
    }

    @Test func creditsWithoutGo() async throws {
        let snapshot = try await fetch(routes(
            go: (403, #"{"type":"error","error":{"type":"ForbiddenError","message":"No subscription"}}"#),
            billing: (200, prepaid), spend: (200, #"{"totalCostMicroCents":0}"#)))
        #expect(snapshot.meters.isEmpty && snapshot.plan == nil && snapshot.note == nil, "credits alone are a plan")
        #expect(snapshot.money.first { $0.headline }?.id == "balance", "the balance is the menu bar's figure")
        #expect(snapshot.money.map(\.amount) == [Decimal(string: "12.3456789")!, 0])
    }

    /// Credits only add: a Console that refuses the key, bills by invoice or answers nonsense shows none, and never
    /// fails the account.
    @Test func creditsAreOptional() async throws {
        for (billing, spend) in [((401, #"{"_tag":"Unauthorized"}"#), (401, "")),
                                 ((200, #"{"billingMode":"seat","mode":"invoiceable","balanceMicroCents":"5"}"#), (500, "")),
                                 ((200, #"{"billingMode":"prepaid","mode":"pay-as-you-go","balanceMicroCents":"12x"}"#),
                                  (200, #"{"totalCostMicroCents":true}"#))] {
            let snapshot = try await fetch(routes(go: (200, #"{"usage":{"weekly":{"percent":3}}}"#), billing: billing, spend: spend))
            #expect(snapshot.meters.map(\.id) == ["weekly"] && snapshot.money.isEmpty)
        }
        let nothing = try await fetch(routes(go: (403, #"{"error":{"type":"ForbiddenError","message":"no"}}"#),
                                             billing: (401, ""), spend: (401, "")))
        #expect(nothing.isEmpty && nothing.note == Snapshot.noPlan, "neither Go nor credits: no active plan")
        await #expect(throws: FetchFailure.unauthorized, "a key OpenCode rejects is still rejected") {
            try await fetch(routes(go: (401, #"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#),
                                   billing: (200, prepaid), spend: (200, "{}")))
        }
    }

    @Test func missingWindowsAreHidden() throws {
        let snapshot = try OpenCodeUsage.snapshot(Data("""
            {"usage":{"rolling":{"usagePercent":40,"resetsAt":1795392000000},"weekly":null,"monthly":{"resetsAt":"x"}}}
            """.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["rolling"])
        #expect(snapshot[meter: "rolling"]?.resetsAt == Date(timeIntervalSince1970: 1_795_392_000), "epoch milliseconds")
    }

    /// A key OpenCode accepts, without a Go subscription: however that is said, a clean "No active plan".
    @Test func keyWithoutGoIsNoActivePlan() async throws {
        for body in [#"{"usage":null}"#, "{}", #"{"usage":{}}"#, #"{"usage":{"rolling":null,"weekly":null,"monthly":null}}"#] {
            let snapshot = try await fetch(Canned.http(body))
            #expect(snapshot.isEmpty && snapshot.note == "No active plan" && snapshot.plan == nil, "\(body)")
        }
        for status in [402, 403, 404] {
            let snapshot = try await fetch(Canned.http(#"{"type":"error","error":{"type":"NotFoundError","message":"No subscription found"}}"#,
                                                       status: status))
            #expect(snapshot.isEmpty && snapshot.note == Snapshot.noPlan)
        }
        let bare = try await fetch(Canned.http("", status: 403))
        #expect(bare.isEmpty && bare.note == Snapshot.noPlan, "OpenCode's own client reads any 403 as a workspace without Go")
    }

    /// The shape OpenCode's own client reads: a window it is holding back shows full.
    @Test func rateLimitedWindowIsFull() throws {
        let snapshot = try OpenCodeUsage.snapshot(Data("""
            {"usage":{"rolling":{"status":"rate-limited","percent":99.6,"resetsAt":"2026-11-13T14:00:00.000Z"},
                      "weekly":{"status":"ok","percent":41,"resetsAt":"2026-11-16T00:00:00.000Z"},
                      "monthly":{"status":"ok","percent":20,"resetsAt":"2026-12-01T00:00:00.000Z"}}}
            """.utf8), now: now)
        #expect(snapshot.meters.map(\.percent) == [100, 41, 20])
    }

    @Test func statusesMapToFailures() async {
        await #expect(throws: FetchFailure.unauthorized) {
            try await fetch(Canned.http(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#, status: 401))
        }
        await #expect(throws: FetchFailure.forbidden) {
            try await fetch(Canned.http(#"{"error":{"type":"authentication_error","message":"Invalid credential"}}"#, status: 403))
        }
        await #expect(throws: FetchFailure.server(404), "an empty 404: the endpoint itself is gone") { try await fetch(Canned.http("", status: 404)) }
        await #expect(throws: FetchFailure.rateLimited(120)) { try await fetch(Canned.http("", status: 429, headers: ["Retry-After": "120"])) }
        await #expect(throws: FetchFailure.unreadable) { try await fetch(Canned.http("<html></html>")) }
        await #expect(throws: FetchFailure.unreadable) { try await fetch(Canned.http("[1]")) }
    }

    @Test func identityNeverHoldsTheKey() async throws {
        let named = try await OpenCode.apiKey.identify(Credential(secret: "sk-secret-1234", fields: ["name": " Work "]),
                                                       Canned.http(#"{"usage":null}"#))
        #expect(named.name == "Work" && named.email.isEmpty)
        #expect(named.id.count == 16 && !named.id.contains("1234"))
        let plain = try await OpenCode.apiKey.identify(Credential(secret: "sk-secret-1234"), Canned.http(#"{"usage":null}"#))
        #expect(plain == Identity(id: named.id, name: "OpenCode"), "the same key is the same account")
        #expect(APIKey.fingerprint("sk-other") != plain.id)
        #expect(OpenCode.apiKey.accountID(plain.id) == "opencode-" + plain.id)
        await #expect(throws: FetchFailure.unauthorized) {
            try await OpenCode.apiKey.identify(Credential(secret: "bad"), Canned.http("", status: 401))
        }
    }

    @Test func formMakesTheCredential() {
        guard case .secret(let form) = OpenCode.apiKey.auth else { Issue.record("not a key form"); return }
        #expect(form.credential(["key": "sk-a", "name": "Personal"]) == Credential(secret: "sk-a", fields: ["name": "Personal"]))
        #expect(form.credential(["key": "sk-a", "name": ""]) == Credential(secret: "sk-a"))
    }
}
