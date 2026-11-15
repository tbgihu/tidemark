import Foundation
import Testing
@testable import TidemarkCore

@Suite struct CursorTests {
    let now = ISO8601.date("2026-11-13T12:00:00Z")!

    /// A Pro account with on-demand turned on and capped, as `GET /api/usage-summary` sends it.
    static let pro = """
    {"billingCycleStart":"2026-11-01T08:12:44.000Z","billingCycleEnd":"2026-12-01T08:12:44.000Z",
     "membershipType":"pro","limitType":"user","isUnlimited":false,
     "autoModelSelectedDisplayMessage":"You've used 36% of your included usage",
     "individualUsage":{
       "plan":{"enabled":true,"used":1450,"limit":2000,"remaining":550,
               "breakdown":{"included":1450,"bonus":0,"total":1450},
               "autoPercentUsed":12.5,"apiPercentUsed":60,"totalPercentUsed":36.25},
       "onDemand":{"enabled":true,"used":1234,"limit":5000,"remaining":3766}},
     "teamUsage":{}}
    """

    @Test func proAccount() throws {
        let snapshot = try CursorUsage.decode(Data(Self.pro.utf8)).snapshot(fetchedAt: now)
        let plan = try #require(snapshot[meter: "plan"])
        #expect(plan.percent == 36.25 && plan.label == "mo" && !plan.short)
        #expect(plan.resetsAt == ISO8601.date("2026-12-01T08:12:44Z"))
        #expect(snapshot.plan == "Pro" && snapshot.note == nil)
        let onDemand = try #require(snapshot.money.first)
        #expect(snapshot.money.count == 1, "a team block with nothing in it shows nothing")
        #expect(onDemand.id == "on-demand" && onDemand.amount == Decimal(string: "12.34") && onDemand.limit == 50)
        #expect(onDemand.currency == "USD" && onDemand.partial && !onDemand.headline)
        #expect(onDemand.start == ISO8601.date("2026-11-01T08:12:44Z") && onDemand.end == plan.resetsAt)
    }

    /// Without `totalPercentUsed`, the share is the plan's cents used of its limit; then an enterprise member's own
    /// cap; then the team's pool.
    @Test func percentFallsBackToCents() throws {
        func percent(_ json: String) throws -> Double? { try CursorUsage.decode(Data(json.utf8)).planPercent }
        #expect(try percent(#"{"individualUsage":{"plan":{"used":"500","limit":2000}}}"#) == 25)
        #expect(abs(try percent(#"{"individualUsage":{"plan":{"used":500,"limit":0},"overall":{"used":7384,"limit":10000}}}"#)! - 73.84) < 1e-9)
        #expect(try percent(#"{"individualUsage":{},"teamUsage":{"pooled":{"used":100,"limit":400}}}"#) == 25)
        #expect(try percent(#"{"individualUsage":{"plan":{"enabled":false,"used":5,"limit":10}}}"#) == nil)
        #expect(try percent(#"{"individualUsage":{"plan":{"totalPercentUsed":0.36}}}"#) == 0.36, "already a percentage")
        #expect(try percent(#"{"isUnlimited":true,"individualUsage":{"plan":{"totalPercentUsed":40}}}"#) == nil)
    }

    /// On-demand without a cap is an amount, not a bar; turned off, it isn't shown; a team's shared budget is its own
    /// figure. With no meter, the first figure is the menu bar's.
    @Test func onDemandSpending() throws {
        let json = """
        {"membershipType":"team","billingCycleEnd":1796112000000,
         "individualUsage":{"onDemand":{"enabled":true,"used":250,"limit":null}},
         "teamUsage":{"onDemand":{"enabled":true,"used":"10000.5","limit":"50000"}}}
        """
        let snapshot = try CursorUsage.decode(Data(json.utf8)).snapshot(fetchedAt: now)
        #expect(snapshot.meters.isEmpty && snapshot.plan == "Teams")
        #expect(snapshot.money.map(\.id) == ["on-demand", "team-on-demand"])
        #expect(snapshot.money[0].limit == nil && snapshot.money[0].amount == Decimal(string: "2.5") && snapshot.money[0].headline)
        #expect(snapshot.money[1].amount == Decimal(string: "100.005") && snapshot.money[1].limit == 500 && !snapshot.money[1].headline)
        #expect(snapshot.money[0].end == Date(timeIntervalSince1970: 1_796_112_000), "milliseconds since 1970")

        let off = try CursorUsage.decode(Data(#"{"individualUsage":{"onDemand":{"enabled":false,"used":0,"limit":0}}}"#.utf8))
        #expect(off.onDemand == nil)
    }

    @Test func accountsWithNothingSaySo() throws {
        let free = try CursorUsage.decode(Data(#"{"membershipType":"free","individualUsage":null,"teamUsage":null}"#.utf8))
            .snapshot(fetchedAt: now)
        #expect(free.isEmpty && free.note == "No active plan" && free.plan == "Free")
        let unlimited = try CursorUsage.decode(Data(#"{"membershipType":"enterprise","isUnlimited":true}"#.utf8)).snapshot(fetchedAt: now)
        #expect(unlimited.isEmpty && unlimited.note == "Unlimited plan" && unlimited.plan == "Enterprise")
        #expect(CursorUsage.planName("pro_plus") == "Pro+" && CursorUsage.planName("some_new_plan") == "Some New Plan")
    }

    /// Wrong types and unknown fields are skipped; only a body that isn't a summary at all fails.
    @Test func decodesLeniently() throws {
        let odd = """
        {"billingCycleEnd":"soon","membershipType":42,"newField":{"x":1},
         "individualUsage":{"plan":{"totalPercentUsed":"n/a","used":true,"limit":2000},"onDemand":"on"}}
        """
        let usage = try CursorUsage.decode(Data(odd.utf8))
        #expect(usage.cycleEnd == nil && usage.membership == nil && usage.planPercent == 0 && usage.onDemand == nil)
        #expect(throws: (any Error).self) { try CursorUsage.decode(Data(#"{"error":"x"}"#.utf8)) }
        #expect(throws: (any Error).self) { try CursorUsage.decode(Data("[]".utf8)) }
    }

    @Test func fetchSendsTheSessionCookie() async throws {
        let recorder = Canned.Seen()
        let context = FetchContext(account: "cursor-u", credential: Credential(secret: "user_01%3A%3Ajwt", fields: ["webStore": "x"]),
                                   http: Canned.http(Self.pro, seen: recorder), now: now, costs: Canned.Costs())
        let snapshot = try await Cursor.account.fetch(context)
        #expect(snapshot[meter: "plan"]?.percent == 36.25 && snapshot.fetchedAt == now)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://cursor.com/api/usage-summary" && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=user_01%3A%3Ajwt")
    }

    /// cursor.com answers 401 `not_authenticated` without a session (checked live): sign in again, as for a 403.
    @Test func anEndedSessionNeedsSigningIn() async {
        let context = { (status: Int) in
            FetchContext(account: "a", credential: Credential(secret: "s"),
                         http: Canned.http(#"{"error":"not_authenticated"}"#, status: status), now: now,
                         costs: Canned.Costs())
        }
        await #expect(throws: FetchFailure.unauthorized) { try await Cursor.account.fetch(context(401)) }
        await #expect(throws: FetchFailure.forbidden) { try await Cursor.account.fetch(context(403)) }
        #expect(FetchFailure.unauthorized.needsUser && FetchFailure.forbidden.needsUser)
    }

    @Test func identity() async throws {
        let recorder = Canned.Seen()
        let me = #"{"email":"jane@example.com","email_verified":true,"name":"Jane Doe","sub":"user_01JABC","picture":null}"#
        let identity = try await Cursor.account.identify(Credential(secret: "s"), Canned.http(me, seen: recorder))
        #expect(identity == Identity(id: "user_01JABC", name: "Jane Doe", email: "jane@example.com"))
        #expect(Cursor.account.accountID(identity.id) == "cursor-user_01JABC")
        #expect(recorder.requests.first?.url?.absoluteString == "https://cursor.com/api/auth/me")

        // Signed out, the endpoint answers 204 with no body (checked live): no one yet, so the sheet keeps waiting.
        await #expect(throws: FetchFailure.unauthorized) {
            try await Cursor.account.identify(Credential(secret: "s"), Canned.http("", status: 204))
        }
        await #expect(throws: FetchFailure.unauthorized) {
            try await Cursor.account.identify(Credential(secret: "s"), Canned.http(#"{"email":"x@example.com"}"#))
        }
        let unnamed = try #require(try CursorUser.decode(Data(#"{"sub":"u","email":"x@example.com","name":" "}"#.utf8)))
        #expect(unnamed.name == "x@example.com")
    }

    @Test func signInKeepsTheWorkOSCookie() {
        guard case .web(let web) = Cursor.account.auth else { Issue.record("Cursor signs in on the web"); return }
        #expect(web.start.absoluteString == "https://cursor.com/dashboard")
        #expect(web.matches(name: "WorkosCursorSessionToken", domain: "cursor.com"))
        #expect(web.matches(name: "WorkosCursorSessionToken", domain: ".cursor.com"))
        #expect(!web.matches(name: "WorkosCursorSessionToken", domain: "authenticator.cursor.sh"))
        #expect(!web.matches(name: "WorkosCursorAuthNonce", domain: "cursor.com"))
        #expect(Cursor.provider.recommendedMinimumInterval >= 600)
    }
}
