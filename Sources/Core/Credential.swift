import Foundation

/// What Tidemark keeps to read an account: a token or key, and for OAuth its refresh token and expiry, plus any
/// extra fields a sign-in asked for (a team id, a region). Kept only in the Keychain (`SecretStore`), never logged.
///
/// Stored as the value types that came before it did: a bare secret as a JSON string, and an OAuth grant as
/// `{"access":…,"refresh":…,"expiresAt":…}`, so every Keychain item reads back as it was written.
struct Credential: Codable, Equatable, Sendable {
    var secret: String
    var refresh: String?
    var expiresAt: Date?
    var fields: [String: String]

    init(secret: String, refresh: String? = nil, expiresAt: Date? = nil, fields: [String: String] = [:]) {
        self.secret = secret
        self.refresh = refresh
        self.expiresAt = expiresAt
        self.fields = fields
    }

    /// Refresh a few minutes early, so a request never races the expiry. Only a credential with a refresh token can.
    func needsRefresh(now: Date = Date()) -> Bool {
        guard refresh != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 300
    }

    private enum Keys: String, CodingKey { case access, refresh, expiresAt, fields }

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let secret = try? single.decode(String.self) {
            self.init(secret: secret)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(secret: try c.decode(String.self, forKey: .access),
                  refresh: try c.decodeIfPresent(String.self, forKey: .refresh),
                  expiresAt: try c.decodeIfPresent(Date.self, forKey: .expiresAt),
                  fields: (try? c.decodeIfPresent([String: String].self, forKey: .fields)) ?? [:])
    }

    func encode(to encoder: any Encoder) throws {
        if refresh == nil, expiresAt == nil, fields.isEmpty {
            var single = encoder.singleValueContainer()
            try single.encode(secret)
            return
        }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(secret, forKey: .access)
        try c.encodeIfPresent(refresh, forKey: .refresh)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        if !fields.isEmpty { try c.encode(fields, forKey: .fields) }
    }
}
