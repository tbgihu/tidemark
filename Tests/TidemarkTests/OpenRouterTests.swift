import Foundation
import Testing
@testable import TidemarkCore

@Suite struct OpenRouterTests {
    let now = ISO8601.date("2026-11-13T15:00:00Z")!   // a Friday

    static let key = """
    {"data":{"label":"sk-or-v1-au7...890","limit":100,"limit_remaining":74.5,"limit_reset":"monthly",
     "usage":125.5,"usage_daily":1.25,"usage_weekly":"8.5","usage_monthly":25.5,"byok_usage":0,"is_free_tier":false,
     "is_management_key":false,"include_byok_in_limit":false,"rate_limit":{"requests":-1,"interval":"10s"},
     "budgets":[{"budget_id":null,"guardrail_id":"g","limit_usd":50,"remaining_usd":17.5,"reset_interval":"weekly",
                 "resets_at":"2026-11-16T00:00:00.000Z","scope":"member","spend_usd":32.5},
                {"limit_usd":100,"remaining_usd":74.5,"reset_interval":"monthly","resets_at":"2026-12-01T00:00:00Z","scope":"key"}],
     "expires_at":null,"future_field":{"x":1}}}
    """

    @Test func keyLimitIsAMeterAndUsageIsMoney() throws {
        let snapshot = try OpenRouter.Key.decode(Data(Self.key.utf8)).snapshot(now: now)
        let meter = try #require(snapshot.meters.first)
        #expect(snapshot.meters.count == 1 && meter.id == "limit" && meter.label == "mo" && meter.percent == 25.5)
        #expect(meter.resetsAt == ISO8601.date("2026-12-01T00:00:00Z"))
        #expect(snapshot.money.map(\.id) == ["month", "week", "today"])
        #expect(snapshot.money.map(\.amount) == [Decimal(string: "25.5"), Decimal(string: "8.5"), Decimal(string: "1.25")])
        #expect(snapshot.headline?.id == "month")
        #expect(snapshot.money[1].start == ISO8601.date("2026-11-09T00:00:00Z"), "the UTC week starts on Monday")
        #expect(snapshot.money[1].end == ISO8601.date("2026-11-16T00:00:00Z"))
    }

    @Test func limitsWithoutResetOrBudgets() throws {
        let daily = try OpenRouter.Key.decode(Data(#"{"data":{"limit":"10","limit_reset":"daily","usage_daily":2.5}}"#.utf8))
        let meter = try #require(daily.snapshot(now: now).meters.first)
        #expect(meter.label == "day" && meter.percent == 25 && meter.resetsAt == ISO8601.date("2026-11-14T00:00:00Z"))

        let lifetime = try OpenRouter.Key.decode(Data(#"{"data":{"limit":20,"limit_remaining":5,"limit_reset":null}}"#.utf8))
        #expect(lifetime.snapshot(now: now).meters.first?.percent == 75)
        #expect(lifetime.snapshot(now: now).meters.first?.resetsAt == nil)

        let unlimited = try OpenRouter.Key.decode(Data(#"{"data":{"label":"","limit":null,"usage":3,"is_free_tier":true}}"#.utf8))
        #expect(unlimited.snapshot(now: now).meters.isEmpty && unlimited.label == nil)
        #expect(unlimited.snapshot(now: now).plan == "Free")
        #expect(throws: (any Error).self) { try OpenRouter.Key.decode(Data(#"{"error":{"code":401}}"#.utf8)) }
    }

    @Test func managementKeyAddsTheBalance() async throws {
        let recorder = Canned.Seen()
        let credential = Credential(secret: "sk-or-v1-key", fields: ["management": "sk-or-v1-mgmt"])
        let http = Canned.http(["key": (200, Self.key), "credits": (200, #"{"data":{"total_credits":100.5,"total_usage":25.75}}"#)], seen: recorder)
        let snapshot = try await OpenRouter.key.fetch(FetchContext(account: "a", credential: credential, http: http, now: now,
                                                                   costs: Canned.Costs()))
        #expect(snapshot.money.first?.id == "balance" && snapshot.money.first?.amount == Decimal(string: "74.75"))
        #expect(snapshot.headline?.id == "balance" && snapshot.money.filter(\.headline).count == 1)
        #expect(recorder.requests.map { $0.url!.absoluteString } == ["https://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/credits"])
        #expect(recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer sk-or-v1-key", "Bearer sk-or-v1-mgmt"])

        let refused = Canned.http(["key": (200, Self.key), "credits": (403, "")])
        let without = try await OpenRouter.key.fetch(FetchContext(account: "a", credential: credential, http: refused, now: now,
                                                                  costs: Canned.Costs()))
        #expect(without.money.map(\.id) == ["month", "week", "today"], "a refused management key hides only the balance")
    }

    @Test func identifyNamesTheKey() async throws {
        let identity = try await OpenRouter.key.identify(Credential(secret: "sk-or-v1-key"), Canned.http(["key": (200, Self.key)]))
        #expect(identity.name == "sk-or-v1-au7...890" && identity.id == APIKey.fingerprint("sk-or-v1-key"))
        #expect(identity.id.count == 16 && !identity.id.contains("sk-or"))
        await #expect(throws: FetchFailure.unauthorized) {
            try await OpenRouter.key.identify(Credential(secret: "k", fields: ["management": "m"]),
                                              Canned.http(["key": (200, Self.key), "credits": (401, "")]))
        }
        guard case .secret(let form) = OpenRouter.key.auth else { Issue.record("a secret form"); return }
        #expect(form.credential(["key": "a", "management": "b"]) == Credential(secret: "a", fields: ["management": "b"]))
        #expect(form.credential(["key": "a", "management": ""]) == Credential(secret: "a"))
    }
}
