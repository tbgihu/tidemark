import Foundation

// Copilot quotas: `GET /copilot_internal/user` (undocumented; what GitHub's own editor extensions read), read
// leniently. Paid plans report `quota_snapshots`; the Free plan may instead report its monthly allowance in
// `monthly_quotas` and what is left in `limited_user_quotas`, resetting on `limited_user_reset_date`.
enum CopilotUsage {
    /// The quotas Tidemark shows, in the order the menu bar stacks them. Their raw values are the meters' ids.
    enum Quota: String, CaseIterable, Sendable {
        case premium, chat, completions

        /// The key in `quota_snapshots`, `monthly_quotas` and `limited_user_quotas`.
        var key: String { self == .premium ? "premium_interactions" : rawValue }
        var title: String {
            switch self {
            case .premium: "Premium requests"
            case .chat: "Chat"
            case .completions: "Code completions"
            }
        }
        /// The menu bar's row label: every quota is monthly, and premium requests are the one that matters.
        var label: String {
            switch self {
            case .premium: "mo"
            case .chat: "chat"
            case .completions: "code"
            }
        }
        var chartLabel: String {
            switch self {
            case .premium: "premium"
            case .chat: "chat"
            case .completions: "code"
            }
        }
        var noun: String {
            switch self {
            case .premium: "Premium request quota"
            case .chat: "Chat quota"
            case .completions: "Code completion quota"
            }
        }
    }

    private static let knownKeys = ["copilot_plan", "access_type_sku", "quota_snapshots", "monthly_quotas",
                                    "limited_user_quotas", "quota_reset_date", "limited_user_reset_date"]

    /// The snapshot: a meter per limited quota (unlimited ones and placeholders are left out), and the plan.
    static func snapshot(_ data: Data, now: Date) throws -> Snapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              knownKeys.contains(where: { root[$0] != nil }) else { throw FetchFailure.unreadable }
        if (root["access_type_sku"] as? String)?.lowercased() == "subscription_ended" {
            return Snapshot(note: Snapshot.noPlan, fetchedAt: now)
        }
        let reset = date(root["quota_reset_date"]) ?? date(root["quota_reset_date_utc"]) ?? date(root["limited_user_reset_date"])
        let snapshots = root["quota_snapshots"] as? [String: Any]
        let monthly = root["monthly_quotas"] as? [String: Any], left = root["limited_user_quotas"] as? [String: Any]
        let meters = Quota.allCases.compactMap { quota -> Meter? in
            guard let used = usedPercent(snapshots?[quota.key]) ?? freeUsedPercent(total: monthly?[quota.key], left: left?[quota.key])
            else { return nil }
            return Meter(id: quota.rawValue, title: quota.title, label: quota.label, noun: quota.noun, percent: used, resetsAt: reset)
        }
        return Snapshot(meters: meters, plan: plan(root["copilot_plan"]), fetchedAt: now)
    }

    /// A quota snapshot's share used: 100 − `percent_remaining`, or from `remaining` of `entitlement` without it.
    /// Unlimited quotas, and the zero-entitlement placeholders of token-billed seats, have none. Over 100 when an
    /// overage is allowed and used.
    static func usedPercent(_ value: Any?) -> Double? {
        guard let quota = value as? [String: Any], (quota["unlimited"] as? Bool) != true else { return nil }
        let entitlement = Wire.double(quota["entitlement"]), remaining = Wire.double(quota["remaining"])
        if entitlement == 0, remaining == 0 { return nil }
        if let percent = Wire.double(quota["percent_remaining"]) { return max(100 - percent, 0) }
        guard let entitlement, entitlement > 0, let remaining else { return nil }
        return max(100 - remaining / entitlement * 100, 0)
    }

    /// The Free plan's share used: what is left of the monthly allowance.
    static func freeUsedPercent(total: Any?, left: Any?) -> Double? {
        guard let total = Wire.double(total), total > 0, let left = Wire.double(left) else { return nil }
        return min(max(100 - left / total * 100, 0), 100)
    }

    /// GitHub's plan ids, as its billing pages name them.
    static func plan(_ value: Any?) -> String? {
        guard let id = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty, id != "unknown"
        else { return nil }
        switch id {
        case "free", "free_limited_copilot": return "Free"
        case "individual", "pro": return "Pro"
        case "individual_pro", "pro_plus", "pro+": return "Pro+"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return id.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    /// An ISO 8601 timestamp, or a bare day (`2026-12-01`, midnight UTC).
    static func date(_ value: Any?) -> Date? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        if let date = ISO8601.date(string) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month().day())
    }
}
