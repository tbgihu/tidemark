import Foundation
import Testing
@testable import TidemarkCore

@Suite struct WarpTests {
    let now = ISO8601.date("2026-11-13T15:00:00Z")!

    static let response = """
    {"data":{"user":{"__typename":"UserOutput","user":{
      "requestLimitInfo":{"isUnlimited":false,"nextRefreshTime":"2026-12-01T08:00:00.000Z","requestLimit":2500,
                          "requestsUsedSinceLastRefresh":"625"},
      "bonusGrants":[{"requestCreditsGranted":1000,"requestCreditsRemaining":400,"expiration":"2027-01-01T00:00:00Z"}],
      "workspaces":[{"bonusGrantsInfo":{"grants":[{"requestCreditsGranted":500,"requestCreditsRemaining":"100","expiration":null}]}},
                    {"bonusGrantsInfo":null}]}}}}
    """

    @Test func creditsMeterAndBonus() throws {
        let snapshot = try Warp.Limits.decode(Data(Self.response.utf8)).snapshot(now: now)
        let meter = try #require(snapshot.meters.first)
        #expect(meter.id == "credits" && meter.label == "mo" && meter.percent == 25)
        #expect(meter.resetsAt == ISO8601.date("2026-12-01T08:00:00Z"))
        #expect(snapshot.money.map(\.id) == ["bonus"] && snapshot.money[0].amount == 500 && snapshot.money[0].currency == nil)
        #expect(snapshot.money[0].digits == 0 && snapshot.plan == nil)
    }

    @Test func unlimitedAndSparseAnswers() throws {
        let unlimited = try Warp.Limits.decode(Data("""
            {"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":{"isUnlimited":true,"nextRefreshTime":null,
             "requestLimit":0,"requestsUsedSinceLastRefresh":12},"bonusGrants":[],"workspaces":[]}}}}
            """.utf8)).snapshot(now: now)
        #expect(unlimited.meters.isEmpty && unlimited.money.isEmpty && unlimited.plan == "Unlimited")

        let sparse = try Warp.Limits.decode(Data(#"{"data":{"user":{"user":{"requestLimitInfo":{"requestLimit":100}}}}}"#.utf8))
        #expect(sparse.snapshot(now: now).isEmpty, "nothing used reported: no bar")

        #expect(throws: (any Error).self) { try Warp.Limits.decode(Data(#"{"errors":[{"message":"bad"}],"data":null}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try Warp.Limits.decode(Data(#"{"data":{"user":{"__typename":"UserFacingError"}}}"#.utf8))
        }
    }

    @Test func requestCarriesWarpsHeadersAndQuery() async throws {
        let recorder = Canned.Seen()
        _ = try await Warp.key.fetch(FetchContext(account: "a", credential: Credential(secret: "wk-1.abc"),
                                                  http: Canned.http(Self.response, seen: recorder), now: now, costs: Canned.Costs()))
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wk-1.abc")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Warp/1.0")
        #expect(request.value(forHTTPHeaderField: "x-warp-client-id") == "warp-app")
        #expect(request.value(forHTTPHeaderField: "x-warp-os-category") == "macOS")
        #expect(request.value(forHTTPHeaderField: "x-warp-os-version") == Warp.osVersion)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["operationName"] as? String == "GetRequestLimitInfo")
        #expect((body["query"] as? String)?.contains("requestsUsedSinceLastRefresh") == true)
        let variables = body["variables"] as? [String: [String: Any]]
        #expect((variables?["requestContext"]?["osContext"] as? [String: String])?["name"] == "macOS")
    }

    @Test func identifyAndStatuses() async throws {
        let identity = try await Warp.key.identify(Credential(secret: "wk-1.abcd"), Canned.http(Self.response))
        #expect(identity.name == "Warp Key …abcd" && Warp.key.accountID(identity.id) == "warp-" + APIKey.fingerprint("wk-1.abcd"))
        await #expect(throws: FetchFailure.unauthorized) {
            try await Warp.key.identify(Credential(secret: "wk-x"), Canned.http(#"{"error":"Unauthorized: Invalid API key"}"#, status: 401))
        }
        guard case .secret(let form) = Warp.key.auth else { Issue.record("a secret form"); return }
        #expect(form.validate(["key": "sk-123"]) != nil && form.validate(["key": "wk-1.abc"]) == nil)
    }
}
