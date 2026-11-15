import Foundation

/// How close a meter is to running out: a bar is drawn in the neutral foreground colour, then orange, then red.
///
/// A provider that grades its limits itself (Claude's usage endpoint sends "normal", "warning" or "critical") is
/// shown as graded rather than worked out again. Only a meter the server didn't grade, or graded with a word
/// Tidemark doesn't know, is graded from its percentage: a warning above 75 %, critical above 95 % or once used up,
/// the thresholds Claude's own clients use for an ungraded limit.
enum Severity: Int, Comparable, Codable, CaseIterable, Sendable {
    case normal, warning, critical

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    /// Above this percentage, a limit is a warning.
    static let warningAbove = 75.0
    /// Above this percentage, or at 100, a limit is critical.
    static let criticalAbove = 95.0

    /// The grade for `percent` used, when the server gave none.
    init(percent: Double) {
        if percent > Self.criticalAbove || percent >= 100 {
            self = .critical
        } else if percent > Self.warningAbove {
            self = .warning
        } else {
            self = .normal
        }
    }

    /// The server's grade, or nil for a missing or unrecognised one. Beyond the three words seen, a word that says
    /// the limit is used up or blocking ("exceeded", "error", "blocked"…) is critical, and one that says it is getting
    /// close ("caution", "high"…) is a warning: a new word should never make a bar look calmer than it is.
    init?(server: String?) {
        guard let word = server?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !word.isEmpty else {
            return nil
        }
        switch word {
        case "normal", "ok", "low", "none", "info", "good", "healthy": self = .normal
        case "warning", "warn", "caution", "elevated", "high", "approaching", "near_limit": self = .warning
        case "critical", "severe", "danger", "error", "exceeded", "limited", "rate_limited", "blocked",
             "rejected", "exhausted", "maxed", "over_limit", "at_limit":
            self = .critical
        default: return nil
        }
    }

    /// The grade to show: the server's when it gave one Tidemark understands, otherwise from the percentage.
    init(server: String?, percent: Double) {
        self = Severity(server: server) ?? Severity(percent: percent)
    }

    /// For VoiceOver and other places where colour can't carry it: nil when normal.
    var spoken: String? {
        switch self {
        case .normal: nil
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}
