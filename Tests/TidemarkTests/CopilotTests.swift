import Foundation
import Testing
@testable import TidemarkCore

@Suite struct CopilotTests {
    let now = ISO8601.date("2026-11-13T12:00:00Z")!

    func snapshot(_ json: String) throws -> Snapshot { try CopilotUsage.snapshot(Data(json.utf8), now: now) }

    func context(_ http: HTTP) -> FetchContext {
        Canned.context(http, Credential(secret: "ghu_x"), now: now)
    }

    /// A Pro account: premium requests limited, chat and completions unlimited.
    let pro = """
    {"login":"octocat","access_type_sku":"monthly_subscriber_quota","copilot_plan":"individual","chat_enabled":true,
     "assigned_date":"2025-03-01T10:00:00Z","quota_reset_date":"2026-12-01","quota_reset_date_utc":"2026-12-01T00:00:00.000Z",
     "quota_snapshots":{
       "chat":{"entitlement":0,"remaining":0,"percent_remaining":100.0,"unlimited":true,"overage_count":0,"overage_permitted":false,"quota_id":"chat"},
       "completions":{"entitlement":0,"remaining":0,"percent_remaining":100.0,"unlimited":true,"overage_count":0,"overage_permitted":false,"quota_id":"completions"},
       "premium_interactions":{"entitlement":300,"remaining":111,"quota_remaining":111.0,"percent_remaining":37.0,"unlimited":false,"overage_count":0,"overage_permitted":true,"quota_id":"premium_interactions"}}}
    """

    @Test func proShowsPremiumRequestsOnly() throws {
        let snapshot = try snapshot(pro)
        #expect(snapshot.meters.map(\.id) == ["premium"])
        let premium = try #require(snapshot[meter: "premium"])
        #expect(premium.percent == 63 && premium.label == "mo" && premium.title == "Premium requests")
        #expect(premium.resetsAt == ISO8601.date("2026-12-01T00:00:00Z"))
        #expect(snapshot.plan == "Pro")
    }

    @Test func everyLimitedQuotaIsAMeter() throws {
        let snapshot = try snapshot("""
            {"copilot_plan":"individual_pro","quota_reset_date":"2026-12-01T00:00:00Z","quota_snapshots":{
              "premium_interactions":{"entitlement":"1500","remaining":"-30","percent_remaining":"-2","overage_permitted":true},
              "chat":{"entitlement":50,"remaining":10},
              "completions":{"entitlement":2000,"remaining":1500,"percent_remaining":null},
              "mystery":{"percent_remaining":10}}}
            """)
        #expect(snapshot.meters.map(\.id) == ["premium", "chat", "completions"])
        #expect(snapshot.meters.map(\.percent) == [102, 80, 25], "strings, derived shares and overage")
        #expect(snapshot.meters.map(\.label) == ["mo", "chat", "code"])
        #expect(snapshot.plan == "Pro+")
    }

    @Test func freePlanReadsItsAllowance() throws {
        let snapshot = try snapshot("""
            {"copilot_plan":"free","access_type_sku":"free_limited_copilot","limited_user_reset_date":"2026-11-28",
             "monthly_quotas":{"chat":50,"completions":2000},"limited_user_quotas":{"chat":40,"completions":500}}
            """)
        #expect(snapshot.meters.map(\.id) == ["chat", "completions"])
        #expect(snapshot.meters.map(\.percent) == [20, 75])
        #expect(snapshot[meter: "chat"]?.resetsAt == ISO8601.date("2026-11-28T00:00:00Z"))
        #expect(snapshot.plan == "Free")
    }

    @Test func noActivePlan() async throws {
        let ended = try snapshot(#"{"copilot_plan":"individual","access_type_sku":"subscription_ended","quota_snapshots":{}}"#)
        #expect(ended.isEmpty && ended.note == Snapshot.noPlan && ended.plan == nil)
        let missing = try await Copilot.account.fetch(context(Canned.http(#"{"message":"Not Found"}"#, status: 404)))
        #expect(missing.isEmpty && missing.note == "No active plan")
    }

    @Test func placeholdersAndUnknownsAreHidden() throws {
        let business = try snapshot("""
            {"copilot_plan":"business","token_based_billing":true,"quota_reset_date":"","quota_snapshots":{
              "premium_interactions":{"entitlement":0,"remaining":0,"percent_remaining":100,"credits_used":31},
              "chat":{"unlimited":true},"completions":null}}
            """)
        #expect(business.isEmpty && business.plan == "Business")
        #expect(throws: (any Error).self) { try snapshot("{}") }
        #expect(throws: (any Error).self) { try snapshot("[]") }
        #expect(CopilotUsage.plan("copilot_for_teachers") == "Copilot For Teachers")
    }

    @Test func fetchSendsTheTokenHonestly() async throws {
        let recorder = Canned.Seen()
        _ = try await Copilot.account.fetch(context(Canned.http(pro, seen: recorder)))
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token ghu_x")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Editor-Version") == nil)
    }

    @Test func statusesMapToFailures() async {
        await #expect(throws: FetchFailure.unauthorized) { try await Copilot.account.fetch(context(Canned.http("", status: 401))) }
        await #expect(throws: FetchFailure.forbidden) { try await Copilot.account.fetch(context(Canned.http("", status: 403))) }
        await #expect(throws: FetchFailure.rateLimited(60)) {
            try await Copilot.account.fetch(context(Canned.http("", status: 403, headers: ["Retry-After": "60"])))
        }
        let reset = String(Int(Date().timeIntervalSince1970) + 600)
        do {
            _ = try await Copilot.account.fetch(context(Canned.http("", status: 403, headers: ["x-ratelimit-remaining": "0",
                                                                                               "x-ratelimit-reset": reset])))
            Issue.record("expected a rate limit")
        } catch {
            guard case .rateLimited(let after?) = error else { Issue.record("got \(error)"); return }
            #expect((590...600).contains(after))
        }
        await #expect(throws: FetchFailure.server(500)) { try await Copilot.account.fetch(context(Canned.http("", status: 500))) }
    }

    @Test func identityFromUser() async throws {
        let recorder = Canned.Seen()
        let identity = try await Copilot.account.identify(
            Credential(secret: "ghu_x"),
            Canned.http(#"{"login":"octocat","id":583231,"name":"The Octocat","email":null}"#, seen: recorder))
        #expect(identity == Identity(id: "583231", name: "The Octocat", email: "octocat"))
        #expect(Copilot.account.accountID(identity.id) == "github-583231")
        #expect(recorder.requests.first?.url?.absoluteString == "https://api.github.com/user")
        #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_x")
        let bare = try GitHubUser.decode(Data(#"{"login":"jd","id":7,"name":" ","email":"jd@example.com"}"#.utf8))
        #expect(bare == Identity(id: "7", name: "jd", email: "jd@example.com"))
    }

    // MARK: Device flow

    @Test func deviceFlowStartsWithTheAppsClientID() async throws {
        let recorder = Canned.Seen()
        guard case .deviceCode(let flow) = Copilot.account.auth else { Issue.record("not a device flow"); return }
        let code = try await flow.start(Canned.http(
            #"{"device_code":"dc","user_code":"3B2F-3FB0","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}"#,
            seen: recorder))
        #expect(code.userCode == "3B2F-3FB0" && code.interval == 5)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code" && request.httpMethod == "POST")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "client_id=Ov23liMerDW15JXKO3eD&scope=read%3Auser")
        #expect(Copilot.clientID == Copilot.defaultClientID)
    }

    /// GitHub answers a poll with 200 and an `error` until the code is approved.
    @Test func pollsReadErrorsSentWith200() throws {
        func poll(_ body: String, status: Int = 200) throws(FetchFailure) -> DevicePoll {
            try GitHubDevice.poll(status: status, body: Data(body.utf8), now: now)
        }
        #expect(try poll(#"{"error":"authorization_pending","error_description":"…"}"#) == .pending)
        #expect(try poll(#"{"error":"slow_down","interval":10}"#) == .slowDown)
        #expect(try poll(#"{"error":"access_denied"}"#) == .denied)
        #expect(try poll(#"{"error":"expired_token"}"#) == .expired)
        #expect(throws: FetchFailure.server(200)) { try poll(#"{"error":"incorrect_device_code"}"#) }
        #expect(throws: FetchFailure.unreadable) { try poll("<html>") }
        #expect(try poll(#"{"error":"authorization_pending"}"#, status: 400) == .pending)

        let approved = try poll("""
            {"access_token":"ghu_a","expires_in":28800,"refresh_token":"ghr_r","refresh_token_expires_in":15897600,"scope":"","token_type":"bearer"}
            """)
        #expect(approved == .approved(Credential(secret: "ghu_a", refresh: "ghr_r", expiresAt: now + 28800)))
        let lasting = try poll(#"{"access_token":"gho_a","scope":"read:user","token_type":"bearer"}"#)
        #expect(lasting == .approved(Credential(secret: "gho_a")), "an app without expiring tokens: never refreshed")
    }

    @Test func refreshRotatesTheTokenWithoutASecret() async throws {
        let recorder = Canned.Seen()
        guard case .deviceCode(let flow) = Copilot.account.auth, let refresh = flow.refresh else {
            Issue.record("no refresh"); return
        }
        let fresh = try await refresh(Credential(secret: "ghu_old", refresh: "ghr_old", expiresAt: now),
                                      Canned.http(#"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new"}"#, seen: recorder))
        #expect(fresh.secret == "ghu_new" && fresh.refresh == "ghr_new")
        let body = String(decoding: recorder.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=Ov23liMerDW15JXKO3eD&grant_type=refresh_token&refresh_token=ghr_old")
        #expect(!body.contains("secret"))

        await #expect(throws: FetchFailure.signInRequired) {
            try await refresh(Credential(secret: "a", refresh: "r"), Canned.http(#"{"error":"bad_refresh_token"}"#))
        }
        await #expect(throws: FetchFailure.signInRequired) {
            try await refresh(Credential(secret: "a", refresh: "r"), Canned.http(#"{"error":"incorrect_client_credentials"}"#))
        }
        await #expect(throws: FetchFailure.server(502)) { try await refresh(Credential(secret: "a", refresh: "r"), Canned.http("", status: 502)) }
        await #expect(throws: FetchFailure.signInRequired) { try await refresh(Credential(secret: "a"), Canned.http("")) }
    }
}
