import Foundation

/// An account in state.json as written before providers existed: always Claude, a `kind` ("subscription", the
/// default, or "organization"), and its data as Claude's `usage` or an organisation's `cost`. Read once, when such a
/// state is loaded; the account is saved in the provider-neutral shape from then on. Its id, and so its Keychain
/// entry, history file and notification state, stays as it was.
struct ClaudeState: Decodable {
    let login: String
    let snapshot: Snapshot?

    private enum Keys: String, CodingKey { case kind, usage, cost }

    /// A kind this build doesn't know isn't guessed at: the account is skipped.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "subscription" {
        case "subscription":
            login = Claude.account.id
            snapshot = (try? c.decodeIfPresent(Usage.self, forKey: .usage))?.snapshot
        case "organization":
            login = Claude.console.id
            snapshot = (try? c.decodeIfPresent(Summary.self, forKey: .cost))?.snapshot
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown account kind")
        }
    }

    /// An organisation's month to date and today so far, in cents, as of a fetch.
    struct Summary: Decodable {
        var month: Cents
        var today: Cents
        /// The start of the UTC month and day the amounts are for.
        var monthStart: Date
        var todayStart: Date
        var fetchedAt: Date

        var snapshot: Snapshot {
            Snapshot(money: CostLedger.figures(month: month.value, today: today.value, monthStart: monthStart, day: todayStart),
                     fetchedAt: fetchedAt)
        }
    }
}
