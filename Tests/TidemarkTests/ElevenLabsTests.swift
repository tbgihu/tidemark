import Foundation
import Testing
@testable import TidemarkCore

/// ElevenLabs subscriptions, from responses shaped as the service sends them.
@Suite struct ElevenLabsTests {
    let now = Date(timeIntervalSince1970: 1_794_560_000)

    @Test func creditsAndTier() throws {
        let body = """
        {"tier":"growing_business","character_count":12345,"character_limit":100000,"can_extend_character_limit":true,
         "next_character_count_reset_unix":1795000000,"voice_slots_used":3,"voice_limit":30,"status":"active",
         "currency":"usd","current_overage":null}
        """
        let snapshot = try ElevenLabsSubscription.snapshot(Data(body.utf8), now: now)
        #expect(snapshot.meters == [Meter(id: "credits", title: "Credits", label: "mo", noun: "Credit limit", percent: 12.345,
                                          resetsAt: Date(timeIntervalSince1970: 1_795_000_000))])
        #expect(snapshot.plan == "Growing Business")
    }

    @Test func edgeCases() throws {
        let free = try ElevenLabsSubscription.snapshot(Data(#"{"tier":"free","character_count":"12000","character_limit":10000,"status":"past_due"}"#.utf8), now: now)
        #expect(free.meters.first?.percent == 100 && free.meters.first?.resetsAt == nil && free.plan == "Free · Past Due")
        let none = try ElevenLabsSubscription.snapshot(Data(#"{"tier":"free","character_count":0,"character_limit":0}"#.utf8), now: now)
        #expect(none.meters.isEmpty && none.plan == "Free", "no limit is no meter, not 0 %")
        #expect(throws: FetchFailure.unreadable) { try ElevenLabsSubscription.snapshot(Data(#"{"detail":"x"}"#.utf8), now: now) }
    }

    @Test func requestsAndRefusals() async throws {
        let seen = Canned.Seen()
        let http = Canned.http(#"{"tier":"starter","character_count":1,"character_limit":30000}"#, seen: seen)
        _ = try await ElevenLabs.key.fetch(Canned.context(http, Credential(secret: "sk_1")))
        #expect(seen.urls == ["https://api.elevenlabs.io/v1/user/subscription"])
        #expect(seen.requests[0].value(forHTTPHeaderField: "xi-api-key") == "sk_1"
                && seen.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try await ElevenLabs.key.identify(Credential(secret: "sk_1", fields: ["name": "Studio"]), http).name == "Studio")

        // As probed with a bogus key: 401 with detail.status invalid_api_key.
        let invalid = #"{"detail":{"type":"authentication_error","code":"unauthorized","message":"Invalid API key","status":"invalid_api_key"}}"#
        await #expect(throws: FetchFailure.unauthorized) {
            try await ElevenLabs.key.fetch(Canned.context(Canned.http(invalid, status: 401), Credential(secret: "x")))
        }
        let missing = #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission user_read"}}"#
        for status in [401, 403] {
            await #expect(throws: FetchFailure.forbidden) {
                try await ElevenLabs.key.fetch(Canned.context(Canned.http(missing, status: status), Credential(secret: "x")))
            }
        }
        await #expect(throws: FetchFailure.rateLimited(9)) {
            try await ElevenLabs.key.fetch(Canned.context(Canned.http("", status: 429, headers: ["Retry-After": "9"]), Credential(secret: "x")))
        }
    }
}
