import Foundation

/// Cursor: an account signed in on cursor.com inside Tidemark (its `WorkosCursorSessionToken` cookie, in a data store of
/// the account's own), whose plan usage and on-demand spending Tidemark shows. Tidemark never reads the Cursor app's
/// or a browser's session.
enum Cursor {
    static let id = "cursor"

    static let provider = Provider(
        id: id, name: "Cursor", company: "Cursor", brandColor: BrandColor(hex: 0x6F86A6),
        // The dashboard's figures settle over minutes; polling it faster only invites rate limits.
        order: Registry.order(of: id), recommendedMinimumInterval: 600, logins: [account])

    static let base = URL(string: "https://cursor.com")!

    static let web = WebLogin(
        start: base.appending(path: "dashboard"), cookie: "WorkosCursorSessionToken", domain: "cursor.com",
        note: "Sign in with your email address or GitHub. Google may refuse to sign in inside an app; if it does, "
            + "use your Cursor account’s email address instead.")

    static let account = Login(
        id: "account", title: "Cursor Account", subtitle: "Sign in on cursor.com to see its usage",
        symbol: "person.crop.circle", auth: .web(web), secretItem: "cursor-sessions",
        history: .meters([ChartedMeter(id: "plan", label: "included", title: "Included usage")]),
        texts: LoginTexts(
            signedOut: "Session expired. Sign in again to see usage.",
            forbidden: "Session expired. Sign in again to see usage.",
            removal: { _, email in
                "Tidemark signs out of \(email) on this Mac and deletes its usage history. Your Cursor account isn’t affected."
            }),
        accountID: { "cursor-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            // Signed out, `/api/auth/me` answers 204 with nothing: no one to identify yet.
            let user = try await http.decode(request("api/auth/me", credential)) { try CursorUser.decode($0) }
            guard let user else { throw .unauthorized }
            return Identity(id: user.id, name: user.name, email: user.email)
        },
        fetch: { context throws(FetchFailure) in
            try await context.http.decode(request("api/usage-summary", context.credential)) {
                try CursorUsage.decode($0).snapshot(fetchedAt: context.now)
            }
        })

    /// A request with the session cookie. A 401 or 403 means the session is over: only signing in again helps.
    static func request(_ path: String, _ credential: Credential) -> URLRequest {
        URLRequest(base.appending(path: path), headers: ["Cookie": "\(web.cookie)=\(credential.secret)"])
    }
}

/// Who is signed in, from `GET /api/auth/me`; nil when no one is (an empty body, or no id).
struct CursorUser: Equatable, Sendable {
    let id: String
    let name: String
    let email: String

    static func decode(_ data: Data) throws -> CursorUser? {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        struct Raw: Decodable {
            let sub: String?
            let email: String?
            let name: String?
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                sub = try? c.decodeIfPresent(String.self, forKey: .sub)
                email = try? c.decodeIfPresent(String.self, forKey: .email)
                name = try? c.decodeIfPresent(String.self, forKey: .name)
            }
            enum Keys: String, CodingKey { case sub, email, name }
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        func clean(_ text: String?) -> String { text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let id = clean(raw.sub), email = clean(raw.email)
        guard !id.isEmpty else { return nil }
        let name = clean(raw.name)
        return CursorUser(id: id, name: name.isEmpty ? (email.isEmpty ? "Cursor account" : email) : name, email: email)
    }
}
