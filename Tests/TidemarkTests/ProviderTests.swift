import Foundation
import Testing
@testable import TidemarkCore

@Suite struct RegistryTests {
    @Test func everyProviderIsConsistent() {
        let providers = Registry.builtIn
        #expect(Set(providers.map(\.id)).count == providers.count, "ids are unique")
        #expect(Set(providers.map(\.brandColor)).count == providers.count, "colours are distinct")
        for provider in providers {
            #expect(Registry.order.contains(provider.id), "\(provider.id) has a reserved place")
            #expect(provider.order == Registry.order(of: provider.id), "\(provider.id) declares its place")
            #expect(!provider.logins.isEmpty && Set(provider.logins.map(\.id)).count == provider.logins.count)
            #expect(provider.recommendedMinimumInterval >= 15)
        }
        let items = providers.flatMap(\.logins).map(\.secretItem)
        #expect(Set(items).count == items.count, "every login has a Keychain item of its own")
        #expect(items.allSatisfy { !$0.contains("#") && !$0.contains("\"") })
        #expect(Registry.order.first == Claude.id && Registry.order.count == 15)
        #expect(!Registry.builtIn.contains { $0.id == Example.id }, "the fake provider is never built in")
    }

    /// Frames tell providers apart at a glance, on light and dark menu bars alike: every colour is of middling
    /// lightness, and far enough from every other (CIELAB distance) and from the warning orange and red.
    @Test func coloursAreReadableAndApart() {
        func lab(_ color: BrandColor) -> (l: Double, a: Double, b: Double) {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let (r, g, b) = (linear(color.red), linear(color.green), linear(color.blue))
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        func distance(_ p: BrandColor, _ q: BrandColor) -> Double {
            let (a, b) = (lab(p), lab(q))
            return ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
        }
        let providers = Registry.builtIn
        let warnings = [BrandColor(hex: 0xFF9500), BrandColor(hex: 0xFF453A)]
        for (index, provider) in providers.enumerated() {
            #expect((48...64).contains(lab(provider.brandColor).l), "\(provider.id) reads on light and dark menu bars")
            #expect(warnings.allSatisfy { distance(provider.brandColor, $0) > 30 }, "\(provider.id) isn't a warning colour")
            for other in providers[(index + 1)...] {
                #expect(distance(provider.brandColor, other.brandColor) > 14, "\(provider.id) and \(other.id) are apart")
            }
        }
    }

    @Test func accountsAreGroupedInTheFixedOrderKeepingTheirOwn() {
        func account(_ id: String, _ provider: String) -> Account { Account(id: id, provider: provider, login: "x", name: id) }
        let grouped = SavedState.grouped([account("x1", "xai"), account("c1", Claude.id), account("x2", "xai"),
                                          account("o1", "openai"), account("c2", Claude.id)])
        #expect(grouped.map(\.id) == ["c1", "c2", "o1", "x1", "x2"])
        #expect(grouped.providers == [Claude.id, "openai", "xai"])
        #expect(grouped.of("xai").map(\.id) == ["x1", "x2"])
    }
}

@Suite struct CredentialTests {
    /// The Keychain items keep the shapes they had before credentials were generic: tokens and keys read back as
    /// written, and are written the same way again.
    @Test func readsAndWritesTheStoredShapes() throws {
        let tokens = #"{"u-1":{"access":"a","refresh":"r","expiresAt":800000000}}"#
        let decoded = try JSONDecoder().decode([String: Credential].self, from: Data(tokens.utf8))
        #expect(decoded["u-1"] == Credential(secret: "a", refresh: "r", expiresAt: Date(timeIntervalSinceReferenceDate: 800_000_000)))
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: [String: Any]]
        #expect(again?["u-1"]?.keys.sorted() == ["access", "expiresAt", "refresh"])

        let keys = #"{"org-1":"sk-ant-admin01-x"}"#
        let decodedKeys = try JSONDecoder().decode([String: Credential].self, from: Data(keys.utf8))
        #expect(decodedKeys["org-1"] == Credential(secret: "sk-ant-admin01-x"))
        #expect(String(decoding: try JSONEncoder().encode(decodedKeys), as: UTF8.self) == keys)
    }

    @Test func extraFieldsRoundTrip() throws {
        let credential = Credential(secret: "k", fields: ["team": "t", "region": "eu"])
        #expect(try JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(credential)) == credential)
    }

    @Test func onlyRefreshableCredentialsExpire() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(Credential(secret: "a", refresh: "r", expiresAt: now + 299).needsRefresh(now: now))
        #expect(!Credential(secret: "a", refresh: "r", expiresAt: now + 3600).needsRefresh(now: now))
        #expect(!Credential(secret: "a", expiresAt: now).needsRefresh(now: now), "a cookie can't be refreshed")
    }
}

/// State written before providers existed: Claude accounts, read once and saved in the new shape, ids unchanged.
@Suite struct MigrationTests {
    let legacy = """
    {"accounts":[
      {"id":"u1","name":"Jane","email":"jane@example.com","showPercent":true,"hiddenInMenuBar":true,"historyExpanded":true,
       "needsSignIn":false,"profileFetchedAt":800000000,
       "usage":{"limits":["session",{"percent":48,"resetsAt":800003600,"reportedSeverity":"normal"},"fable",{"percent":75}],
                "extra":{"spentMinor":1240,"limitMinor":5000,"currency":"EUR","decimals":2},"fetchedAt":800000000}},
      {"id":"org-9","kind":"organization","name":"Acme","email":"","cost":{"month":"41234.5","today":"1200",
       "monthStart":783907200,"todayStart":784857600,"fetchedAt":784900000}},
      {"id":"x","kind":"galaxy","name":"?"},
      {"id":"org-2","kind":"organization","name":"B","cost":{"month":12}}
    ],"fired":["u1|session|800003600|75"]}
    """

    @Test func claudeAccountsMigrate() throws {
        let state = try #require(SavedState.load(Data(legacy.utf8)))
        #expect(state.accounts.map(\.id) == ["u1", "org-9", "org-2"], "a kind from the future is skipped")
        #expect(state.accounts.allSatisfy { $0.provider == Claude.id })
        #expect(state.accounts.map(\.login) == [Claude.account.id, Claude.console.id, Claude.console.id])
        #expect(state.fired == ["u1|session|800003600|75"], "notification state keys on the same meter ids")

        let jane = state.accounts[0]
        #expect(!jane.showBars && !jane.showPercent && !jane.inMenuBar && jane.historyExpanded && jane.email == "jane@example.com",
                "hidden from the menu bar, it shows neither")
        #expect(jane.profileFetchedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        let usage = try #require(jane.snapshot)
        #expect(usage.meters.map(\.id) == ["session", "fable"] && usage.meters.map(\.label) == ["5h", "w(F)"])
        #expect(usage.meters[0].short && usage.meters[0].reportedSeverity == "normal" && usage.meters[0].noun == "Session limit")
        #expect(usage.money.first?.amount == Decimal(string: "12.4") && usage.money.first?.limit == 50
                && usage.money.first?.currency == "EUR")

        let acme = try #require(state.accounts[1].snapshot)
        #expect(acme.headline?.amount == Decimal(string: "412.345") && acme.money.map(\.id) == ["month", "today"])
        #expect(acme.fetchedAt == Date(timeIntervalSinceReferenceDate: 784_900_000))
        #expect(state.accounts[2].snapshot == nil, "a broken cost is dropped, the organisation kept")
    }

    /// Saved again, the state is in the new shape and reads back identically, with no trace of the old one.
    @Test func migratedStateSavesInTheNewShape() throws {
        let state = try #require(SavedState.load(Data(legacy.utf8)))
        let data = try JSONEncoder().encode(state)
        #expect(SavedState.load(data) == state)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"kind\"") && !text.contains("\"usage\"") && !text.contains("\"cost\""))
        #expect(text.contains("\"provider\":\"claude\""))
    }

    /// The real state.json, copied: set `TIDEMARK_TEST_STATE` to a copy of it (never the original) to check it
    /// migrates without losing an account.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TIDEMARK_TEST_STATE"] != nil))
    func aCopyOfTheRealStateMigrates() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TIDEMARK_TEST_STATE"])
        let data = try Data(contentsOf: URL(filePath: path))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let before = (raw?["accounts"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let state = try #require(SavedState.load(data))
        #expect(Set(state.accounts.map(\.id)) == Set(before), "every account survives, under its own id")
        #expect(state.accounts.allSatisfy { Registry.resolve($0) != nil }, "every account has a provider and login")
        #expect(SavedState.load(try JSONEncoder().encode(state)) == state)
    }
}

@Suite struct AuthTests {
    @Test func deviceCodes() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let code = try DeviceCode.decode(Data("""
            {"device_code":"d","user_code":"ABCD-EFGH","verification_uri":"https://example.com/device",
             "verification_uri_complete":"https://example.com/device?code=ABCD-EFGH","interval":7,"expires_in":600}
            """.utf8), now: now)
        #expect(code.userCode == "ABCD-EFGH" && code.interval == 7 && code.expiresAt == now + 600)
        #expect(code.completeURL?.query() == "code=ABCD-EFGH")
        #expect(throws: (any Error).self) {
            try DeviceCode.decode(Data(#"{"device_code":"d","user_code":"u","verification_uri":"http://example.com"}"#.utf8))
        }
        #expect(try DevicePoll.decode(status: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)) == .pending)
        #expect(try DevicePoll.decode(status: 400, body: Data(#"{"error":"slow_down"}"#.utf8)) == .slowDown)
        #expect(try DevicePoll.decode(status: 400, body: Data(#"{"error":"access_denied"}"#.utf8)) == .denied)
        #expect(try DevicePoll.decode(status: 400, body: Data(#"{"error":"expired_token"}"#.utf8)) == .expired)
        if case .approved(let credential) = try DevicePoll.decode(status: 200, body: Data(#"{"access_token":"t","refresh_token":"r"}"#.utf8)) {
            #expect(credential.secret == "t" && credential.refresh == "r")
        } else {
            Issue.record("an approved poll carries the credential")
        }
        #expect(throws: FetchFailure.server(500)) { try DevicePoll.decode(status: 500, body: Data()) }
    }

    @Test func secretForms() {
        let form = SecretForm(title: "t", intro: "i", fields: [
            .init(id: "key", label: "Key", kind: .secret), .init(id: "team", label: "Team", kind: .text, optional: true),
        ])
        #expect(SecretForm.clean(" sk-1\n23 ", secret: true) == "sk-123")
        #expect(SecretForm.clean("  Blue team ", secret: false) == "Blue team")
        #expect(form.credential(["key": "sk", "team": "blue"]) == Credential(secret: "sk", fields: ["team": "blue"]))
        #expect(form.credential(["key": "sk", "team": ""]) == Credential(secret: "sk"))
        #expect(Claude.keyForm.validate(["key": "sk-ant-api03-x"])?.contains("workspace") == true)
        #expect(Claude.keyForm.validate(["key": "sk-ant-admin01-x"]) == nil)
    }

    @Test func webCookies() {
        let web = WebLogin(start: URL(string: "https://example.com")!, cookie: "session", domain: "example.com")
        #expect(web.matches(name: "session", domain: ".example.com"))
        #expect(web.matches(name: "session", domain: "app.example.com"))
        #expect(!web.matches(name: "session", domain: "badexample.com"))
        #expect(!web.matches(name: "other", domain: "example.com"))
    }
}

/// Providers fetch through `HTTP` only: these run Claude's logins against canned answers.
@Suite struct FetchTests {
    func context(_ http: HTTP, secret: String = "token", now: Date = Date()) -> FetchContext {
        Canned.context(http, Credential(secret: secret), now: now)
    }

    @Test func claudeUsage() async throws {
        let recorder = Canned.Seen()
        let snapshot = try await Claude.account.fetch(context(Canned.http(#"{"five_hour":{"utilization":12}}"#, seen: recorder)))
        #expect(snapshot.meters.map(\.id) == ["session"] && snapshot.meters[0].percent == 12)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func statusesMapToFailures() async {
        await #expect(throws: FetchFailure.unauthorized) { try await Claude.account.fetch(context(Canned.http("", status: 401))) }
        await #expect(throws: FetchFailure.rateLimited(30)) {
            try await Claude.account.fetch(context(Canned.http("", status: 429, headers: ["Retry-After": "30"])))
        }
        await #expect(throws: FetchFailure.server(403), "a 403 from the usage endpoint is retried, not a refusal") {
            try await Claude.account.fetch(context(Canned.http("", status: 403)))
        }
        await #expect(throws: FetchFailure.forbidden) {
            try await Claude.console.identify(Credential(secret: "k"), Canned.http("", status: 403))
        }
        await #expect(throws: FetchFailure.unreadable) { try await Claude.account.fetch(context(Canned.http("{}"))) }
    }

    @Test func consoleCosts() async throws {
        let now = ISO8601.date("2026-11-12T15:00:00Z")!
        let recorder = Canned.Seen()
        let report = Canned.http(#"{"data":[{"starting_at":"2026-11-01T00:00:00Z","results":[{"amount":"1000","currency":"USD"}]},"#
                                     + #"{"starting_at":"2026-11-12T00:00:00Z","results":[{"amount":"250.5"}]}],"has_more":false}"#,
                                 seen: recorder)
        let snapshot = try await Claude.console.fetch(context(report, secret: "sk-ant-admin01-k", now: now))
        #expect(snapshot.headline?.amount == Decimal(string: "12.505") && snapshot.money.last?.amount == Decimal(string: "2.505"))
        let request = try #require(recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin01-k")
        #expect(request.url?.path() == "/v1/organizations/cost_report")
        let identity = try await Claude.console.identify(Credential(secret: "k"), Canned.http(#"{"id":"o-1","name":"Acme"}"#))
        #expect(identity == Identity(id: "o-1", name: "Acme") && Claude.console.accountID(identity.id) == "org-o-1")
    }
}
