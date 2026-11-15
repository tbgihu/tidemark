import Foundation
import Testing
@testable import TidemarkCore

/// The store's logic against a stand-in for `/usr/bin/security` that models the facts it rests on: an item Tidemark
/// didn't write shares the name with its own and is never read, overwritten or deleted, and `-i` executes only the
/// first 4096 characters of a line. The real tool is in `RealKeychainTests`, against a throwaway keychain file.
@Suite struct KeychainTests {
    static let service = "io.github.tbgihu.tidemark.test"
    static let path = "/tmp/never-used.keychain-db"
    static let value = "s3cr3t-välue with spaces & symbols !@#\"\\ and\na newline"
    /// Well past one line, and not a multiple of any part size.
    static let long = String((0..<9001).map { $0 % 97 == 0 ? "ö" : Character(UnicodeScalar(0x41 + $0 % 26)!) })

    @Test func roundTrip() throws {
        let (store, tool) = FakeSecurity.store()
        #expect(try store.read("tokens") == nil)
        try store.write("tokens", "first")
        try store.write("tokens", Self.value)
        #expect(try store.read("tokens") == Self.value)
        let item = try #require(tool.items["tokens"])
        #expect(item.generic == SecretStore.marker)
        #expect(Data(base64Encoded: String(item.data.dropFirst(4))).map { String(decoding: $0, as: UTF8.self) } == Self.value)
        #expect(try store.delete("tokens"))
        #expect(try !store.delete("tokens"))
        #expect(try store.read("tokens") == nil)
    }

    @Test func theSecretIsNeverOnACommandLine() throws {
        let (store, tool) = FakeSecurity.store()
        try store.write("tokens", Self.value)
        try store.write("tokens", Self.long)
        let encoded = [Self.value, Self.long].map { Data($0.utf8).base64EncodedString() }
        for arguments in tool.calls.map(\.arguments) {
            #expect(!arguments.joined(separator: " ").contains(Self.value))
            #expect(!encoded.contains { secret in arguments.contains { $0.contains(secret.prefix(40)) } })
        }
        #expect(tool.calls.contains { $0.arguments == ["-i"] })
        #expect(!tool.calls.contains { $0.arguments.last == "-w" }, "-w as the last option reads 128 characters")
    }

    @Test(arguments: [nil, "secitem"]) func anItemTidemarkDidNotWriteIsNeverTouched(_ generic: String?) throws {
        let (store, tool) = FakeSecurity.store()
        tool.items["tokens"] = .init(generic: generic, data: "theirs")
        #expect(try store.read("tokens") == nil)
        #expect(try !store.delete("tokens"))
        #expect(throws: SecretError.foreign) { try store.write("tokens", "ours") }
        #expect(tool.items["tokens"] == .init(generic: generic, data: "theirs"))
        #expect(!tool.calls.contains { $0.arguments.contains("-w") }, "a data read would raise a dialog")
    }

    @Test func aLongSecretIsSplitSoNoLineIsCut() throws {
        let (store, tool) = FakeSecurity.store()
        try store.write("tokens", Self.long)
        #expect(tool.items["tokens"]?.data.hasPrefix("chunks:") == true)
        #expect(tool.parts.count > 1)
        #expect(try store.read("tokens") == Self.long)
        try store.write("tokens", "short again")
        #expect(tool.parts.isEmpty, "parts of the longer value outlived it")
        #expect(try store.read("tokens") == "short again")
        try store.write("tokens", Self.long)
        #expect(try store.delete("tokens"))
        #expect(tool.items.isEmpty)
    }

    @Test func everyLineFitsTheToolsBuffer() throws {
        let (store, tool) = FakeSecurity.store()
        for size in [1, 2900, 2950, 3000, 6000, 9001] {
            try store.write("tokens", String(repeating: "x", count: size))
            #expect(try store.read("tokens") == String(repeating: "x", count: size))
        }
        let lines = tool.calls.compactMap(\.input)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.utf8.count <= SecretStore.lineMax + 1 })   // the newline included
    }

    /// What the real tool does to an over-long line: it executes its first part, then the rest as another command.
    @Test func aTruncatedWriteIsCaughtAndNotKept() {
        let (store, tool) = FakeSecurity.store()
        tool.lineBuffer = 200
        #expect(throws: SecretError.self) { try store.write("tokens", String(repeating: "y", count: 300)) }
        #expect(tool.items.isEmpty)
    }

    /// A write that read back differently is removed, not kept damaged.
    @Test func aWriteThatDoesNotReadBackIsRemoved() {
        let (store, tool) = FakeSecurity.store()
        tool.lineBuffer = 200
        tool.quietTruncation = true
        #expect(throws: SecretError.unverified) { try store.write("tokens", String(repeating: "y", count: 300)) }
        #expect(tool.items.isEmpty)
    }

    @Test func aMissingOrAlteredPartIsAnErrorNotAShorterSecret() throws {
        let (store, tool) = FakeSecurity.store()
        try store.write("tokens", Self.long)
        tool.items["tokens#2"] = nil
        #expect(throws: SecretError.damaged) { try store.read("tokens") }
        try store.write("tokens", Self.long)
        tool.items["tokens#1"]?.data = "b64:" + Data("z".utf8).base64EncodedString()
        #expect(throws: SecretError.damaged) { try store.read("tokens") }
    }

    @Test func aValueWithoutTheEnvelopeIsDamaged() {
        let (store, tool) = FakeSecurity.store()
        tool.items["tokens"] = .init(generic: SecretStore.marker, data: "plain")
        #expect(throws: SecretError.damaged) { try store.read("tokens") }
    }

    @Test(arguments: ["add-generic-password", "find-generic-password", "delete-generic-password"])
    func aFailureOtherThanNotFoundThrows(_ command: String) throws {
        let (store, tool) = FakeSecurity.store()
        try store.write("tokens", "x")
        tool.failing = command
        #expect(throws: SecretError.self) {
            try store.write("tokens", "y")
            try store.delete("tokens")
        }
    }

    @Test func aNameThatCouldEscapeItsQuotesIsRefused() {
        let (store, _) = FakeSecurity.store()
        for account in ["a\"b", "a\\b", "a\nb", "a#1", ""] {
            #expect(throws: SecretError.badName) { try store.write(account, "x") }
        }
    }

    /// A locked keychain is never handed to the tool, which would ask for its password.
    @Test func aLockedKeychainRunsNothing() {
        let (store, tool) = FakeSecurity.store(unlocked: false)
        #expect(throws: SecretError.locked) { try store.read("tokens") }
        #expect(throws: SecretError.locked) { try store.write("tokens", "x") }
        #expect(throws: SecretError.locked) { try store.delete("tokens") }
        #expect(tool.calls.isEmpty)
    }

    @Test func noKeychainRunsNothing() {
        let tool = FakeSecurity()
        let store = SecretStore(service: Self.service, keychain: KeychainTarget(path: { nil }, isUnlocked: { _ in true }),
                                run: tool.run)
        #expect(throws: SecretError.locked) { try store.read("tokens") }
        #expect(tool.calls.isEmpty)
    }

    @Test func aCallThatNeverAnswersIsStopped() {
        let start = Date()
        #expect(throws: SecretError.timedOut) {
            try SecurityTool.run(["5"], input: nil, timeout: 0.2, executable: "/bin/sleep")
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func theGenericAttributeIsReadFromTheListing() {
        let listing = """
            keychain: "/x.keychain-db"
            attributes:
                "acct"<blob>="tokens"
                "gena"<blob>="tidemark:security"
            """
        #expect(SecretStore.generic(listing) == "tidemark:security")
        #expect(SecretStore.generic(#"    "gena"<blob>=<NULL>"#) == nil)
        #expect(SecretStore.generic("") == nil)
    }
}

/// A stand-in for `/usr/bin/security`: items by account under one service, each with its generic attribute.
final class FakeSecurity: @unchecked Sendable {
    struct Item: Equatable { var generic: String?; var data: String }
    struct Call { var arguments: [String]; var input: String? }

    var items: [String: Item] = [:]
    var calls: [Call] = []
    /// The tool's line buffer: a longer line is executed in pieces.
    var lineBuffer = 4096
    var failing: String?
    /// Drops the rest of a cut line instead of executing it, so the cut goes unreported.
    var quietTruncation = false
    private let lock = NSLock()

    var parts: [String] { items.keys.filter { $0.contains("#") }.sorted() }

    static func store(unlocked: Bool = true) -> (SecretStore, FakeSecurity) {
        let tool = FakeSecurity()
        let target = KeychainTarget(path: { KeychainTests.path }, isUnlocked: { _ in unlocked })
        return (SecretStore(service: KeychainTests.service, keychain: target, run: tool.run), tool)
    }

    func run(_ arguments: [String], _ input: String?) throws(SecretError) -> ToolResult {
        lock.withLock {
            calls.append(Call(arguments: arguments, input: input))
            guard arguments == ["-i"], let input else { return execute(arguments) }
            var status: Int32 = 0, error = ""
            for line in input.split(separator: "\n") {
                var rest = Substring(line)
                while !rest.isEmpty {
                    let piece = rest.prefix(lineBuffer - 1)
                    rest = quietTruncation ? "" : rest.dropFirst(piece.count)
                    let result = execute(Self.words(String(piece)))
                    if result.status != 0 { status = result.status; error += "\(piece.prefix(20)): returned \(result.status)\n" }
                }
            }
            return ToolResult(status: status, output: "", error: error)
        }
    }

    private func execute(_ words: [String]) -> ToolResult {
        guard let command = words.first else { return ToolResult(status: 0, output: "", error: "") }
        if command == failing { return ToolResult(status: 1, output: "", error: "failed") }
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 1
        while index < words.count {
            let word = words[index]
            if ["-w"].contains(word), command == "find-generic-password" { flags.insert(word); index += 1; continue }
            if word == "-U" { flags.insert(word); index += 1; continue }
            if word.hasPrefix("-"), index + 1 < words.count { options[word] = words[index + 1]; index += 2; continue }
            index += 1
        }
        guard options["-s"] == KeychainTests.service, let account = options["-a"] else {
            return ToolResult(status: 44, output: "", error: "not found")
        }
        switch command {
        case "find-generic-password":
            guard let item = items[account] else { return ToolResult(status: 44, output: "", error: "not found") }
            if flags.contains("-w") { return ToolResult(status: 0, output: item.data + "\n", error: "") }
            let generic = item.generic.map { "\"\($0)\"" } ?? "<NULL>"
            return ToolResult(status: 0, output: "attributes:\n    \"acct\"<blob>=\"\(account)\"\n    \"gena\"<blob>=\(generic)\n",
                              error: "")
        case "delete-generic-password":
            guard items.removeValue(forKey: account) != nil else { return ToolResult(status: 44, output: "", error: "") }
            return ToolResult(status: 0, output: "", error: "")
        case "add-generic-password":
            if items[account] != nil, !flags.contains("-U") { return ToolResult(status: 45, output: "", error: "exists") }
            // `-G` doesn't filter: an update replaces whatever item holds the name.
            items[account] = Item(generic: options["-G"], data: options["-w"] ?? "")
            return ToolResult(status: 0, output: "", error: "")
        default:
            return ToolResult(status: 1, output: "", error: "unknown command")
        }
    }

    /// The tool's own word splitting: spaces separate words, double quotes group them.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], word = "", quoted = false, started = false
        for character in line {
            if character == "\"" { quoted.toggle(); started = true; continue }
            if character == " ", !quoted {
                if started { words.append(word) }
                word = ""; started = false
                continue
            }
            word.append(character); started = true
        }
        if started { words.append(word) }
        return words
    }
}
