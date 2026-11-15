import CryptoKit
import Foundation

/// Accounts added with a pasted key: a stable id and a hint for keys whose provider names no owner, the optional
/// field that names the account, and the region a key was issued for.
enum APIKey {
    /// A stable, non-reversible id: the start of the key's SHA-256, in hex. The same key added again is the same
    /// account. Never the key itself, nor enough of it to use.
    static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "Key …a1b2": its last four characters, as providers' own consoles show keys.
    static func hint(_ key: String) -> String { "Key …" + key.suffix(4) }

    /// The optional field of a key form that names the account.
    static let nameField = "name"

    static func nameInput(placeholder: String) -> SecretForm.Field {
        .init(id: nameField, label: "Name", placeholder: placeholder, kind: .text, optional: true)
    }

    /// The name the user gave the account, or `fallback`.
    static func name(_ credential: Credential, default fallback: String) -> String {
        credential.fields[nameField].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback
    }

    /// Where a key was issued, for providers that run an International and a China service with separate keys.
    enum Region: String, Sendable {
        case international, china

        init(_ credential: Credential) { self = Region(rawValue: credential.fields[Self.field] ?? "") ?? .international }

        static let field = "region"
        static let input = SecretForm.Field(id: field, label: "Region", kind: .choice([
            (Region.international.rawValue, "International"), (Region.china.rawValue, "China"),
        ]))
    }
}

extension LoginTexts {
    /// For a login added with a pasted key, named `noun` ("API key", "admin key"): a rejected key is re-entered, and
    /// removing the account leaves the key working until it is revoked in `console`. `costs` for logins that read
    /// costs rather than usage.
    static func key(_ noun: String = "API key", revokeIn console: String, forbidden: String = "This key can’t read its usage.",
                    costs: Bool = false) -> LoginTexts {
        LoginTexts(
            signedOut: "Key rejected. Re-enter the \(noun) to see \(costs ? "costs" : "usage").", signedOutShort: "Key rejected",
            reauthenticate: "Re-enter Key…", reauthenticateSpoken: "Re-enter the \(noun) for", forbidden: forbidden,
            removal: { _, _ in
                "Tidemark deletes this \(noun) from this Mac, and \(costs ? "its cached costs" : "its usage history"). "
                    + "The key itself still works: revoke it in \(console) if nothing else uses it."
            })
    }
}
