import Foundation
import Testing
@testable import TidemarkCore

/// The store against the real `/usr/bin/security`, only when `TIDEMARK_TEST_KEYCHAIN` names a throwaway keychain
/// FILE, unlocked, made for the purpose (never the login keychain, never one in ~/Library/Keychains). Every call is
/// bounded, so a dialog would fail the test instead of waiting for someone.
private let throwawayKeychain: String? = {
    guard let path = ProcessInfo.processInfo.environment["TIDEMARK_TEST_KEYCHAIN"], path.hasSuffix(".keychain-db"),
          !path.contains("/Library/Keychains/") else { return nil }
    return path
}()

@Suite(.enabled(if: throwawayKeychain != nil), .serialized)
struct RealKeychainTests {
    static let path = throwawayKeychain

    static let service = "io.github.tbgihu.tidemark.test"
    let store = SecretStore(service: Self.service, keychain: .file(Self.path ?? ""), timeout: 15)

    private func tool(_ arguments: String...) throws -> ToolResult {
        try SecurityTool.run(arguments + [Self.path!], input: nil, timeout: 15)
    }

    private func wipe() throws {
        for account in ["roundtrip", "long", "foreign"] {
            for name in [account] + (1...8).map({ "\(account)#\($0)" }) {
                _ = try tool("delete-generic-password", "-s", Self.service, "-a", name)
            }
        }
    }

    @Test func roundTrip() throws {
        try wipe()
        defer { try? wipe() }
        #expect(try store.read("roundtrip") == nil)
        try store.write("roundtrip", "first")
        try store.write("roundtrip", KeychainTests.value)
        #expect(try store.read("roundtrip") == KeychainTests.value)
        #expect(try tool("find-generic-password", "-s", Self.service, "-a", "roundtrip", "-w").output.hasPrefix("b64:"))
        #expect(try store.delete("roundtrip"))
        #expect(try store.read("roundtrip") == nil)
        #expect(try !store.delete("roundtrip"))
    }

    /// Over 4 KB, so over one `-i` line: split, and read back whole.
    @Test func aLongSecretRoundTripsInParts() throws {
        try wipe()
        defer { try? wipe() }
        try store.write("long", KeychainTests.long)
        #expect(try tool("find-generic-password", "-s", Self.service, "-a", "long#2").status == 0)
        #expect(try store.read("long") == KeychainTests.long)
        try store.write("long", "short")
        #expect(try tool("find-generic-password", "-s", Self.service, "-a", "long#1").status == SecretStore.notFound)
        try store.write("long", KeychainTests.long)
        #expect(try store.delete("long"))
        for name in ["long", "long#1", "long#2"] {
            #expect(try tool("find-generic-password", "-s", Self.service, "-a", name).status == SecretStore.notFound)
        }
    }

    /// The claim the marker rests on: a data read here would raise a dialog and run into the timeout.
    @Test func anItemWrittenByHandIsNeverTouched() throws {
        try wipe()
        defer { try? wipe() }
        #expect(try tool("add-generic-password", "-a", "foreign", "-s", Self.service, "-w", "pässwörd").status == 0)
        #expect(try store.read("foreign") == nil)
        #expect(try !store.delete("foreign"))
        #expect(throws: SecretError.foreign) { try store.write("foreign", "ours") }
        // Printed as hex: the ambiguity the `b64:` envelope removes. (Process passes arguments decomposed, as file
        // names are: one more reason a secret never travels as one.)
        let raw = try tool("find-generic-password", "-s", Self.service, "-a", "foreign", "-w").output
        let hex = Data("pässwörd".decomposedStringWithCanonicalMapping.utf8).map { String(format: "%02x", $0) }.joined()
        #expect(raw.trimmingCharacters(in: .newlines) == hex)
    }
}
