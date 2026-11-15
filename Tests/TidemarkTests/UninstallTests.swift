import Foundation
import Testing
@testable import TidemarkCore

/// `make uninstall` deletes Tidemark's Keychain items itself when the app is already gone, from a list in
/// scripts/lib.sh: it must name every item a provider writes.
@Suite struct UninstallTests {
    @Test func scriptKnowsEveryKeychainItem() throws {
        let lib = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/lib.sh")
        let text = try String(contentsOf: lib, encoding: .utf8)
        let list = try #require(text.firstMatch(of: /readonly secret_items=\(([^)]*)\)/)).1
        let listed = Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
        let written = Set(Registry.secretItems.filter { !$0.hasPrefix("example-") })
        #expect(listed == written, "missing: \(written.subtracting(listed).sorted()), extra: \(listed.subtracting(written).sorted())")
    }
}
