import Foundation
import Testing
@testable import TidemarkCore

@Suite struct XAITests {
    /// Answers each path with its (status, body); anything else is a 404.
    func http(_ routes: [String: (Int, String)], seen: Canned.Seen = Canned.Seen()) -> HTTP {
        Canned.http(routes, route: { $0.url!.path.components(separatedBy: "/teams/team-1/").last ?? "" },
                    unknown: #"{"code":5,"message":"Not Found"}"#, seen: seen)
    }

    let credential = Credential(secret: "xai-token-x", fields: ["team": "team-1"])
    let now = ISO8601.date("2026-11-13T15:00:00Z")!

    static let balance = #"{"changes":[{"teamId":"team-1","changeOrigin":"PURCHASE","amount":{"val":"-1000"}}],"total":{"val":"-4550"}}"#
    static let invoice = """
    {"coreInvoice":{"lines":[],"amountBeforeVat":"1250","vatCost":"0","amountAfterVat":"1250","totalWithCorr":{"val":"5000"},
     "prepaidCredits":{"val":"-4500"},"prepaidCreditsUsed":{"val":"0"}},
     "effectiveSpendingLimit":"20000","defaultCredits":"0","billingCycle":{"year":2026,"month":11}}
    """
    static let usage = """
    {"timeSeries":[{"group":[],"groupLabels":[],"dataPoints":[
      {"timestamp":"2026-11-11T00:00:00Z","values":[1.25]},{"timestamp":"2026-11-12T00:00:00Z","values":[0]},
      {"timestamp":"2026-11-13T00:00:00Z","values":[0.75973725]}]}],"limitReached":false}
    """

    @Test func balanceIsTheNegatedLedger() throws {
        #expect(try XAI.Balance.decode(Data(Self.balance.utf8)).dollars == Decimal(string: "45.5"))
        #expect(try XAI.Balance.decode(Data(#"{"total":{"val":"250"}}"#.utf8)).dollars == -2.5, "money owed is negative")
        #expect(throws: (any Error).self, "no total is not a zero balance") { try XAI.Balance.decode(Data(#"{"changes":[]}"#.utf8)) }
        #expect(throws: (any Error).self) { try XAI.Balance.decode(Data(#"{"total":{"val":"lots"}}"#.utf8)) }
    }

    @Test func invoiceMakesTheMonthlyMeter() throws {
        let invoice = try XAI.Invoice.decode(Data(Self.invoice.utf8))
        let meter = try #require(invoice.meter)
        #expect(meter.id == "cycle" && meter.label == "mo" && meter.percent == 25)
        #expect(meter.resetsAt == ISO8601.date("2026-12-01T00:00:00Z"))

        let noLimit = try XAI.Invoice.decode(Data(#"{"coreInvoice":{"amountAfterVat":"99"},"effectiveSpendingLimit":"0"}"#.utf8))
        #expect(noLimit.meter == nil, "prepaid only: no limit to measure against")
        #expect(noLimit.money?.amount == Decimal(string: "0.99") && noLimit.money?.end == nil)

        let empty = try XAI.Invoice.decode(Data("{}".utf8))
        #expect(empty.meter == nil && empty.money == nil)
    }

    @Test func usageSumsDailyDollarsAsCents() throws {
        let range = ISO8601.date("2026-11-11T00:00:00Z")!..<ISO8601.date("2026-11-13T00:00:00Z")!
        let days = try XAI.Usage.decode(Data(Self.usage.utf8), in: range)
        #expect(days == [ISO8601.date("2026-11-11T00:00:00Z")!: 125, ISO8601.date("2026-11-12T00:00:00Z")!: 0])
        #expect(throws: (any Error).self, "a truncated answer isn't charted") {
            try XAI.Usage.decode(Data(#"{"timeSeries":[],"limitReached":true}"#.utf8), in: range)
        }
        #expect(throws: (any Error).self) {
            try XAI.Usage.decode(Data(#"{"timeSeries":[{"dataPoints":[{"timestamp":"x","values":[1]}]}]}"#.utf8), in: range)
        }
        #expect(XAI.Usage.timestamp(range.lowerBound) == "2026-11-11 00:00:00")
    }

    @Test func fetchReadsBalanceInvoiceAndCosts() async throws {
        let recorder = Canned.Seen(), costs = Canned.Costs()
        let http = http(["prepaid/balance": (200, Self.balance), "postpaid/invoice/preview": (200, Self.invoice),
                         "usage": (200, Self.usage)], seen: recorder)
        let snapshot = try await XAI.team.fetch(FetchContext(account: "xai-team-1", credential: credential, http: http,
                                                             now: now, costs: costs))
        #expect(snapshot.money.map(\.id) == ["balance"] && snapshot.headline?.amount == Decimal(string: "45.5"))
        #expect(snapshot.meters.map(\.id) == ["cycle"])
        let ledger = await costs.ledger("xai-team-1")
        #expect(ledger.cents(on: ISO8601.date("2026-11-11T00:00:00Z")!) == 125)

        let requests = recorder.requests
        #expect(requests.map { $0.url!.absoluteString } == [
            "https://management-api.x.ai/v1/billing/teams/team-1/prepaid/balance",
            "https://management-api.x.ai/v1/billing/teams/team-1/postpaid/invoice/preview",
            "https://management-api.x.ai/v1/billing/teams/team-1/usage",
        ])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer xai-token-x" })
        let usage = try #require(requests.last)
        #expect(usage.httpMethod == "POST" && usage.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: usage.httpBody ?? Data()) as? [String: Any])
        let analytics = try #require(body["analyticsRequest"] as? [String: Any])
        let time = try #require(analytics["timeRange"] as? [String: String])
        #expect(time == ["startTime": "2026-11-01 00:00:00", "endTime": "2026-11-14 00:00:00", "timezone": "Etc/GMT"])
    }

    @Test func extrasFailingKeepTheBalance() async throws {
        let http = http(["prepaid/balance": (200, Self.balance), "postpaid/invoice/preview": (403, ""), "usage": (500, "")])
        let snapshot = try await XAI.team.fetch(FetchContext(account: "a", credential: credential, http: http, now: now,
                                                             costs: Canned.Costs()))
        #expect(snapshot.money.map(\.id) == ["balance"] && snapshot.meters.isEmpty)

        let limited = self.http(["prepaid/balance": (200, Self.balance), "postpaid/invoice/preview": (429, "")])
        await #expect(throws: FetchFailure.rateLimited(nil)) {
            try await XAI.team.fetch(FetchContext(account: "a", credential: credential, http: limited, now: now, costs: Canned.Costs()))
        }
    }

    @Test func identifyChecksKeyAndTeam() async throws {
        let identity = try await XAI.team.identify(credential, http(["prepaid/balance": (200, Self.balance)]))
        #expect(identity.id == "team-1" && XAI.team.accountID(identity.id) == "xai-team-1")
        await #expect(throws: FetchFailure.server(404)) {
            try await XAI.team.identify(Credential(secret: "k", fields: ["team": "other"]), http([:]))
        }
        await #expect(throws: FetchFailure.unauthorized) {
            try await XAI.team.identify(credential, http(["prepaid/balance": (401, #"{"code":16}"#)]))
        }
        guard case .secret(let form) = XAI.team.auth else { Issue.record("a secret form"); return }
        #expect(form.validate(["key": "k", "team": "../x"]) != nil && form.validate(["key": "k", "team": "abc-123"]) == nil)
        #expect(form.credential(["key": "k", "team": "abc-123"]) == Credential(secret: "k", fields: ["team": "abc-123"]))
    }
}
