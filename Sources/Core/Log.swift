import Foundation
import os

/// Unified logging, under the bundle identifier. Everything is `.debug` or `.info`, so it costs nothing unless
/// streamed: `log stream --predicate 'subsystem == "io.github.tbgihu.tidemark"' --level debug`. Never log a token, a
/// key, an email or a response body; account ids are `.private`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.tbgihu.tidemark"
    /// Requests and their outcomes: status, Retry-After, the backoff chosen.
    static let fetch = Logger(subsystem: subsystem, category: "fetch")
    /// Token refreshes.
    static let auth = Logger(subsystem: subsystem, category: "auth")
    /// When the next refresh is due, pauses and resumes.
    static let schedule = Logger(subsystem: subsystem, category: "schedule")
    /// Keychain reads and writes, by status code only.
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
}
