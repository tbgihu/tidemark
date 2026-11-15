import CryptoKit
import Foundation
import Security

/// Tidemark's secrets, as generic-password items that only Apple's `/usr/bin/security` creates, reads and deletes.
///
/// **Why the tool.** An item made through the Security framework is tied to the creating app's code identity. A
/// locally signed Tidemark has no Apple team, so that identity is its exact build, and every rebuild or update would
/// ask for the login password. An item `security` creates names `/usr/bin/security` in its access list instead, so
/// any build reads it without a dialog. The cost: any process of this user can read it the same way (SECURITY.md).
///
/// **No secret on a command line.** `security -i` reads commands from standard input, so the value travels in an
/// `add-generic-password` line on a pipe. Two measured traps, both silent:
///
/// - `-i` reads a line into a 4096-byte buffer and EXECUTES a longer one cut in two: the first 4096 bytes, then the
///   rest as another command (the keychain is the line's last word, so a cut line writes to the default keychain).
///   Every line is held to `lineMax`; a longer value is split over `<account>#1…n` behind a checksummed header, and
///   every write is read back.
/// - `-w` as the last option, reading the value from standard input, keeps only 128 characters. It is never used.
///
/// Values are stored as `b64:<base64 of the UTF-8>`, since `-w` prints a value that isn't printable ASCII as hex.
///
/// Every item carries `marker` in its generic attribute, checked from the attributes alone (`-G` doesn't filter),
/// which raises no dialog: an item Tidemark didn't write under the same name is never read, overwritten or deleted.
///
/// A locked keychain is never handed to the tool, which would ask for its password: every call checks the lock state
/// first, in process, and fails with `.locked`. Every call blocks for at most `timeout`: run it off the main thread.
struct SecretStore: Sendable {
    static let tool = "/usr/bin/security"
    static let marker = "tidemark:security"
    static let envelope = "b64:"
    /// A value too long for one line: `<account>` holds `chunks:<n>:<sha256 of the UTF-8>`, and the value is in
    /// `<account>#1` … `<account>#n`, each the envelope of consecutive bytes.
    static let chunked = "chunks:"
    static let part = "#"
    /// `security -i`'s line buffer is 4096 bytes, the newline included.
    static let lineMax = 4095
    /// The tool's exit status for "no such item" (errSecItemNotFound).
    static let notFound: Int32 = 44

    typealias Run = @Sendable (_ arguments: [String], _ input: String?) throws(SecretError) -> ToolResult

    let service: String
    let keychain: KeychainTarget
    /// The one door to the tool, which the tests replace.
    let run: Run

    init(service: String, keychain: KeychainTarget, timeout: TimeInterval = 10, run: Run? = nil) {
        self.service = service
        self.keychain = keychain
        if let run {
            self.run = run
        } else {
            self.run = { (arguments: [String], input: String?) throws(SecretError) -> ToolResult in
                try SecurityTool.run(arguments, input: input, timeout: timeout)
            }
        }
    }

    // MARK: Reading, writing, deleting

    /// The stored secret, or nil when Tidemark stored none under `account` (or the item there isn't Tidemark's).
    func read(_ account: String) throws(SecretError) -> String? {
        let path = try unlockedKeychain()
        try checkNames(account, path)
        guard try owner(account, path) == true, let stored = try fetch(account, path) else { return nil }
        let data: Data
        if !stored.hasPrefix(Self.chunked) {
            data = try unwrap(stored)
        } else {
            let fields = stored.dropFirst(Self.chunked.count).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, let count = Int(fields[0]), count > 0, count < 1000 else { throw .damaged }
            var joined = Data()
            for index in 1...count {
                let name = "\(account)\(Self.part)\(index)"
                guard try owner(name, path) == true, let piece = try fetch(name, path) else { throw .damaged }
                joined += try unwrap(piece)
            }
            guard Self.digest(joined) == fields[1] else { throw .damaged }
            data = joined
        }
        guard let value = String(data: data, encoding: .utf8) else { throw .damaged }
        return value
    }

    /// Stores (or replaces) a secret, then reads it back: afterwards exactly `value` is stored, or this throws and
    /// nothing of it stays.
    func write(_ account: String, _ value: String) throws(SecretError) {
        let path = try unlockedKeychain()
        try checkNames(account, path)
        if try owner(account, path) == false { throw .foreign }
        do {
            try replace(account, path, value)
        } catch .foreign {
            throw .foreign
        } catch {
            _ = try? delete(account)                    // a half-written value is worse than none
            try? dropParts(account, path, keeping: 0)   // parts written before the header was
            throw error
        }
    }

    private func replace(_ account: String, _ path: String, _ value: String) throws(SecretError) {
        let data = Data(value.utf8)
        let single = Self.envelope + data.base64EncodedString()
        if Self.line(account: account, service: service, keychain: path, value: single).utf8.count <= Self.lineMax {
            try store(account, path, single)
            try dropParts(account, path, keeping: 0)
        } else {
            let parts = try parts(account, path, data)
            for (offset, part) in parts.enumerated() {
                let name = "\(account)\(Self.part)\(offset + 1)"
                if try owner(name, path) == false { throw .foreign }
                try store(name, path, Self.envelope + part.base64EncodedString())
            }
            // The header last, so a reader never finds a header whose parts aren't all written.
            try store(account, path, "\(Self.chunked)\(parts.count):\(Self.digest(data))")
            try dropParts(account, path, keeping: parts.count)
        }
        let back: String?
        do { back = try read(account) } catch { back = nil }
        guard back == value else { throw .unverified }
    }

    /// Deletes a secret. Returns whether there was one: false when Tidemark stored none under `account`.
    @discardableResult
    func delete(_ account: String) throws(SecretError) -> Bool {
        let path = try unlockedKeychain()
        try checkNames(account, path)
        guard try owner(account, path) == true else { return false }
        try remove(account, path)
        try dropParts(account, path, keeping: 0)
        return true
    }

    // MARK: The tool

    /// The keychain's path when it is unlocked. A locked keychain, or one that can't be found, is never handed to
    /// the tool, which would ask for its password.
    private func unlockedKeychain() throws(SecretError) -> String {
        guard let path = keychain.path(), keychain.isUnlocked(path) else { throw .locked }
        return path
    }

    /// Whose item is under `account`: nil none, true Tidemark's, false somebody else's. Attributes only, no data, so
    /// no dialog.
    private func owner(_ account: String, _ path: String) throws(SecretError) -> Bool? {
        let result = try call(path, ["find-generic-password", "-s", service, "-a", account, path])
        if result.status == Self.notFound { return nil }
        guard result.status == 0 else { throw .failed(result.status) }
        return Self.generic(result.output) == Self.marker
    }

    private func fetch(_ account: String, _ path: String) throws(SecretError) -> String? {
        let result = try call(path, ["find-generic-password", "-s", service, "-a", account, "-w", path])
        if result.status == Self.notFound { return nil }
        guard result.status == 0 else { throw .failed(result.status) }
        return result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
    }

    /// One item, one line on standard input. `value` is printable ASCII (an envelope or a header).
    private func store(_ account: String, _ path: String, _ value: String) throws(SecretError) {
        let line = Self.line(account: account, service: service, keychain: path, value: value)
        guard line.utf8.count <= Self.lineMax else { throw .tooLong }      // never reached through write
        let result = try call(path, ["-i"], input: line + "\n")
        // `-i`'s exit status isn't always the command's: a failed command says "returned <status>".
        guard result.status == 0, !result.output.contains("returned"), !result.error.contains("returned") else {
            throw .failed(result.status == 0 ? 1 : result.status)
        }
    }

    private func remove(_ account: String, _ path: String) throws(SecretError) {
        let result = try call(path, ["delete-generic-password", "-s", service, "-a", account, path])
        guard result.status == 0 || result.status == Self.notFound else { throw .failed(result.status) }
    }

    /// Deletes Tidemark's parts beyond `keeping`. They are contiguous, so the first absent one ends it.
    private func dropParts(_ account: String, _ path: String, keeping: Int) throws(SecretError) {
        var index = keeping + 1
        while try owner("\(account)\(Self.part)\(index)", path) == true {
            try remove("\(account)\(Self.part)\(index)", path)
            index += 1
        }
    }

    /// Checked again just before every run: the keychain may have locked since.
    private func call(_ path: String, _ arguments: [String], input: String? = nil) throws(SecretError) -> ToolResult {
        guard keychain.isUnlocked(path) else { throw .locked }
        return try run(arguments, input)
    }

    /// `data` split so that every part's line fits, the longest part name counted.
    private func parts(_ account: String, _ path: String, _ data: Data) throws(SecretError) -> [Data] {
        var count = 1
        while true {
            let empty = Self.line(account: "\(account)\(Self.part)\(count)", service: service, keychain: path,
                                  value: Self.envelope)
            let perPart = (Self.lineMax - empty.utf8.count) / 4 * 3          // base64: 4 characters per 3 bytes
            guard perPart > 0 else { throw .tooLong }
            if count * perPart >= data.count {
                return stride(from: 0, to: data.count, by: perPart).map { data.subdata(in: $0..<min($0 + perPart, data.count)) }
            }
            count += 1
        }
    }

    /// Names are put in the tool's quotes on a line it parses: nothing that could leave them is let in.
    private func checkNames(_ account: String, _ path: String) throws(SecretError) {
        let names = account + service + path
        guard !account.isEmpty, !account.contains(Self.part),
              !names.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7f })
        else { throw .badName }
    }

    private func unwrap(_ stored: String) throws(SecretError) -> Data {
        guard stored.hasPrefix(Self.envelope),
              let data = Data(base64Encoded: String(stored.dropFirst(Self.envelope.count))) else { throw .damaged }
        return data
    }

    static func line(account: String, service: String, keychain: String, value: String) -> String {
        "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -l \"Tidemark\" -G \(marker) -w \(value) \"\(keychain)\""
    }

    /// The generic attribute in `find-generic-password`'s listing: `"gena"<blob>="…"`.
    static func generic(_ listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("\"gena\"<blob>=") else { continue }
            let value = trimmed.dropFirst("\"gena\"<blob>=".count)
            guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a secret couldn't be read, written or deleted. Never carries a secret.
enum SecretError: Error, Equatable, Sendable {
    /// The keychain is locked (or there is none): nothing was run.
    case locked
    /// The tool didn't answer in time and was stopped.
    case timedOut
    /// An item Tidemark didn't write holds the name.
    case foreign
    /// Tidemark's item is there but isn't readable as Tidemark wrote it.
    case damaged
    /// A write didn't read back as written, so it was removed rather than kept damaged.
    case unverified
    case tooLong
    case badName
    /// The tool failed (its exit status), or couldn't be started (-1).
    case failed(Int32)
}

/// What one run of the tool gave back.
struct ToolResult: Sendable {
    var status: Int32
    var output: String
    var error: String
}

/// Which keychain file the items are in, and whether it is unlocked right now.
struct KeychainTarget: Sendable {
    /// The keychain's path; nil when there is none.
    let path: @Sendable () -> String?
    let isUnlocked: @Sendable (String) -> Bool

    /// The user's default keychain, the login keychain: where Tidemark's items are.
    static let login = KeychainTarget(path: { files.defaultPath() }, isUnlocked: { files.isUnlocked($0) })

    /// A keychain file named explicitly: the tests' throwaway one.
    static func file(_ path: String) -> KeychainTarget {
        KeychainTarget(path: { path }, isUnlocked: { files.isUnlocked($0) })
    }

    static let files: any KeychainFiles = LegacyKeychainFiles()
}

/// The keychain-file calls, deprecated with SecKeychain but the only ones that tell whether a keychain is locked
/// without unlocking it or asking. Called through a protocol so the deprecation is stated once, here.
protocol KeychainFiles: Sendable {
    func defaultPath() -> String?
    func isUnlocked(_ path: String) -> Bool
}

struct LegacyKeychainFiles: KeychainFiles {
    @available(macOS, deprecated: 10.10)
    func defaultPath() -> String? {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return nil }
        var length = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Unlocked, as its status says. Neither unlocks nor asks; a keychain whose status can't be read (missing, say)
    /// counts as locked, so the tool is never sent to it.
    @available(macOS, deprecated: 10.10)
    func isUnlocked(_ path: String) -> Bool {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return false }
        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        return SecKeychainGetStatus(keychain, &status) == errSecSuccess && status & SecKeychainStatus(kSecUnlockStateStatus) != 0
    }
}
