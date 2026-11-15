import Foundation

/// z.ai's GLM Coding Plan (BigModel in China): its token windows (5-hour, weekly) and the monthly MCP allowance, read
/// with an API key from the region it was issued in.
enum Zai {
    static let id = "zai"

    static let provider = Provider(
        id: id, name: "z.ai", company: "Z.ai", brandColor: BrandColor(hex: 0x3E9E44),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [plan])

    /// International keys come from z.ai, Chinese ones from BigModel (open.bigmodel.cn).
    static func host(_ credential: Credential) -> String {
        APIKey.Region(credential) == .china ? "open.bigmodel.cn" : "api.z.ai"
    }

    static func request(_ credential: Credential) -> URLRequest {
        URLRequest(URL(string: "https://\(host(credential))/api/monitor/usage/quota/limit")!,
                   headers: ["Authorization": "Bearer \(credential.secret)"])
    }

    static let plan = Login(
        id: "plan", title: "GLM Coding Plan", subtitle: "Add an API key to see its usage limits", symbol: "key",
        kindLabel: "GLM Coding Plan", auth: .secret(SecretForm(
            title: "Add a GLM Coding Plan Key",
            intro: "Tidemark shows a GLM Coding Plan’s 5-hour and weekly limits and its monthly MCP allowance. Paste "
                + "an API key from z.ai (International) or BigModel (China) and choose the region it was issued for.",
            fields: [.init(id: "key", label: "API key", placeholder: "Your API key", kind: .secret),
                     APIKey.Region.input,
                     APIKey.nameInput(placeholder: "Optional, such as Work")],
            footnote: "Stored in your Keychain on this Mac only, and sent only to z.ai or BigModel.",
            explain: { failure in
                switch failure {
                case .unauthorized: "z.ai didn’t accept this key. Check that it was issued for the region chosen."
                case .rateLimited: "z.ai asked to slow down. Try again in a minute."
                default: nil
                }
            })),
        secretItem: "zai-api-keys",
        history: .meters([ChartedMeter(id: "session", label: "5h", title: "5-hour limit"),
                          ChartedMeter(id: "weekly", label: "weekly", title: "Weekly limit"),
                          ChartedMeter(id: "mcp", label: "mcp", title: "MCP calls")]),
        texts: .key(revokeIn: "z.ai or BigModel"),
        accountID: { "zai-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try ZaiQuota.snapshot(try await http.data(request(credential)), now: Date())
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "GLM Coding Plan"))
        },
        fetch: { context throws(FetchFailure) in
            try ZaiQuota.snapshot(try await context.http.data(request(context.credential)), now: context.now)
        })
}

/// `GET /api/monitor/usage/quota/limit`. Errors come back as HTTP 200 with `success: false` and the status in `code`
/// (401 for a rejected key). `data.limits[]` holds `TOKENS_LIMIT` windows, sized by `unit` (1 day, 3 hours, 5
/// minutes, 6 weeks) times `number`, and a `TIME_LIMIT` for MCP calls (`unit` 5, `number` 1: monthly).
enum ZaiQuota {
    static func snapshot(_ data: Data, now: Date) throws(FetchFailure) -> Snapshot {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw .unreadable }
        if raw.success == false || (raw.code.map { $0 != 200 && $0 != 0 } ?? false) {
            if raw.message.map(saysNoPlan) == true { return Snapshot(note: Snapshot.noPlan, fetchedAt: now) }
            throw failure(raw.code)
        }
        guard let quota = raw.data, let limits = quota.limits else { throw .unreadable }

        var meters: [Meter] = []
        let tokens = limits.filter { $0.type == "TOKENS_LIMIT" || $0.type == "CREDIT_LIMIT" }
            .sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
        for limit in tokens {
            guard let meter = limit.meter(now: now), !meters.contains(where: { $0.id == meter.id }) else { continue }
            meters.append(meter)
        }
        if let mcp = limits.last(where: { $0.type == "TIME_LIMIT" })?.meter(now: now) { meters.append(mcp) }
        return Snapshot(meters: meters, plan: quota.plan, note: quota.plan == nil && limits.isEmpty ? Snapshot.noPlan : nil,
                        fetchedAt: now)
    }

    /// BigModel answers a key without a Coding Plan with an error saying so.
    static func saysNoPlan(_ message: String) -> Bool { message.lowercased().contains("coding plan") }

    static func failure(_ code: Int?) -> FetchFailure {
        switch code {
        case 401, 1000, 1001, 1002, 1003, 1004: .unauthorized
        case 403: .forbidden
        case 429, 1302, 1303, 1305: .rateLimited(nil)
        case let code? where code >= 500 && code < 600: .server(code)
        default: .unreadable
        }
    }

    // MARK: Wire format

    struct Raw: Decodable {
        let code: Int?
        let message: String?
        let success: Bool?
        let data: Quota?

        private enum Keys: String, CodingKey { case code, msg, success, data }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            code = c.number(.code)?.int
            message = c.text(.msg)
            success = (try? c.decodeIfPresent(Bool.self, forKey: .success)) ?? nil
            data = try? c.decodeIfPresent(Quota.self, forKey: .data)
        }
    }

    struct Quota: Decodable {
        let limits: [Limit]?
        let plan: String?

        private enum Keys: String, CodingKey { case limits, planName, plan, plan_type, packageName, level }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            limits = (try? c.decodeIfPresent([Lenient<Limit>].self, forKey: .limits))?.map { $0.value }.compactMap { $0 }
            plan = [Keys.planName, .plan, .plan_type, .packageName, .level].lazy.compactMap { c.text($0) }.first
        }
    }

    struct Limit: Decodable {
        let type: String
        let unit: Int?
        let number: Int?
        let percentage: Double?
        let usage: Double?
        let current: Double?
        let remaining: Double?
        let nextReset: Date?

        private enum Keys: String, CodingKey { case type, unit, number, percentage, usage, currentValue, remaining, nextResetTime }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decode(String.self, forKey: .type)
            unit = c.number(.unit)?.int
            number = c.number(.number)?.int
            percentage = c.number(.percentage)?.double
            usage = c.number(.usage)?.double
            current = c.number(.currentValue)?.double
            remaining = c.number(.remaining)?.double
            nextReset = Wire.epoch(c.number(.nextResetTime)?.double)
        }

        /// The window's length: `number` of `unit`s.
        var minutes: Int? {
            let factor = [1: 1440, 3: 60, 5: 1, 6: 10080]
            guard let unit, let number, (1...1000).contains(number), let size = factor[unit] else { return nil }
            return number * size
        }

        /// Counts when there are some (`usage` is the limit, `currentValue` what is used), else `percentage`.
        var percent: Double? {
            if let usage, usage > 0 {
                let used: Double? = if let remaining { max(usage - remaining, current ?? usage - remaining) } else { current }
                if let used { return Wire.percent(used: used, of: usage) }
            }
            return percentage.map { min(max($0, 0), 100) }
        }

        func meter(now: Date) -> Meter? {
            guard let percent else { return nil }
            if type == "TIME_LIMIT" {
                let monthly = unit == 5 && number == 1
                return Meter(id: "mcp", title: monthly ? "MCP calls · monthly" : "MCP calls", label: "mcp", noun: "MCP limit",
                             percent: percent, resetsAt: nextReset)
            }
            guard let minutes else {
                return Meter(id: "tokens", title: "Token limit", label: "tok", percent: percent, resetsAt: nextReset)
            }
            // A 5-hour window can't reset more than 5 hours from now: such a time is wrong, and not shown.
            let reset = minutes == 300 ? nextReset.flatMap { $0 <= now + 5 * 3600 + 60 ? $0 : nil } : nextReset
            let (id, title, label): (String, String, String) = switch minutes {
            case 300: ("session", "5-hour limit", "5h")
            case 10080: ("weekly", "Weekly limit", "w")
            case 1440: ("daily", "Daily limit", "day")
            case let m where m % 10080 == 0: ("tokens-\(m)", "\(m / 10080)-week limit", "\(m / 10080)w")
            case let m where m % 1440 == 0: ("tokens-\(m)", "\(m / 1440)-day limit", "\(m / 1440)d")
            case let m where m % 60 == 0: ("tokens-\(m)", "\(m / 60)-hour limit", "\(m / 60)h")
            case let m: ("tokens-\(m)", "\(m)-minute limit", "\(m)m")
            }
            return Meter(id: id, title: title, label: label, percent: percent, resetsAt: reset, short: minutes < 1440)
        }
    }
}
