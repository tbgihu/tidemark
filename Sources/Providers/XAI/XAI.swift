import Foundation

/// xAI: an API team's prepaid credits, its spend this billing cycle against its spending limit, and its daily costs,
/// read from the Management API (`management-api.x.ai`) with a management key and the team's id.
enum XAI {
    static let id = "xai"

    static let provider = Provider(
        id: id, name: "xAI", company: "xAI", brandColor: BrandColor(hex: 0x8E8E93),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [team])

    static let team = Login(
        id: "team", title: "API Team", subtitle: "Add a management key to see credits and spend", symbol: "building.2",
        kindLabel: "API team", auth: .secret(form),
        // Billing settles over minutes: reading it more often shows nothing new.
        minimumInterval: 300, secretItem: "xai-management-keys", history: .dailyCosts,
        texts: .key("management key", revokeIn: "the xAI Console", forbidden: "This management key can’t read the team’s billing.",
                    costs: true),
        accountID: { "xai-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            guard let team = teamID(credential) else { throw .signInRequired }
            _ = try await http.decode(request("prepaid/balance", credential), Balance.decode)
            return Identity(id: team, name: APIKey.name(credential, default: "Team " + team.prefix(8)))
        },
        fetch: { context throws(FetchFailure) in
            let credential = context.credential, http = context.http
            let balance = try await http.decode(request("prepaid/balance", credential), Balance.decode)
            var snapshot = Snapshot(money: [balance.money], fetchedAt: Date())
            // The invoice preview and the daily costs only add to the balance: a failure hides what they show,
            // unless xAI asked to slow down.
            do throws(FetchFailure) {
                let invoice = try await http.decode(request("postpaid/invoice/preview", credential), Invoice.decode)
                if let meter = invoice.meter { snapshot.meters.append(meter) } else if let spend = invoice.money { snapshot.money.append(spend) }
            } catch {
                if case .rateLimited = error { throw error }
            }
            do throws(FetchFailure) {
                let range = CostPlan.refresh(now: context.now)
                let days = try await costs(credential, range: range, http: http)
                _ = await context.costs.merge(context.account, days, covering: range, now: context.now)
            } catch {
                if case .rateLimited = error { throw error }
            }
            return snapshot
        },
        dailyCosts: { credential, range, http, _ throws(FetchFailure) in try await costs(credential, range: range, http: http) })

    static let form = SecretForm(
        title: "Add an xAI API Team",
        intro: "Tidemark shows an xAI team’s prepaid credits, what it spent this billing cycle and its daily costs. "
            + "Create a management key in the xAI Console (Settings → Management Keys) and copy the team’s ID.",
        warning: "A management key can change the team’s settings and keys. Tidemark only reads billing, but create a "
            + "dedicated key for it, with read-only billing access if you can, so you can revoke it on its own.",
        fields: [.init(id: "key", label: "Management key", placeholder: "xai-token-…", kind: .secret),
                 .init(id: "team", label: "Team ID", placeholder: "00000000-0000-0000-0000-000000000000", kind: .text),
                 APIKey.nameInput(placeholder: "Optional, such as Production")],
        footnote: "Stored in your Keychain on this Mac only, and sent only to xAI.",
        validate: { values in
            validTeam(values["team"] ?? "") ? nil : "A team ID is letters, digits and dashes, as the xAI Console shows it."
        },
        explain: { failure in
            switch failure {
            case .unauthorized: "xAI didn’t accept this key. Check that it’s a management key, not an API key."
            case .forbidden: "This management key can’t read the team’s billing."
            case .server(404): "xAI doesn’t know this team. Check the team ID, and that the key belongs to the same team."
            case .rateLimited: "xAI asked to slow down. Try again in a minute."
            default: nil
            }
        })

    static func validTeam(_ team: String) -> Bool {
        !team.isEmpty && team.count <= 64 && team.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func teamID(_ credential: Credential) -> String? {
        guard let team = credential.fields["team"], validTeam(team) else { return nil }
        return team
    }

    static func request(_ path: String, _ credential: Credential, body: Data? = nil) -> URLRequest {
        let team = teamID(credential) ?? "-"
        var request = URLRequest(URL(string: "https://management-api.x.ai/v1/billing/teams/\(team)/\(path)")!,
                                 method: body == nil ? "GET" : "POST",
                                 headers: ["Authorization": "Bearer \(credential.secret)"])
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Cents of USD per UTC day over `range` (UTC midnights), from the usage analytics: one dense series of daily spend.
    static func costs(_ credential: Credential, range: Range<Date>, http: HTTP) async throws(FetchFailure) -> [Date: Decimal] {
        try await http.decode(request("usage", credential, body: Usage.body(range))) { try Usage.decode($0, in: range) }
    }

    // MARK: Responses

    /// `GET …/prepaid/balance`: the prepaid ledger, in USD cents, negative for credit (a $10 top-up is "-1000").
    struct Balance: Equatable {
        /// In dollars, positive while there is credit.
        let dollars: Decimal

        var money: Money {
            Money(id: "balance", title: "Prepaid credits", role: .balance, amount: dollars, currency: "USD", headline: true)
        }

        static func decode(_ data: Data) throws -> Balance {
            struct Raw: Decodable { let total: USDCents? }
            guard let cents = try JSONDecoder().decode(Raw.self, from: data).total?.val else { throw Unreadable() }
            return Balance(dollars: -cents / 100)
        }
    }

    /// `{"val": "1234"}`, USD cents as xAI writes them.
    struct USDCents: Decodable {
        let val: Decimal?
        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let number = try? single.decode(Wire.Number.self) {
                val = number.decimal
                return
            }
            enum Keys: String, CodingKey { case val }
            val = try decoder.container(keyedBy: Keys.self).number(.val)?.decimal
        }
    }

    /// `GET …/postpaid/invoice/preview`: this billing cycle's invoice so far and the effective spending limit.
    struct Invoice: Equatable {
        /// In dollars.
        var spend: Decimal?
        var limit: Decimal?
        /// The billing cycle: a calendar month, taken as UTC.
        var cycle: Range<Date>?

        var meter: Meter? {
            guard let spend, let limit, limit > 0 else { return nil }
            return Meter(id: "cycle", title: "Spending limit", label: "mo", noun: "Monthly spending limit",
                         percent: NSDecimalNumber(decimal: spend / limit * 100).doubleValue, resetsAt: cycle?.upperBound)
        }

        /// Without a limit, the spend alone.
        var money: Money? {
            guard let spend else { return nil }
            return Money(id: "cycle", title: "This billing cycle", amount: spend, currency: "USD",
                         start: cycle?.lowerBound, end: cycle?.upperBound, partial: true)
        }

        static func decode(_ data: Data) throws -> Invoice {
            struct Raw: Decodable {
                struct Core: Decodable { let totalWithCorr: USDCents?; let amountAfterVat: USDCents? }
                struct Cycle: Decodable { let year: Wire.Number?; let month: Wire.Number? }
                let coreInvoice: Core?
                let effectiveSpendingLimit: USDCents?
                let billingCycle: Cycle?
            }
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            let cents = raw.coreInvoice?.totalWithCorr?.val ?? raw.coreInvoice?.amountAfterVat?.val
            var cycle: Range<Date>?
            if let year = raw.billingCycle?.year?.int, let month = raw.billingCycle?.month?.int,
               let start = CostCalendar.utc.date(from: DateComponents(year: year, month: month)),
               let end = CostCalendar.utc.date(byAdding: .month, value: 1, to: start) {
                cycle = start..<end
            }
            return Invoice(spend: cents.map { $0 / 100 }, limit: raw.effectiveSpendingLimit?.val.map { $0 / 100 }, cycle: cycle)
        }
    }

    /// `POST …/usage`: spend in USD per day, summed over the whole team.
    enum Usage {
        static func body(_ range: Range<Date>) -> Data {
            let request: [String: Any] = ["analyticsRequest": [
                "timeRange": ["startTime": timestamp(range.lowerBound), "endTime": timestamp(range.upperBound),
                              "timezone": "Etc/GMT"],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
                "groupBy": [String](),
                "filters": [String](),
            ]]
            return (try? JSONSerialization.data(withJSONObject: request, options: .sortedKeys)) ?? Data()
        }

        /// "2026-11-01 00:00:00" in UTC, as the analytics API takes times.
        static func timestamp(_ date: Date) -> String {
            let c = CostCalendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                          c.minute ?? 0, c.second ?? 0)
        }

        /// Strict where a lenient reading would chart a wrong amount: a point that isn't a date and a non-negative
        /// number, or a truncated answer (`limitReached`), fails it.
        static func decode(_ data: Data, in range: Range<Date>) throws -> [Date: Decimal] {
            struct Raw: Decodable {
                struct Series: Decodable { let dataPoints: [Point]? }
                struct Point: Decodable { let timestamp: String; let values: [Wire.Number]? }
                let timeSeries: [Series]
                let limitReached: Bool?
            }
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            guard raw.limitReached != true else { throw Unreadable() }
            var days: [Date: Decimal] = [:]
            for point in raw.timeSeries.flatMap({ $0.dataPoints ?? [] }) {
                guard let time = ISO8601.date(point.timestamp), let dollars = point.values?.first?.decimal, dollars >= 0
                else { throw Unreadable() }
                let day = CostCalendar.day(time)
                if range.contains(day) { days[day, default: 0] += dollars * 100 }
            }
            return days
        }
    }

    struct Unreadable: Error {}
}
