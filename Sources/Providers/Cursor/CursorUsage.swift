import Foundation

// Cursor's `GET /api/usage-summary`, read leniently: an unofficial dashboard endpoint whose fields come and go by
// plan. Amounts are in US cents; percentages are already 0–100 (0.36 means 0.36 %, not 36 %).

/// What the usage summary reported about one billing cycle.
struct CursorUsage: Equatable, Sendable {
    var cycleStart: Date?
    var cycleEnd: Date?
    /// "pro", "pro_plus", "ultra", "free", "team", "enterprise"…
    var membership: String?
    var unlimited = false
    /// The included plan's share used, 0–100: nil when the response doesn't say.
    var planPercent: Double?
    /// Pay-as-you-go spending beyond the plan, the account's own.
    var onDemand: Spend?
    /// The team's shared on-demand budget, for team plans.
    var teamOnDemand: Spend?

    struct Spend: Equatable, Sendable {
        var usedCents: Double
        /// nil: no cap.
        var limitCents: Double?
    }

    /// Only a body that isn't a usage summary at all (none of its fields, even as `null`) throws.
    static func decode(_ data: Data) throws -> CursorUsage {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.recognised else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a usage summary"))
        }
        var usage = CursorUsage(cycleStart: raw.billingCycleStart, cycleEnd: raw.billingCycleEnd,
                                membership: raw.membershipType, unlimited: raw.isUnlimited == true)
        let plan = raw.individualUsage?.plan.flatMap { $0.enabled == false ? nil : $0 }
        if !usage.unlimited {
            usage.planPercent = plan?.totalPercentUsed?.double
                ?? share(plan?.used, plan?.limit)
                ?? share(raw.individualUsage?.overall?.used, raw.individualUsage?.overall?.limit)
                ?? share(raw.teamUsage?.pooled?.used, raw.teamUsage?.pooled?.limit)
        }
        usage.onDemand = raw.individualUsage?.onDemand?.spend
        usage.teamOnDemand = raw.teamUsage?.onDemand?.spend
        return usage
    }

    private static func share(_ used: Wire.Number?, _ limit: Wire.Number?) -> Double? {
        guard let limit = limit?.double, limit > 0 else { return nil }
        return (used?.double ?? 0) / limit * 100
    }

    /// The plan's name as Cursor's dashboard writes it.
    static func planName(_ membership: String?) -> String? {
        guard let membership = membership?.trimmingCharacters(in: .whitespacesAndNewlines), !membership.isEmpty else {
            return nil
        }
        let known = ["pro": "Pro", "pro_plus": "Pro+", "pro_student": "Pro", "ultra": "Ultra", "free": "Free",
                     "hobby": "Hobby", "free_trial": "Pro Trial", "team": "Teams", "business": "Teams",
                     "enterprise": "Enterprise", "express": "Start"]
        return known[membership.lowercased()]
            ?? membership.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func snapshot(fetchedAt: Date) -> Snapshot {
        var meters: [Meter] = []
        if let planPercent {
            meters.append(Meter(id: "plan", title: "Included usage", label: "mo", noun: "Included usage",
                                percent: planPercent, resetsAt: cycleEnd))
        }
        var money: [Money] = []
        func figure(_ id: String, _ title: String, _ spend: Spend?) {
            guard let spend, spend.usedCents > 0 || (spend.limitCents ?? 0) > 0 else { return }
            money.append(Money(id: id, title: title, amount: Self.dollars(spend.usedCents), currency: "USD",
                               limit: spend.limitCents.flatMap { $0 > 0 ? Self.dollars($0) : nil },
                               limitLabel: "monthly limit", start: cycleStart, end: cycleEnd, partial: true,
                               headline: meters.isEmpty && money.isEmpty))
        }
        figure("on-demand", "On-demand usage", onDemand)
        figure("team-on-demand", "Team on-demand usage", teamOnDemand)
        let note: String? = meters.isEmpty && money.isEmpty ? (unlimited ? "Unlimited plan" : Snapshot.noPlan) : nil
        return Snapshot(meters: meters, money: money, plan: Self.planName(membership), note: note, fetchedAt: fetchedAt)
    }

    /// Cents as dollars, exactly to the cent's hundredth.
    static func dollars(_ cents: Double) -> Decimal {
        var value = Decimal(cents) / 100, result = Decimal()
        NSDecimalRound(&result, &value, 4, .plain)
        return result
    }

    // MARK: The wire format: every field optional, each decoded on its own.

    private struct Raw: Decodable {
        let billingCycleStart: Date?
        let billingCycleEnd: Date?
        let membershipType: String?
        let isUnlimited: Bool?
        let individualUsage: Individual?
        let teamUsage: Team?
        let recognised: Bool

        enum Keys: String, CodingKey {
            case billingCycleStart, billingCycleEnd, membershipType, limitType, isUnlimited, individualUsage, teamUsage
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            recognised = !c.allKeys.isEmpty
            billingCycleStart = c.moment(.billingCycleStart)
            billingCycleEnd = c.moment(.billingCycleEnd)
            membershipType = try? c.decodeIfPresent(String.self, forKey: .membershipType)
            isUnlimited = try? c.decodeIfPresent(Bool.self, forKey: .isUnlimited)
            individualUsage = try? c.decodeIfPresent(Individual.self, forKey: .individualUsage)
            teamUsage = try? c.decodeIfPresent(Team.self, forKey: .teamUsage)
        }
    }

    private struct Individual: Decodable {
        let plan: Plan?
        let onDemand: Bucket?
        /// Enterprise members with a personal cap and no `plan`.
        let overall: Bucket?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            plan = try? c.decodeIfPresent(Plan.self, forKey: .plan)
            onDemand = try? c.decodeIfPresent(Bucket.self, forKey: .onDemand)
            overall = try? c.decodeIfPresent(Bucket.self, forKey: .overall)
        }
        enum Keys: String, CodingKey { case plan, onDemand, overall }
    }

    private struct Team: Decodable {
        let onDemand: Bucket?
        /// A pool shared by the team's members.
        let pooled: Bucket?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            onDemand = try? c.decodeIfPresent(Bucket.self, forKey: .onDemand)
            pooled = try? c.decodeIfPresent(Bucket.self, forKey: .pooled)
        }
        enum Keys: String, CodingKey { case onDemand, pooled }
    }

    private struct Plan: Decodable {
        let enabled: Bool?
        let used: Wire.Number?
        let limit: Wire.Number?
        let totalPercentUsed: Wire.Number?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
            used = c.number(.used)
            limit = c.number(.limit)
            totalPercentUsed = c.number(.totalPercentUsed)
        }
        enum Keys: String, CodingKey { case enabled, used, limit, totalPercentUsed }
    }

    private struct Bucket: Decodable {
        let enabled: Bool?
        let used: Wire.Number?
        /// `null` means no cap.
        let limit: Wire.Number?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
            used = c.number(.used)
            limit = c.number(.limit)
        }
        enum Keys: String, CodingKey { case enabled, used, limit }

        /// Spending, unless it is turned off and nothing was spent.
        var spend: Spend? {
            let used = used?.double ?? 0
            guard enabled != false || used > 0 else { return nil }
            return Spend(usedCents: max(used, 0), limitCents: limit?.double)
        }
    }
}
