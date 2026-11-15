import Foundation

// agy's answers with `--output-format json`, read leniently. `/usage`: `command.data.groups`, each a `name` ("Gemini
// Models", "Claude and GPT models") and `buckets`, each an `id` ("gemini-5h"), a `window` ("5h", "weekly"), a
// `remaining_fraction` (0–1) and a `reset_time`. `/credits`: `command.data.remaining_credits`. Both have `status`
// "SUCCESS" and no model turns (`num_turns` 0).
enum AntigravityUsage {
    /// The limits, a meter per bucket: each group's 5-hour and weekly limits, the first group's (Gemini's) first, then
    /// the others' weekly limits before their 5-hour ones, so the menu bar's three rows hold Gemini's two and the
    /// weekly limit of the rest.
    static func meters(_ data: Data) throws(FetchFailure) -> [Meter] {
        guard let groups = answer(data, command: "usage")?["groups"] as? [[String: Any]] else { throw .unreadable }
        var first: [Meter] = [], rest: [Meter] = [], restShort: [Meter] = []
        for (index, group) in groups.enumerated() {
            let name = (group["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let tag = name.first.map { "(\($0.uppercased()))" } ?? ""
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["id"] as? String, !id.isEmpty,
                      let remaining = Wire.double(bucket["remaining_fraction"]) else { continue }
                let window = (bucket["window"] as? String)?.lowercased() ?? ""
                let short = window.hasSuffix("h")
                let label = (short ? window : window == "weekly" ? "w" : String(window.prefix(2))) + tag
                let limit = short ? "\(window.dropLast())-hour limit" : window == "weekly" ? "weekly limit" : "\(window) limit"
                let meter = Meter(id: id, title: name.isEmpty ? limit.capitalized : "\(name.capitalizedFirst) · \(limit)",
                                  label: label, percent: min(max((1 - remaining) * 100, 0), 100),
                                  resetsAt: Wire.date(bucket["reset_time"]), short: short)
                if index == 0 { first.append(meter) } else if short { restShort.append(meter) } else { rest.append(meter) }
            }
        }
        return first.sorted { $0.short && !$1.short } + rest + restShort
    }

    /// The AI credits left, when agy reports any.
    static func credits(_ data: Data) -> Decimal? {
        guard let value = answer(data, command: "credits")?["remaining_credits"] else { return nil }
        return (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.decimalValue }
    }

    static func snapshot(meters: [Meter], credits: Decimal?, now: Date) -> Snapshot {
        let money = credits.map { [Money(id: "credits", title: "AI credits", role: .balance, amount: $0, currency: nil, digits: 0)] }
        return Snapshot(meters: meters, money: (credits ?? 0) > 0 ? money ?? [] : [],
                        note: meters.isEmpty ? Snapshot.noPlan : nil, fetchedAt: now)
    }

    /// `command.data` of a successful answer to `command` that ran no model turn.
    private static func answer(_ data: Data, command: String) -> [String: Any]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["status"] as? String)?.uppercased() == "SUCCESS", Wire.double(root["num_turns"]) ?? 0 == 0,
              let answer = root["command"] as? [String: Any], answer["name"] as? String == command else { return nil }
        return answer["data"] as? [String: Any]
    }
}

private extension String {
    /// "Gemini Models" stays as it is; "claude and GPT models" becomes "Claude and GPT models".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
