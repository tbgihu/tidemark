import Foundation
import Testing
@testable import TidemarkCore

/// Kimi Code limits and Moonshot API balances, from responses shaped as the services send them.
@Suite struct MoonshotTests {
    let now = ISO8601.date("2026-11-13T10:00:00Z")!

    func context(_ http: HTTP, _ credential: Credential) -> FetchContext { Canned.context(http, credential, now: now) }

    // MARK: Kimi Code

    /// The documented count-based shape: weekly requests in `usage`, the 5-hour window in `limits[]`.
    @Test func kimiCodeCounts() throws {
        let body = """
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-11-16T15:23:13.716839300Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-11-13T13:33:02.717479433Z"}}],
         "user":{"membership":{"level":"LEVEL_BASIC"}}}
        """
        let snapshot = try KimiCode.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "weekly"] && snapshot.meters.map(\.label) == ["5h", "w"])
        #expect(snapshot.meters[0].percent == 69.5 && snapshot.meters[0].short)
        #expect(abs(snapshot.meters[1].percent - 214.0 / 2048 * 100) < 1e-9 && !snapshot.meters[1].short)
        #expect(abs(snapshot.meters[0].resetsAt!.timeIntervalSince(ISO8601.date("2026-11-13T13:33:02Z")!) - 0.717) < 0.001)
        #expect(snapshot.plan == "Moderato")
    }

    /// The newer ratio pools, with a monthly pool; counts for the same window and reset win when they say more.
    @Test func kimiCodeRatioPools() throws {
        let body = """
        {"usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"2026-11-13T13:00:00Z"},
                   "limit_7d":{"used_ratio":0.1,"reset_time":"2026-11-16T00:00:00Z"},
                   "limit_month_total":{"used_ratio":1.4,"reset_time":"2026-12-01T00:00:00Z"},
                   "limit_month_code":{"used_ratio":"bad"}},
         "usage":{"limit":100,"used":30,"resetTime":"2026-11-16T00:00:01Z"},
         "limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"200","remaining":"190","resetTime":"2026-11-13T13:00:00Z"}}],
         "user":{"membership":{"level":"LEVEL_ULTRA_MAX"}},"version":"GOODS_VERSION_V1"}
        """
        let snapshot = try KimiCode.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "weekly", "monthly"])
        #expect(snapshot.meters.map(\.label) == ["5h", "w", "mo"])
        #expect(snapshot.meters[0].percent == 25, "the ratio wins over fewer counted requests")
        #expect(snapshot.meters[1].percent == 30, "counts for the same reset that say more win")
        #expect(snapshot.meters[2].percent == 100, "a ratio above 1 is full, not more")
        #expect(snapshot.plan == "Ultra Max", "an unknown level is shown as sent")
    }

    @Test func kimiCodeWithoutLimits() throws {
        #expect(try KimiCode.snapshot(Data(#"{"usage":null,"limits":[],"user":{"membership":{"level":"LEVEL_UNSPECIFIED"}}}"#.utf8), now: now)
            == Snapshot(note: Snapshot.noPlan, fetchedAt: now))
        #expect(throws: FetchFailure.unreadable) { try KimiCode.snapshot(Data(#"{"error":"x"}"#.utf8), now: now) }
        #expect(throws: FetchFailure.unreadable) { try KimiCode.snapshot(Data("[]".utf8), now: now) }
        // Counts that make no sense hide the meter, never the response.
        let odd = try KimiCode.snapshot(Data(#"{"usage":{"limit":"0","used":"5"},"limits":[{"window":{},"detail":{"limit":"x"}}]}"#.utf8), now: now)
        #expect(odd.meters.isEmpty)
    }

    @Test func kimiCodeRequestsTheRegionsHost() async throws {
        let seen = Canned.Seen()
        let http = Canned.http(#"{"usage":{"limit":"10","used":"1"}}"#, seen: seen)
        _ = try await Moonshot.code.fetch(context(http, Credential(secret: "sk-kimi-x", fields: ["region": "international"])))
        _ = try await Moonshot.code.fetch(context(http, Credential(secret: "sk-kimi-x", fields: ["region": "china"])))
        _ = try await Moonshot.code.fetch(context(http, Credential(secret: "sk-kimi-x")))
        #expect(seen.requests.map { $0.url!.absoluteString } == ["https://api.kimi.ai/coding/v1/usages",
                                                                 "https://api.kimi.com/coding/v1/usages",
                                                                 "https://api.kimi.ai/coding/v1/usages"])
        #expect(seen.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-kimi-x" && $0.httpMethod == "GET" })

        let identity = try await Moonshot.code.identify(Credential(secret: "sk-kimi-x", fields: ["name": " Work "]), http)
        #expect(identity.name == "Work" && identity.id == APIKey.fingerprint("sk-kimi-x") && !identity.id.contains("kimi"))
        #expect(try await Moonshot.code.identify(Credential(secret: "sk-kimi-x"), http).name == "Kimi Code")
        #expect(Moonshot.code.accountID(identity.id) == "kimi-code-" + identity.id)
    }

    @Test func kimiCodeFailures() async {
        let key = Credential(secret: "k")
        await #expect(throws: FetchFailure.unauthorized) {
            try await Moonshot.code.fetch(context(Canned.http(#"{"error":{"type":"invalid_authentication_error"}}"#, status: 401), key))
        }
        await #expect(throws: FetchFailure.rateLimited(60)) {
            try await Moonshot.code.fetch(context(Canned.http("", status: 429, headers: ["Retry-After": "60"]), key))
        }
        await #expect(throws: FetchFailure.unauthorized) { try await Moonshot.code.identify(key, Canned.http("", status: 401)) }
    }

    // MARK: Moonshot API

    @Test func balanceInTheRegionsCurrency() async throws {
        let body = #"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}"#
        let seen = Canned.Seen()
        let international = try await Moonshot.api.fetch(context(Canned.http(body, seen: seen), Credential(secret: "sk-1")))
        #expect(international.headline == Money(id: "balance", title: "Available balance", role: .balance,
                                                amount: Decimal(string: "49.58894")!, currency: "USD", headline: true))
        #expect(international.money.map(\.id) == ["balance", "vouchers"] && international.meters.isEmpty)

        let china = try await Moonshot.api.fetch(context(Canned.http(body, seen: seen), Credential(secret: "sk-1", fields: ["region": "china"])))
        #expect(china.headline?.currency == "CNY")
        #expect(seen.requests.map { $0.url!.absoluteString } == ["https://api.moonshot.ai/v1/users/me/balance",
                                                                 "https://api.moonshot.cn/v1/users/me/balance"])
        #expect(seen.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1" })
    }

    @Test func balanceOwedAndOddShapes() throws {
        let owed = try MoonshotBalance.snapshot(Data(#"{"data":{"available_balance":"-1.5","voucher_balance":"0","cash_balance":"-1.5"}}"#.utf8),
                                                currency: "USD", now: now)
        #expect(owed.headline?.amount == Decimal(string: "-1.5") && owed.money.map(\.id) == ["balance", "owed"])
        #expect(owed.money.last?.amount == Decimal(string: "1.5"))
        let derived = try MoonshotBalance.snapshot(Data(#"{"data":{"cash_balance":2,"voucher_balance":1}}"#.utf8), currency: "CNY", now: now)
        #expect(derived.headline?.amount == 3)
        #expect(throws: FetchFailure.unreadable) { try MoonshotBalance.snapshot(Data(#"{"data":{}}"#.utf8), currency: "USD", now: now) }
        #expect(throws: FetchFailure.unreadable) { try MoonshotBalance.snapshot(Data("nope".utf8), currency: "USD", now: now) }
    }

    @Test func descriptor() {
        #expect(Registry.provider(Moonshot.id)?.logins.map(\.id) == ["code", "api"])
        #expect(Moonshot.api.minimumInterval == 900 && !Moonshot.api.reportsMeters && Moonshot.code.reportsMeters)
        guard case .secret(let form) = Moonshot.code.auth else { Issue.record("a key form"); return }
        #expect(form.fields.map(\.id) == ["key", "region", "name"])
        #expect(form.credential(["key": "sk", "region": "china", "name": ""]) == Credential(secret: "sk", fields: ["region": "china"]))
    }
}
