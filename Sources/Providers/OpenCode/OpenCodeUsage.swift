import Foundation

// OpenCode Go: `GET https://opencode.ai/zen/go/v1/usage` (undocumented), read leniently. It reports
// `usage.{rolling,weekly,monthly}`, each a percentage used, 0–100, when it resets, and a `status` of "ok" or
// "rate-limited". OpenCode's own client reads the same endpoint, with an API key or its sign-in.
enum OpenCodeUsage {
    /// The windows Tidemark shows, in the order the menu bar stacks them. Their raw values are the meters' ids and
    /// their keys in `usage`.
    enum Window: String, CaseIterable, Sendable {
        case rolling, weekly, monthly

        var title: String {
            switch self {
            case .rolling: "5-hour limit"
            case .weekly: "Weekly limit"
            case .monthly: "Monthly limit"
            }
        }
        var label: String {
            switch self {
            case .rolling: "5h"
            case .weekly: "w"
            case .monthly: "mo"
            }
        }
    }

    private static let percentKeys = ["percent", "usagePercent", "usedPercent", "percentUsed", "usage_percent", "used_percent"]
    private static let resetAtKeys = ["resetsAt", "resetAt", "resets_at", "reset_at", "nextReset", "next_reset"]
    private static let resetInKeys = ["resetInSec", "resetInSeconds", "reset_in_sec", "resetsInSec"]

    /// The snapshot: a meter per window reported. A response without any (no `usage`, or `usage: null`) is a key
    /// without a Go subscription.
    static func snapshot(_ data: Data, now: Date) throws -> Snapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchFailure.unreadable }
        let usage = root["usage"] as? [String: Any] ?? [:]
        let meters = Window.allCases.compactMap { window -> Meter? in
            guard let raw = usage[window.rawValue] as? [String: Any],
                  let percent = percentKeys.lazy.compactMap({ Wire.double(raw[$0]) }).first else { return nil }
            // A window OpenCode is holding back is full, whatever its rounded percentage says.
            let limited = (raw["status"] as? String)?.lowercased() == "rate-limited"
            return Meter(id: window.rawValue, title: window.title, label: window.label,
                         percent: limited ? max(percent, 100) : percent,
                         resetsAt: reset(raw, now: now), short: window == .rolling)
        }
        return Snapshot(meters: meters, plan: meters.isEmpty ? nil : "Go", note: meters.isEmpty ? Snapshot.noPlan : nil,
                        fetchedAt: now)
    }

    // Credits, from the Console's API: `GET /console/api/billing/status` and `/console/api/usage/summary?range=30d`.
    // Amounts are micro-cents, as strings or numbers: a dollar is 100,000,000.
    private static let microCentsPerDollar: Decimal = 100_000_000

    /// The credit balance left, for a prepaid pay-as-you-go workspace; nil for one billed otherwise, which has none.
    static func balance(_ data: Data) -> Decimal? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["billingMode"] as? String == "prepaid", root["mode"] as? String == "pay-as-you-go" else { return nil }
        return microCents(root["balanceMicroCents"])
    }

    /// What the last 30 days spent.
    static func spend(_ data: Data) -> Decimal? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return microCents(root["totalCostMicroCents"])
    }

    private static func microCents(_ value: Any?) -> Decimal? {
        let amount: Decimal? = switch value {
        case let text as String where text.wholeMatch(of: /-?[0-9]+/) != nil: Decimal(string: text)
        // A JSON true or false is no amount; Swift's `is Bool` would also take any 0 or 1.
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.decimalValue
        default: nil
        }
        return amount.map { $0 / microCentsPerDollar }
    }

    /// The credits as figures: the balance first, the menu bar's figure when there are no Go limits to draw.
    static func money(balance: Decimal?, spend: Decimal?, now: Date, headline: Bool) -> [Money] {
        var money: [Money] = []
        if let balance {
            money.append(Money(id: "balance", title: "Credit balance", role: .balance, amount: balance, currency: "USD",
                               headline: headline))
        }
        if let spend {
            money.append(Money(id: "spend", title: "Spent, last 30 days", amount: spend, currency: "USD",
                               headline: headline && balance == nil))
        }
        return money
    }

    /// When a window resets: a timestamp (ISO 8601, or epoch seconds or milliseconds), or seconds from now.
    static func reset(_ window: [String: Any], now: Date) -> Date? {
        if let date = resetAtKeys.lazy.compactMap({ Wire.date(window[$0]) }).first { return date }
        return resetInKeys.lazy.compactMap { Wire.double(window[$0]) }.first.map { now.addingTimeInterval(max($0, 0)) }
    }

    /// A refusal that names the account's plan rather than the key: a 403, which is how OpenCode answers for a
    /// workspace without Go, or OpenCode's JSON error (`{"type":"error","error":{"type":…,"message":…}}`) with a 402
    /// or 404; never an authentication error. A bare 404 (the endpoint gone) stays a server error.
    static func refusesForWantOfPlan(status: Int, body: Data) -> Bool {
        guard [402, 403, 404].contains(status) else { return false }
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return status == 403 }
        let error = root["error"] as? [String: Any]
        let text = [error?["type"], error?["message"], root["error"] as? String, root["message"]]
            .compactMap { $0 as? String }.joined(separator: " ").lowercased()
        guard !text.isEmpty else { return false }
        return !["auth", "credential", "unauthori", "api key", "invalid key"].contains { text.contains($0) }
    }
}
