import CryptoKit
import Foundation
import Testing
@testable import TidemarkCore

@Suite struct OAuthTests {
    @Test func pkceChallengeMatchesRFC7636Example() {
        let attempt = OAuthPKCE.Attempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomTokensAreURLSafeAndUnique() {
        let a = OAuth.randomToken(), b = OAuth.randomToken()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func onlyAnOAuthErrorRejectsTheGrant() {
        let oauth = Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8)
        let page = Data("<html>Access denied</html>".utf8)
        #expect(OAuth.rejectsGrant(status: 400, body: oauth))
        #expect(OAuth.rejectsGrant(status: 403, body: oauth))
        #expect(OAuth.rejectsGrant(status: 401, body: page))
        #expect(!OAuth.rejectsGrant(status: 403, body: page))
        #expect(!OAuth.rejectsGrant(status: 400, body: Data()))
        #expect(!OAuth.rejectsGrant(status: 500, body: oauth))
    }

    @Test func authorizeURL() throws {
        let attempt = OAuthPKCE.Attempt(verifier: "v", state: "st")
        let url = Claude.oauth.authorizeURL(attempt, redirect: "http://localhost:5000/callback", scope: "user:profile")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host() == "claude.com")
        #expect(query == ["code": "true", "client_id": Claude.oauth.clientID, "response_type": "code",
                          "redirect_uri": "http://localhost:5000/callback", "scope": "user:profile",
                          "code_challenge": attempt.challenge, "code_challenge_method": "S256", "state": "st"])
    }

    @Test func callback() {
        #expect(OAuth.callback(query: "code=abc&state=st", expecting: "st") == .code("abc"))
        #expect(OAuth.callback(query: "code=abc&state=other", expecting: "st") == .foreign)
        #expect(OAuth.callback(query: "code=abc", expecting: "st") == .foreign)
        #expect(OAuth.callback(query: nil, expecting: "st") == .foreign)
        #expect(OAuth.callback(query: "error=invalid_scope&state=st", expecting: "st") == .denied("invalid_scope"))
        #expect(OAuth.callback(query: "state=st", expecting: "st") == .denied("no_code"))
        #expect(OAuth.callback(query: "code=a%2Bb&state=st", expecting: "st") == .code("a+b"))
    }

    @Test func pasted() {
        #expect(OAuth.pasted("  abc#st\n", expecting: "st") == .code("abc"))
        #expect(OAuth.pasted("abc#nope", expecting: "st") == .foreign)
        #expect(OAuth.pasted("abc", expecting: "st") == .foreign)
        #expect(OAuth.pasted("#st", expecting: "st") == .foreign)
    }

    @Test func bodies() {
        let attempt = OAuthPKCE.Attempt(verifier: "ver", state: "st")
        #expect(Claude.oauth.exchangeBody(code: "c", attempt: attempt, redirect: "r") ==
                ["grant_type": "authorization_code", "code": "c", "state": "st", "client_id": Claude.oauth.clientID,
                 "redirect_uri": "r", "code_verifier": "ver"])
        #expect(Claude.oauth.refreshBody("rt") == ["grant_type": "refresh_token", "refresh_token": "rt",
                                                   "client_id": Claude.oauth.clientID])
        #expect(OAuth.form(["b": "x y", "a": "1&2"]) == "a=1%262&b=x%20y")
    }

    @Test func tokens() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let tokens = try OAuth.credential(Data(#"{"access_token":"a","refresh_token":"r","expires_in":28800,"token_type":"Bearer","scope":"user:profile","account":{"uuid":"u"}}"#.utf8), now: now)
        #expect(tokens == Credential(secret: "a", refresh: "r", expiresAt: now + 28800))
        #expect(!tokens.needsRefresh(now: now))
        #expect(tokens.needsRefresh(now: now + 28800 - 299))
        let rotated = try OAuth.credential(Data(#"{"access_token":"b","expires_in":10}"#.utf8), previousRefresh: "r", now: now)
        #expect(rotated.refresh == "r")
        #expect(throws: (any Error).self) { try OAuth.credential(Data(#"{"access_token":"b"}"#.utf8)) }
        #expect(throws: (any Error).self) { try OAuth.credential(Data(#"{"error":"invalid_grant"}"#.utf8)) }
    }

    @Test func profile() throws {
        let profile = try Profile.decode(Data("""
        {"account":{"uuid":"u-1","full_name":"Jane Doe","display_name":"Jane","email":"jane@example.com","has_claude_max":true},
         "organization":{"uuid":"o","name":"x"}}
        """.utf8))
        #expect(profile == Profile(id: "u-1", name: "Jane Doe", email: "jane@example.com"))
        let sparse = try Profile.decode(Data(#"{"account":{"uuid":"u-2","full_name":" ","display_name":null,"email_address":"alex@example.com"}}"#.utf8))
        #expect(sparse == Profile(id: "u-2", name: "alex@example.com", email: "alex@example.com"))
        #expect(throws: (any Error).self) { try Profile.decode(Data(#"{"account":{}}"#.utf8)) }
    }
}
