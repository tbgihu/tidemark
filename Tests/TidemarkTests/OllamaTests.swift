import Foundation
import Testing
@testable import TidemarkCore

/// Ollama Cloud balances, from responses shaped as the service sends them.
@Suite struct OllamaTests {
    let now = ISO8601.date("2026-11-13T10:00:00Z")!

    @Test func currentPlan() throws {
        let body = """
        {"included":{"balance_usd":"52.50","allowance_usd":60,"period":{"from":"2026-11-01T00:00:00Z","until":"2026-12-01T00:00:00Z"}},
         "purchased":{"balance_usd":"10.25"}}
        """
        let snapshot = try OllamaBalance.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["monthly"] && snapshot.meters[0].label == "mo")
        #expect(snapshot.meters[0].percent == 12.5 && snapshot.meters[0].resetsAt == ISO8601.date("2026-12-01T00:00:00Z"))
        #expect(snapshot.money == [Money(id: "purchased", title: "Purchased credits", role: .balance,
                                         amount: Decimal(string: "10.25")!, currency: "USD", headline: true)])
        #expect(snapshot.plan == nil)
    }

    @Test func legacyPlanWins() throws {
        let body = """
        {"included":{"session":{"remaining_percent":"80","resets_at":"2026-11-13T12:00:00Z"},
                     "weekly":{"remaining_percent":35.5,"resets_at":"2026-11-17T00:00:00.123Z"},
                     "allowance_usd":60,"balance_usd":0},"plan":"pro"}
        """
        let snapshot = try OllamaBalance.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "weekly"] && snapshot.meters.map(\.label) == ["ses", "w"])
        #expect(snapshot.meters.map(\.percent) == [20, 64.5] && snapshot.meters[0].short)
        #expect(snapshot.meters[1].resetsAt == ISO8601.date("2026-11-17T00:00:00.123Z"))
        #expect(snapshot.money.isEmpty && snapshot.plan == "Pro")
    }

    @Test func edgeCases() throws {
        // Purchased credits only: the balance is the headline, no meter from a zero allowance.
        let purchased = try OllamaBalance.snapshot(Data(#"{"included":{"allowance_usd":0,"balance_usd":0},"purchased":{"balance_usd":3}}"#.utf8), now: now)
        #expect(purchased.meters.isEmpty && purchased.headline?.amount == 3)
        // Out-of-range percentages hide the meter, not the response.
        let odd = try OllamaBalance.snapshot(Data(#"{"included":{"session":{"remaining_percent":140}},"purchased":null}"#.utf8), now: now)
        #expect(odd.isEmpty)
        #expect(try OllamaBalance.snapshot(Data(#"{"included":null,"purchased":null}"#.utf8), now: now).note == Snapshot.noPlan)
        #expect(throws: FetchFailure.unreadable) { try OllamaBalance.snapshot(Data(#"{"error":"x"}"#.utf8), now: now) }
    }

    @Test func requestsAndFailures() async throws {
        let seen = Canned.Seen()
        let http = Canned.http(#"{"purchased":{"balance_usd":1}}"#, seen: seen)
        _ = try await Ollama.cloud.fetch(Canned.context(http, Credential(secret: "ok-1")))
        #expect(try await Ollama.cloud.identify(Credential(secret: "ok-1"), http) == Identity(id: APIKey.fingerprint("ok-1"), name: "Ollama Cloud"))
        #expect(seen.urls == Array(repeating: "https://ollama.com/api/balance", count: 2))
        #expect(seen.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer ok-1" })
        // As probed with a bogus key.
        await #expect(throws: FetchFailure.unauthorized) {
            try await Ollama.cloud.fetch(Canned.context(Canned.http(#"{"error":"invalid credentials"}"#, status: 401), Credential(secret: "x")))
        }
        await #expect(throws: FetchFailure.rateLimited(6)) {
            try await Ollama.cloud.fetch(Canned.context(Canned.http("", status: 429, headers: ["Retry-After": "6"]), Credential(secret: "x")))
        }
        #expect(Ollama.cloud.minimumInterval >= 60 && Ollama.provider.recommendedMinimumInterval >= 60, "10 requests a minute")
    }
}
