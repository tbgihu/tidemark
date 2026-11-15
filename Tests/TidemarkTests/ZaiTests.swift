import Foundation
import Testing
@testable import TidemarkCore

/// z.ai's GLM Coding Plan quota, from responses shaped as the service sends them.
@Suite struct ZaiTests {
    let now = Date(timeIntervalSince1970: 1_794_560_000)            // 2026-11-13T08:53:20Z
    var ms: (TimeInterval) -> Int { { Int((now.timeIntervalSince1970 + $0) * 1000) } }

    @Test func windowsAndMCP() throws {
        let body = """
        {"code":200,"msg":"Operation successful","success":true,"data":{"planName":"Pro","limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":120,"remaining":880,"percentage":12,
           "nextResetTime":\(ms(20 * 86400)),"usageDetails":[{"modelCode":"search-prime","usage":100}]},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":41,"nextResetTime":\(ms(3 * 86400))},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":"800","currentValue":"200","percentage":30,"nextResetTime":\(ms(7200))},
          {"type":"SOMETHING_NEW","unit":9,"number":1,"percentage":99}
        ]}}
        """
        let snapshot = try ZaiQuota.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "weekly", "mcp"])
        #expect(snapshot.meters.map(\.label) == ["5h", "w", "mcp"])
        #expect(snapshot.meters.map(\.percent) == [25, 41, 12], "counts win over the rounded percentage")
        #expect(snapshot.meters[0].short && !snapshot.meters[1].short)
        #expect(snapshot.meters[0].resetsAt == now + 7200 && snapshot.meters[1].resetsAt == now + 3 * 86400)
        #expect(snapshot.meters[2].title == "MCP calls · monthly")
        #expect(snapshot.plan == "Pro")
    }

    @Test func implausibleResetsAndOddEntries() throws {
        let body = """
        {"code":200,"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":5,"nextResetTime":\(ms(10 * 3600))},
          {"type":"TOKENS_LIMIT","unit":1,"number":1,"percentage":"7","nextResetTime":\(Int(now.timeIntervalSince1970) + 3600)},
          {"type":"TOKENS_LIMIT","unit":42,"number":1,"percentage":8},
          {"type":"TOKENS_LIMIT","unit":3,"number":5},
          {"unit":3},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":0,"percentage":0}
        ],"plan_type":"Lite"}}
        """
        let snapshot = try ZaiQuota.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "daily", "tokens", "mcp"])
        #expect(snapshot.meters[0].resetsAt == nil, "a 5-hour reset 10 hours away is wrong")
        #expect(snapshot.meters[1].resetsAt == now + 3600 && snapshot.meters[1].label == "day", "seconds read as seconds")
        #expect(snapshot.plan == "Lite")
    }

    @Test func errorsInTheBody() throws {
        func failure(_ body: String) -> FetchFailure? {
            do { _ = try ZaiQuota.snapshot(Data(body.utf8), now: now); return nil } catch { return error }
        }
        // As probed with a bogus key: HTTP 200, the status in the body.
        #expect(failure(#"{"code":401,"msg":"token expired or incorrect","success":false}"#) == .unauthorized)
        #expect(failure(#"{"code":1302,"msg":"High concurrency","success":false}"#) == .rateLimited(nil))
        #expect(failure(#"{"code":503,"success":false}"#) == .server(503))
        #expect(failure(#"{"success":false}"#) == .unreadable)
        #expect(failure("<html>") == .unreadable)
        #expect(failure(#"{"code":200,"success":true,"data":{}}"#) == .unreadable)
        let none = try ZaiQuota.snapshot(Data(#"{"code":500,"msg":"当前用户不存在coding plan","success":false}"#.utf8), now: now)
        #expect(none == Snapshot(note: Snapshot.noPlan, fetchedAt: now))
        #expect(try ZaiQuota.snapshot(Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8), now: now).note == Snapshot.noPlan)
    }

    @Test func requestsTheRegionsHost() async throws {
        let seen = Canned.Seen()
        let http = Canned.http(#"{"code":200,"success":true,"data":{"limits":[]}}"#, seen: seen)
        _ = try await Zai.plan.fetch(Canned.context(http, Credential(secret: "k1")))
        let identity = try await Zai.plan.identify(Credential(secret: "k1", fields: ["region": "china"]), http)
        #expect(seen.urls == ["https://api.z.ai/api/monitor/usage/quota/limit", "https://open.bigmodel.cn/api/monitor/usage/quota/limit"])
        #expect(seen.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer k1" })
        #expect(identity == Identity(id: APIKey.fingerprint("k1"), name: "GLM Coding Plan"))
        await #expect(throws: FetchFailure.unauthorized) {
            try await Zai.plan.identify(Credential(secret: "bad"), Canned.http(#"{"code":401,"success":false}"#))
        }
        await #expect(throws: FetchFailure.rateLimited(12)) {
            try await Zai.plan.fetch(Canned.context(Canned.http("", status: 429, headers: ["Retry-After": "12"]), Credential(secret: "k")))
        }
    }
}
