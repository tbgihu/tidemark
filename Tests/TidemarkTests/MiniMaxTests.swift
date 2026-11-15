import Foundation
import Testing
@testable import TidemarkCore

/// MiniMax Coding Plan remains, from responses shaped as the service sends them.
@Suite struct MiniMaxTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var start: Int { 1_700_000_000_000 }

    /// `current_interval_usage_count` is what is LEFT: 15000 total with 14989 "usage" is 11 requests used, about
    /// 0.07 %, not 99.9 %. The same response read the other way would show a plan all but exhausted on a fresh window.
    @Test func usageCountIsRemaining() throws {
        let body = """
        {"base_resp":{"status_code":"0"},"data":{"current_subscribe_title":"Max","model_remains":[
          {"model_name":"MiniMax-M2","current_interval_total_count":"15000","current_interval_usage_count":"14989",
           "start_time":\(start),"end_time":\(start + 5 * 3600 * 1000),"remains_time":8941292,
           "current_weekly_total_count":100000,"current_weekly_usage_count":75000,
           "weekly_start_time":\(start - 86_400_000),"weekly_end_time":\(start + 6 * 86_400_000)}]}}
        """
        let snapshot = try MiniMaxRemains.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "weekly"] && snapshot.meters.map(\.label) == ["5h", "w"])
        #expect(abs(snapshot.meters[0].percent - 11.0 / 15000 * 100) < 1e-9, "11 of 15000 used")
        #expect(snapshot.meters[1].percent == 25, "75000 of 100000 left")
        #expect(snapshot.meters[0].resetsAt == now + 5 * 3600 && snapshot.meters[0].short && snapshot.meters[0].title == "5-hour limit")
        #expect(snapshot.meters[1].resetsAt == now + 6 * 86400 && !snapshot.meters[1].short)
        #expect(snapshot.plan == "Max")
    }

    /// Token plans: counts of 0 and the share left as a percentage; other models after the text ones; status 3 for
    /// a model the plan doesn't include.
    @Test func tokenPlanPercentages() throws {
        let body = """
        {"base_resp":{"status_code":0,"status_msg":"success"},"model_remains":[
          {"model_name":"video","current_interval_total_count":0,"current_interval_usage_count":0,
           "current_interval_remaining_percent":30,"start_time":\(start),"end_time":\(start + 86_400_000)},
          {"model_name":"general","current_interval_total_count":0,"current_interval_usage_count":0,
           "current_interval_remaining_percent":"96","start_time":\(start - 3_600_000),"end_time":\(start + 4 * 3_600_000),
           "current_weekly_total_count":0,"current_weekly_usage_count":0,"current_weekly_remaining_percent":"99%",
           "weekly_end_time":\(start + 3 * 86_400_000)},
          {"model_name":"speech-2.8","current_interval_status":3,"current_interval_remaining_percent":100,
           "current_weekly_status":3,"current_weekly_remaining_percent":100}]}
        """
        let snapshot = try MiniMaxRemains.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session", "weekly", "vid-interval"])
        #expect(snapshot.meters.map(\.label) == ["5h", "w", "vid"])
        #expect(snapshot.meters.map(\.percent) == [4, 1, 70])
        #expect(snapshot.meters[2].title == "Video · daily" && !snapshot.meters[2].short)
        #expect(snapshot.plan == nil)
    }

    @Test func mostConstrainedTextModelAndPastEnds() throws {
        let body = """
        {"model_remains":[
          {"model_name":"MiniMax-M2","current_interval_total_count":100,"current_interval_usage_count":90,"end_time":\(start - 1000),"remains_time":60000},
          {"model_name":"MiniMax-M2.5","current_interval_total_count":100,"current_interval_usage_count":40},
          {"model_name":"MiniMax-M2.7","current_interval_total_count":0,"current_interval_usage_count":0}],
         "plan_name":" Plus "}
        """
        let snapshot = try MiniMaxRemains.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters.map(\.id) == ["session"] && snapshot.meters[0].percent == 60)
        #expect(snapshot.plan == "Plus")
        let first = try MiniMaxRemains.snapshot(Data(body.replacingOccurrences(of: "40}", with: "95}").utf8), now: now)
        #expect(first.meters[0].percent == 10 && first.meters[0].resetsAt == now + 60, "a past end falls back to remains_time")
    }

    @Test func errorsInTheBody() throws {
        func failure(_ body: String) -> FetchFailure? {
            do { _ = try MiniMaxRemains.snapshot(Data(body.utf8), now: now); return nil } catch { return error }
        }
        // As probed with a bogus key: HTTP 200 and status 1004.
        #expect(failure(#"{"base_resp":{"status_code":1004,"status_msg":"login fail: Please carry the API secret key"}}"#) == .unauthorized)
        #expect(failure(#"{"base_resp":{"status_code":1002,"status_msg":"rate limit"}}"#) == .rateLimited(nil))
        #expect(failure(#"{"data":{"base_resp":{"status_code":1013}}}"#) == .server(1013))
        #expect(failure(#"{"base_resp":{"status_code":0}}"#) == .unreadable)
        #expect(failure("[]") == .unreadable)
        #expect(try MiniMaxRemains.snapshot(Data(#"{"base_resp":{"status_code":0},"model_remains":[]}"#.utf8), now: now)
            == Snapshot(note: Snapshot.noPlan, fetchedAt: now))
    }

    @Test func requestsAndKeys() async throws {
        let seen = Canned.Seen()
        let http = Canned.http(#"{"base_resp":{"status_code":0},"model_remains":[]}"#, seen: seen)
        _ = try await MiniMax.plan.fetch(Canned.context(http, Credential(secret: "sk-cp-1")))
        let identity = try await MiniMax.plan.identify(Credential(secret: "sk-cp-1", fields: ["region": "china", "name": "Lab"]), http)
        #expect(seen.urls == ["https://api.minimax.io/v1/token_plan/remains", "https://api.minimaxi.com/v1/token_plan/remains"])
        #expect(seen.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-cp-1" })
        #expect(identity == Identity(id: APIKey.fingerprint("sk-cp-1"), name: "Lab"))
        guard case .secret(let form) = MiniMax.plan.auth else { Issue.record("a key form"); return }
        #expect(form.validate(["key": "sk-api-123"])?.contains("sk-cp-") == true && form.validate(["key": "sk-cp-123"]) == nil)
    }
}
