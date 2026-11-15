import Foundation
import Testing
@testable import TidemarkCore

/// A JWT with `claims` as its payload (unsigned: Tidemark never checks the signature).
private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    return "eyJhbGciOiJSUzI1NiJ9." + OAuth.base64URL(payload) + ".c2lnbmF0dXJl"
}

private let idToken = jwt([
    "sub": "auth0|abc", "email": "jane@example.com", "name": "Jane Doe",
    "https://api.openai.com/auth": ["chatgpt_account_id": "acc-123", "chatgpt_user_id": "user-9",
                                    "chatgpt_plan_type": "go"],
])

private func body(_ request: URLRequest) -> [String: String] {
    guard let data = request.httpBody else { return [:] }
    if request.value(forHTTPHeaderField: "Content-Type") == "application/json" {
        return (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
    }
    let items = URLComponents(string: "?" + String(decoding: data, as: UTF8.self))?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

@Suite struct ChatGPTUsageTests {
    let now = Date(timeIntervalSince1970: 1_763_000_000)

    @Test func plusWithTwoWindowsCreditsAndAModelLimit() throws {
        let snapshot = try OpenAI.usage(Data("""
            {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
              "primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1763003600},
              "secondary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_after_seconds":86400,"reset_at":1763086400}},
             "credits":{"has_credits":true,"unlimited":false,"balance":"9.99","approx_local_messages":[1,2]},
             "spend_control":null,
             "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox",
               "rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":70,"limit_window_seconds":18000,
               "reset_after_seconds":900,"reset_at":1763000900},"secondary_window":null}}],
             "rate_limit_reached_type":null,"something_new":{"x":1}}
            """.utf8), now: now)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.meters.map(\.id) == ["5h", "weekly", "gpt-5.3-codex-spark:5h"])
        #expect(snapshot.meters.map(\.label) == ["5h", "w", "+5h"])
        #expect(snapshot.meters.map(\.percent) == [42, 7, 70])
        #expect(snapshot.meters[0].title == "5-hour limit" && snapshot.meters[0].short && !snapshot.meters[1].short)
        #expect(snapshot.meters[0].resetsAt == Date(timeIntervalSince1970: 1_763_003_600))
        #expect(snapshot.meters[2].title == "GPT-5.3-Codex-Spark · 5-hour limit")
        #expect(snapshot.money == [Money(id: "credits", title: "Credits", role: .balance, amount: Decimal(string: "9.99")!,
                                         currency: nil, digits: 2, headline: true)])
    }

    @Test func goWithoutLimits() throws {
        let snapshot = try OpenAI.usage(Data(#"{"plan_type":"go","rate_limit":null,"credits":null}"#.utf8), now: now)
        #expect(snapshot.plan == "Go" && snapshot.isEmpty)
        let bare = try OpenAI.usage(Data(#"{"plan_type":"go"}"#.utf8), now: now)
        #expect(bare.plan == "Go" && bare.isEmpty)
    }

    @Test func goWithOneWindow() throws {
        let snapshot = try OpenAI.usage(Data("""
            {"plan_type":"go","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":
              {"used_percent":"12","limit_window_seconds":"2592000","reset_after_seconds":"100","reset_at":1765592000000},
              "secondary_window":null},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
            """.utf8), now: now)
        #expect(snapshot.meters.count == 1 && snapshot.money.isEmpty)
        let meter = try #require(snapshot.meters.first)
        #expect(meter.id == "monthly" && meter.label == "mo" && meter.percent == 12 && meter.title == "Monthly limit")
        #expect(meter.resetsAt == Date(timeIntervalSince1970: 1_765_592_000), "milliseconds are read as such")
    }

    @Test func windowsAreNamedByLength() {
        #expect(OpenAI.Window(seconds: 18000) == .fiveHours)
        #expect(OpenAI.Window(seconds: 604800) == .weekly)
        #expect(OpenAI.Window(seconds: 2592000) == .monthly && OpenAI.Window(seconds: 2678400) == .monthly)
        #expect(OpenAI.Window(seconds: 86400) == .daily)
        #expect(OpenAI.Window(seconds: 3600)?.label == "1h")
        #expect(OpenAI.Window(seconds: 300)?.label == "5m")
        #expect(OpenAI.Window(seconds: 1_209_600)?.label == "14d")
        #expect(OpenAI.Window(seconds: 0) == nil && OpenAI.Window(seconds: nil) == nil)
    }

    @Test func malformedPartsAreLeftOut() throws {
        let snapshot = try OpenAI.usage(Data("""
            {"plan_type":7,"rate_limit":{"primary_window":{"used_percent":null,"limit_window_seconds":18000},
              "secondary_window":{"used_percent":50}},
             "credits":{"has_credits":true,"unlimited":true,"balance":null},
             "additional_rate_limits":[{"limit_name":"x"},{"bad":true},"nope"]}
            """.utf8), now: now)
        #expect(snapshot.plan == nil && snapshot.isEmpty)
        #expect(throws: (any Error).self) { try OpenAI.usage(Data(#"{"detail":"Unauthorized"}"#.utf8), now: now) }
        #expect(throws: (any Error).self) { try OpenAI.usage(Data("<html>".utf8), now: now) }
    }

    @Test func monthlyCreditCap() throws {
        let snapshot = try OpenAI.usage(Data("""
            {"plan_type":"business","rate_limit":null,"spend_control":{"reached":true,"individual_limit":
              {"limit":"25000","used":"25000","remaining":"0","used_percent":100,"reset_at":1764000000}}}
            """.utf8), now: now)
        let cap = try #require(snapshot.money.first)
        #expect(snapshot.plan == "Business" && cap.amount == 25000 && cap.limit == 25000 && cap.currency == nil)
        #expect(cap.severity == .critical && cap.end == Date(timeIntervalSince1970: 1_764_000_000) && cap.headline)
    }

    @Test func plans() {
        #expect(OpenAI.planName("go") == "Go" && OpenAI.planName("prolite") == "Pro Lite")
        #expect(OpenAI.planName("enterprise_cbp_usage_based") == "Enterprise")
        #expect(OpenAI.planName("unknown") == nil && OpenAI.planName("guest") == nil && OpenAI.planName("") == nil)
        #expect(OpenAI.planName("some_new_plan") == "Some New Plan")
    }

    @Test func fetchSendsTheWorkspace() async throws {
        let recorder = Canned.Seen()
        let credential = Credential(secret: "access", refresh: "r", fields: ["id": "user-9/acc-123", "account": "acc-123"])
        let context = FetchContext(account: "openai-x", credential: credential,
                                   http: Canned.http(seen: recorder) { _ in (200, #"{"plan_type":"go","rate_limit":null}"#) },
                                   now: now, costs: Canned.Costs())
        let snapshot = try await OpenAI.account.fetch(context)
        #expect(snapshot.plan == "Go")
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage" && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc-123")
    }

    @Test func fetchFailures() async {
        func context(_ status: Int, _ body: String = "") -> FetchContext {
            Canned.context(Canned.http(headers: ["Retry-After": "60"]) { _ in (status, body) }, Credential(secret: "t"), now: now)
        }
        await #expect(throws: FetchFailure.unauthorized) { try await OpenAI.account.fetch(context(401, #"{"detail":"Unauthorized"}"#)) }
        await #expect(throws: FetchFailure.server(403)) { try await OpenAI.account.fetch(context(403, "<html>")) }
        await #expect(throws: FetchFailure.rateLimited(60)) { try await OpenAI.account.fetch(context(429)) }
        await #expect(throws: FetchFailure.unreadable) { try await OpenAI.account.fetch(context(200, "{}")) }
    }
}

@Suite struct ChatGPTAuthTests {
    let now = Date(timeIntervalSince1970: 1_763_049_574)

    @Test func userCode() throws {
        // As auth.openai.com answered an unauthenticated probe.
        let code = try ChatGPTAuth.userCode(Data("""
            {"device_auth_id":"deviceauth_6af7","user_code":"G80M-MYXWN","interval":"5",
             "expires_at":"2026-11-13T16:34:34.530896+00:00"}
            """.utf8), now: ISO8601.date("2026-11-13T16:19:34Z")!)
        #expect(code.deviceCode == "deviceauth_6af7" && code.userCode == "G80M-MYXWN" && code.interval == 5)
        #expect(code.verificationURL.absoluteString == "https://auth.openai.com/codex/device")
        #expect(abs(code.expiresAt.timeIntervalSince(ISO8601.date("2026-11-13T16:34:34Z")!)) < 1)
        let fallback = try ChatGPTAuth.userCode(Data(#"{"device_auth_id":"d","usercode":"AB-CD","interval":7}"#.utf8), now: now)
        #expect(fallback.userCode == "AB-CD" && fallback.interval == 7 && fallback.expiresAt == now + 900)
        #expect(throws: (any Error).self) { try ChatGPTAuth.userCode(Data(#"{"device_auth_id":"d"}"#.utf8)) }
    }

    @Test func pollAnswers() throws {
        let pending = Data(#"{"error":{"message":"Device authorization is pending. Please try again.","type":"invalid_request_error","param":null,"code":"deviceauth_authorization_pending"}}"#.utf8)
        #expect(try ChatGPTAuth.pollResult(status: 403, body: pending) == .waiting(.pending))
        #expect(try ChatGPTAuth.pollResult(status: 404, body: Data()) == .waiting(.pending))
        #expect(try ChatGPTAuth.pollResult(status: 403, body: Data(#"{"error":{"code":"deviceauth_expired"}}"#.utf8)) == .waiting(.expired))
        #expect(try ChatGPTAuth.pollResult(status: 200, body: Data(#"{"authorization_code":"c","code_challenge":"x","code_verifier":"v"}"#.utf8))
                == .approved(.init(code: "c", verifier: "v")))
        #expect(throws: FetchFailure.unreadable) { try ChatGPTAuth.pollResult(status: 200, body: Data("{}".utf8)) }
        #expect(throws: FetchFailure.rateLimited(10)) { try ChatGPTAuth.pollResult(status: 429, body: Data(), retryAfter: "10") }
        #expect(throws: FetchFailure.server(500)) { try ChatGPTAuth.pollResult(status: 500, body: Data()) }
    }

    @Test func approvalExchangesTheCode() async throws {
        let recorder = Canned.Seen()
        let access = jwt(["exp": 1_764_000_000])
        let device = DeviceCode(deviceCode: "deviceauth_1", userCode: "AB-CD", verificationURL: ChatGPTAuth.verificationURL,
                                expiresAt: now + 900)
        let server = Canned.http(seen: recorder) { request in
            switch request.url?.path() {
            case "/api/accounts/deviceauth/token": (200, #"{"authorization_code":"code-1","code_challenge":"ch","code_verifier":"ver-1"}"#)
            case "/oauth/token": (200, #"{"id_token":"\#(idToken)","access_token":"\#(access)","refresh_token":"rt-1"}"#)
            default: (404, "")
            }
        }
        guard case .approved(let credential) = try await ChatGPTAuth.flow.poll(device, server) else {
            Issue.record("approved")
            return
        }
        #expect(credential.secret == access && credential.refresh == "rt-1")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_764_000_000))
        #expect(credential.fields == ["id": "user-9/acc-123", "account": "acc-123", "email": "jane@example.com", "name": "Jane Doe"])
        #expect(!credential.fields.values.contains(idToken), "the ID token itself isn't kept")
        let poll = recorder.requests[0], exchange = recorder.requests[1]
        #expect(body(poll) == ["device_auth_id": "deviceauth_1", "user_code": "AB-CD"] && poll.httpMethod == "POST")
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(body(exchange) == ["grant_type": "authorization_code", "client_id": ChatGPTAuth.clientID, "code": "code-1",
                                   "redirect_uri": "https://auth.openai.com/deviceauth/callback", "code_verifier": "ver-1"])
        #expect(try await OpenAI.account.identify(credential, server)
                == Identity(id: "user-9/acc-123", name: "Jane Doe", email: "jane@example.com"))
        #expect(OpenAI.account.accountID("user-9/acc-123") == "openai-user-9/acc-123")
    }

    @Test func aFailedExchangeIsRetriedWithTheSameCode() async throws {
        let recorder = Canned.Seen()
        let device = DeviceCode(deviceCode: "deviceauth_2", userCode: "EF-GH", verificationURL: ChatGPTAuth.verificationURL,
                                expiresAt: now + 900)
        let failing = Canned.http(seen: recorder) { request in
            request.url?.path() == "/oauth/token" ? (502, "") : (200, #"{"authorization_code":"c2","code_verifier":"v2"}"#)
        }
        await #expect(throws: FetchFailure.server(502)) { try await ChatGPTAuth.flow.poll(device, failing) }
        let working = Canned.http(seen: recorder) { request in
            request.url?.path() == "/oauth/token"
                ? (200, #"{"id_token":"\#(idToken)","access_token":"a2","refresh_token":"r2","expires_in":3600}"#) : (403, "")
        }
        guard case .approved(let credential) = try await ChatGPTAuth.flow.poll(device, working) else {
            Issue.record("approved on the retry")
            return
        }
        #expect(credential.secret == "a2" && credential.expiresAt != nil)
        #expect(recorder.requests.map { $0.url!.path() } == ["/api/accounts/deviceauth/token", "/oauth/token", "/oauth/token"])
        #expect(body(recorder.requests[2])["code"] == "c2")
    }

    @Test func refreshRotatesTheToken() async throws {
        let recorder = Canned.Seen()
        let old = Credential(secret: "a1", refresh: "rt-1", expiresAt: now,
                             fields: ["id": "user-9/acc-123", "account": "acc-123", "email": "old@example.com"])
        let refresh = try #require(OpenAI.account.auth.refresh)
        let renewed = try await refresh(old, Canned.http(seen: recorder) { _ in (200, #"{"access_token":"a2","refresh_token":"rt-2"}"#) })
        #expect(renewed.secret == "a2" && renewed.refresh == "rt-2" && renewed.fields == old.fields)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body(request) == ["client_id": ChatGPTAuth.clientID, "grant_type": "refresh_token", "refresh_token": "rt-1"])
        // A new ID token updates who it is; a response without a refresh token keeps the old one.
        let again = try await refresh(renewed, Canned.http { _ in (200, #"{"access_token":"a3","id_token":"\#(idToken)"}"#) })
        #expect(again.refresh == "rt-2" && again.fields["email"] == "jane@example.com")
    }

    @Test func aReusedRefreshTokenMeansSigningInAgain() async throws {
        let refresh = try #require(OpenAI.account.auth.refresh)
        let credential = Credential(secret: "a", refresh: "rt", fields: ["id": "u"])
        func answer(_ status: Int, _ body: String) async -> FetchFailure? {
            do { _ = try await refresh(credential, Canned.http { _ in (status, body) }); return nil } catch { return error }
        }
        #expect(await answer(401, #"{"error":{"message":"Could not validate your refresh token.","type":"invalid_request_error","param":null,"code":"invalid_refresh_token"}}"#) == .signInRequired)
        #expect(await answer(400, #"{"error":{"code":"refresh_token_reused"}}"#) == .signInRequired)
        #expect(await answer(403, #"{"error":"refresh_token_expired"}"#) == .signInRequired)
        #expect(await answer(400, #"{"error":"invalid_grant"}"#) == .signInRequired)
        #expect(await answer(400, #"{"error":{"code":"something_else"}}"#) == .server(400), "kept: it may still work")
        #expect(await answer(403, "<html>Cloudflare</html>") == .server(403))
        #expect(await answer(502, "") == .server(502))
        #expect(await answer(200, "{}") == .unreadable)
        await #expect(throws: FetchFailure.signInRequired) {
            try await refresh(Credential(secret: "a"), Canned.http { _ in (200, "") })
        }
    }

    @Test func claims() {
        let claims = ChatGPTAuth.Claims(idToken: jwt([
            "sub": "s", "https://api.openai.com/profile": ["email": "p@example.com"],
            "https://api.openai.com/auth": ["chatgpt_account_user_id": "user-1__acc-2", "chatgpt_account_id": "acc-2"],
        ]))
        #expect(claims?.id == "user-1__acc-2" && claims?.email == "p@example.com" && claims?.name == nil)
        #expect(ChatGPTAuth.Claims(idToken: jwt(["sub": "s"]))?.id == "s")
        #expect(ChatGPTAuth.Claims(idToken: jwt([:])) == nil && ChatGPTAuth.Claims(idToken: "not.a-jwt") == nil)
        #expect(throws: FetchFailure.signInRequired) { try ChatGPTAuth.identity(Credential(secret: "a")) }
    }
}

@Suite struct OpenAICostTests {
    @Test func pages() throws {
        let page = try OpenAI.CostPage.decode(Data("""
            {"object":"page","data":[
              {"object":"bucket","start_time":1762905600,"end_time":1762992000,"results":[
                {"object":"organization.costs.result","amount":{"value":0.13080438340307526,"currency":"usd"},"line_item":null,"project_id":null},
                {"object":"organization.costs.result","amount":{"value":1.2e-05,"currency":"usd"},"line_item":null,"project_id":"proj_1"}]},
              {"object":"bucket","start_time":1762992000,"end_time":1763078400,"results":[]}],
             "has_more":true,"next_page":"page_AAA"}
            """.utf8))
        let day = Date(timeIntervalSince1970: 1_762_905_600)
        #expect(page.days[day] == Decimal(string: "13.081638340307526"))
        #expect(page.days[Date(timeIntervalSince1970: 1_762_992_000)] == 0 && page.nextPage == "page_AAA")
        #expect(throws: (any Error).self) {
            try OpenAI.CostPage.decode(Data(#"{"data":[{"start_time":1,"results":[{"amount":{"value":1,"currency":"eur"}}]}]}"#.utf8))
        }
        #expect(throws: (any Error).self) { try OpenAI.CostPage.decode(Data(#"{"data":[],"has_more":true}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try OpenAI.CostPage.decode(Data(#"{"data":[{"start_time":1762905600,"results":[{"amount":null}]}]}"#.utf8))
        }
    }

    @Test func monthToDateAndToday() async throws {
        let now = ISO8601.date("2026-11-12T15:00:00Z")!
        let recorder = Canned.Seen()
        let report = Canned.http(seen: recorder) { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }
            return page == nil
                ? (200, #"{"data":[{"start_time":\#(Int(ISO8601.date("2026-11-01T00:00:00Z")!.timeIntervalSince1970)),"results":[{"amount":{"value":10,"currency":"usd"}}]}],"has_more":true,"next_page":"p2"}"#)
                : (200, #"{"data":[{"start_time":\#(Int(ISO8601.date("2026-11-12T00:00:00Z")!.timeIntervalSince1970)),"results":[{"amount":{"value":2.505,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#)
        }
        let context = FetchContext(account: "openai-org-x", credential: Credential(secret: "sk-admin-k"), http: report,
                                   now: now, costs: Canned.Costs())
        let snapshot = try await OpenAI.organization.fetch(context)
        #expect(snapshot.headline?.amount == Decimal(string: "12.505") && snapshot.money.last?.amount == Decimal(string: "2.505"))
        #expect(recorder.requests.count == 2)
        let first = try #require(recorder.requests.first)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer sk-admin-k")
        #expect(first.url?.host() == "api.openai.com" && first.url?.path() == "/v1/organization/costs")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: first.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(query["start_time"] == String(Int(ISO8601.date("2026-11-01T00:00:00Z")!.timeIntervalSince1970)))
        #expect(query["bucket_width"] == "1d" && query["end_time"] == nil, "a range reaching past now stays open")
        #expect(recorder.requests[1].url?.query()?.contains("page=p2") == true)
    }

    @Test func dailyCostsOfPastDaysAskForAnEnd() async throws {
        let recorder = Canned.Seen()
        let now = ISO8601.date("2026-11-12T15:00:00Z")!
        let range = ISO8601.date("2026-10-01T00:00:00Z")!..<ISO8601.date("2026-10-31T00:00:00Z")!
        _ = try await OpenAI.organization.dailyCosts?(Credential(secret: "k"), range, Canned.http(seen: recorder) { _ in (200, #"{"data":[]}"#) }, now)
        #expect(recorder.requests.first?.url?.query()?.contains("end_time=\(Int(range.upperBound.timeIntervalSince1970))") == true)
    }

    @Test func identity() async throws {
        let ok = #"{"object":"page","data":[],"has_more":false,"next_page":null}"#
        let named = try await OpenAI.organization.identify(Credential(secret: "sk-admin-k", fields: ["name": "Acme"]),
                                                           Canned.http(headers: ["openai-organization": "org-abc"]) { _ in (200, ok) })
        #expect(named == Identity(id: "org-abc", name: "Acme") && OpenAI.organization.accountID(named.id) == "openai-org-org-abc")
        let anonymous = try await OpenAI.organization.identify(Credential(secret: "sk-admin-k"), Canned.http { _ in (200, ok) })
        #expect(anonymous.id.hasPrefix("key-") && anonymous.id.count == 20 && !anonymous.id.contains("sk-admin"))
        #expect(anonymous.name == "OpenAI organisation")
        await #expect(throws: FetchFailure.unauthorized) {
            try await OpenAI.organization.identify(Credential(secret: "sk-admin-bogus"), Canned.http { _ in
                (401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#)
            })
        }
        await #expect(throws: FetchFailure.forbidden) {
            try await OpenAI.organization.identify(Credential(secret: "sk-admin-k"), Canned.http { _ in (403, "") })
        }
    }

    @Test func keyShapes() {
        #expect(OpenAI.keyForm.validate(["key": "sk-proj-abc"])?.contains("Admin API key") == true)
        #expect(OpenAI.keyForm.validate(["key": "sk-abc"]) != nil)
        #expect(OpenAI.keyForm.validate(["key": "sk-admin-abc"]) == nil)
        #expect(OpenAI.keyForm.credential(["key": "sk-admin-abc", "name": "Acme"])
                == Credential(secret: "sk-admin-abc", fields: ["name": "Acme"]))
    }
}
