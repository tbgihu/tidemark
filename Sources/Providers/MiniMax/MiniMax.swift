import Foundation

/// MiniMax Coding (Token) Plans: the 5-hour and weekly limits of its text models, and the windows of any other
/// models the plan includes, read with a Coding Plan key (`sk-cp-…`) from the region it was issued in.
enum MiniMax {
    static let id = "minimax"

    static let provider = Provider(
        id: id, name: "MiniMax", company: "MiniMax", brandColor: BrandColor(hex: 0xC04FC0),
        order: Registry.order(of: id), recommendedMinimumInterval: 300, logins: [plan])

    static func host(_ credential: Credential) -> String {
        APIKey.Region(credential) == .china ? "api.minimaxi.com" : "api.minimax.io"
    }

    static func request(_ credential: Credential) -> URLRequest {
        URLRequest(URL(string: "https://\(host(credential))/v1/token_plan/remains")!,
                   headers: ["Authorization": "Bearer \(credential.secret)"])
    }

    static let plan = Login(
        id: "plan", title: "Coding Plan", subtitle: "Add a Coding Plan key to see its usage limits", symbol: "key",
        kindLabel: "Coding Plan", auth: .secret(SecretForm(
            title: "Add a MiniMax Coding Plan Key",
            intro: "Tidemark shows a MiniMax Coding Plan’s 5-hour and weekly limits. Paste the plan’s API key "
                + "(sk-cp-…) from platform.minimax.io (International) or platform.minimaxi.com (China) and choose the "
                + "region it was issued for.",
            fields: [.init(id: "key", label: "Coding Plan key", placeholder: "sk-cp-…", kind: .secret),
                     APIKey.Region.input,
                     APIKey.nameInput(placeholder: "Optional, such as Work")],
            footnote: "Stored in your Keychain on this Mac only, and sent only to MiniMax.",
            validate: { values in
                (values["key"] ?? "").hasPrefix("sk-api-")
                    ? "This is a pay-as-you-go API key (sk-api-…). Usage limits can only be read with the Coding Plan’s key (sk-cp-…)."
                    : nil
            },
            explain: { failure in
                switch failure {
                case .unauthorized: "MiniMax didn’t accept this key. Check that it’s a Coding Plan key (sk-cp-…) issued for the region chosen."
                case .rateLimited: "MiniMax asked to slow down. Try again in a minute."
                default: nil
                }
            })),
        secretItem: "minimax-api-keys",
        history: .meters([ChartedMeter(id: "session", label: "5h", title: "5-hour limit"),
                          ChartedMeter(id: "weekly", label: "weekly", title: "Weekly limit")]),
        texts: .key(revokeIn: "the MiniMax platform"),
        accountID: { "minimax-" + $0 },
        identify: { credential, http throws(FetchFailure) in
            _ = try MiniMaxRemains.snapshot(try await http.data(request(credential)), now: Date())
            return Identity(id: APIKey.fingerprint(credential.secret), name: APIKey.name(credential, default: "MiniMax Coding Plan"))
        },
        fetch: { context throws(FetchFailure) in
            try MiniMaxRemains.snapshot(try await context.http.data(request(context.credential)), now: context.now)
        })
}

/// `GET /v1/token_plan/remains`. Errors come back as HTTP 200 with `base_resp.status_code` (1004 for a rejected
/// key). `model_remains[]` has, per model, the current interval (`start_time`…`end_time`, epoch ms) and week.
///
/// Despite its name, `current_interval_usage_count` (and `current_weekly_usage_count`) is the number of requests
/// **remaining**, not used: 15000 total and 14989 "usage" is 11 requests used, as CodexBar established from live
/// responses (docs/minimax.md and its parser's tests). Newer token plans send the counts as 0 and the share left in
/// `current_interval_remaining_percent` instead, which wins when present. Status 3 marks a window the plan doesn't
/// include, or an unlimited one: neither is a meter.
enum MiniMaxRemains {
    static func snapshot(_ data: Data, now: Date) throws(FetchFailure) -> Snapshot {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw .unreadable }
        if let status = raw.status, status != 0 { throw failure(status) }
        guard let models = raw.models else { throw .unreadable }

        var meters: [Meter] = []
        func add(_ meter: Meter?) {
            guard let meter else { return }
            if let index = meters.firstIndex(where: { $0.id == meter.id }) {
                if meter.percent > meters[index].percent { meters[index] = meter }   // the most constrained
            } else {
                meters.append(meter)
            }
        }
        // Text models first, whose limits are the plan's 5-hour and weekly ones; the others after.
        let ordered = models.filter(\.isText) + models.filter { !$0.isText }
        for model in ordered {
            add(model.interval.meter(model, weekly: false, now: now))
            add(model.week.meter(model, weekly: true, now: now))
        }
        return Snapshot(meters: meters, plan: raw.plan, note: raw.plan == nil && models.isEmpty ? Snapshot.noPlan : nil,
                        fetchedAt: now)
    }

    static func failure(_ status: Int) -> FetchFailure {
        switch status {
        case 1004, 2049: .unauthorized
        case 1002, 1039: .rateLimited(nil)
        default: .server(status)
        }
    }

    // MARK: Wire format

    struct Raw: Decodable {
        let status: Int?
        let models: [Model]?
        let plan: String?

        private enum Keys: String, CodingKey {
            case base_resp, data, model_remains, current_subscribe_title, plan_name, combo_title, current_plan_title,
                 current_combo_card
        }
        private struct Base: Decodable {
            let code: Int?
            private enum Keys: String, CodingKey { case status_code }
            init(from decoder: any Decoder) throws {
                code = try decoder.container(keyedBy: Keys.self).number(.status_code)?.int
            }
        }
        private struct Card: Decodable { let title: String? }

        init(from decoder: any Decoder) throws {
            let outer = try decoder.container(keyedBy: Keys.self)
            // The fields sit in `data` or at the top level; the status in either.
            let c = (try? outer.nestedContainer(keyedBy: Keys.self, forKey: .data)) ?? outer
            status = [c, outer].lazy.compactMap { (try? $0.decodeIfPresent(Base.self, forKey: .base_resp))?.code }.first
            models = (try? c.decodeIfPresent([Lenient<Model>].self, forKey: .model_remains))?.compactMap(\.value)
            let card = (try? c.decodeIfPresent(Card.self, forKey: .current_combo_card))?.title
            plan = ([c.text(.current_subscribe_title), c.text(.plan_name), c.text(.combo_title), c.text(.current_plan_title)]
                + [card?.trimmingCharacters(in: .whitespaces)]).compactMap { $0 }.first { !$0.isEmpty }
        }
    }

    struct Model: Decodable {
        let name: String
        let interval: Window
        let week: Window

        private enum Keys: String, CodingKey { case model_name }

        init(from decoder: any Decoder) throws {
            name = try decoder.container(keyedBy: Keys.self).text(.model_name) ?? ""
            interval = try Window(decoder, prefix: "current_interval", start: "start_time", end: "end_time", remains: "remains_time")
            week = try Window(decoder, prefix: "current_weekly", start: "weekly_start_time", end: "weekly_end_time",
                              remains: "weekly_remains_time")
        }

        /// The models a coding plan is for: `general` in token plans, MiniMax-M… in older ones.
        var isText: Bool {
            let lower = name.lowercased()
            return lower.isEmpty || lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2.")
        }

        /// What any other model is, in a few characters for the menu bar.
        var kind: (title: String, label: String) {
            let lower = name.lowercased()
            if lower.contains("speech") { return ("Speech", "tts") }
            if lower.contains("hailuo") && lower.contains("fast") { return ("Image to video", "i2v") }
            if lower.contains("video") || lower.contains("hailuo") { return ("Video", "vid") }
            if lower.hasPrefix("image") { return ("Image", "img") }
            if lower.contains("music") { return ("Music", "mus") }
            return (name, String(lower.filter { $0.isLetter || $0.isNumber }.prefix(3)))
        }
    }

    struct Window {
        let total: Double?
        let remaining: Double?
        let remainingPercent: Double?
        let status: Int?
        let start: Date?
        let end: Date?
        let remainsMilliseconds: Double?

        private struct Key: CodingKey {
            let stringValue: String
            init(_ name: String) { stringValue = name }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(_ decoder: any Decoder, prefix: String, start: String, end: String, remains: String) throws {
            let c = try decoder.container(keyedBy: Key.self)
            total = c.number(Key(prefix + "_total_count"))?.double
            remaining = c.number(Key(prefix + "_usage_count"))?.double     // remaining, despite the name
            remainingPercent = c.number(Key(prefix + "_remaining_percent"))?.double
                ?? c.text(Key(prefix + "_remaining_percent")).flatMap { $0.hasSuffix("%") ? Double($0.dropLast()) : nil }
            status = c.number(Key(prefix + "_status"))?.int
            self.start = Wire.epoch(c.number(Key(start))?.double)
            self.end = Wire.epoch(c.number(Key(end))?.double)
            remainsMilliseconds = c.number(Key(remains))?.double
        }

        var percent: Double? {
            if let remainingPercent, remainingPercent.isFinite { return min(max(100 - remainingPercent, 0), 100) }
            guard let total, total > 0, let remaining, remaining >= 0 else { return nil }
            return Wire.percent(used: total - remaining, of: total)
        }

        func resetsAt(now: Date) -> Date? {
            if let end, end > now { return end }
            guard let remainsMilliseconds, remainsMilliseconds > 0 else { return nil }
            return now + remainsMilliseconds / 1000
        }

        var minutes: Int? {
            guard let start, let end, end > start else { return nil }
            return Int((end.timeIntervalSince(start) / 60).rounded())
        }

        func meter(_ model: Model, weekly: Bool, now: Date) -> Meter? {
            guard status != 3, let percent else { return nil }
            let reset = resetsAt(now: now)
            let minutes = weekly ? 10080 : minutes ?? 300
            let span: (title: String, label: String) = switch minutes {
            case 10080: ("weekly", "w")
            case 1440: ("daily", "day")
            case let m where m % 60 == 0: ("\(m / 60)-hour", "\(m / 60)h")
            case let m: ("\(m)-minute", "\(m)m")
            }
            if model.isText {
                return weekly
                    ? Meter(id: "weekly", title: "Weekly limit", label: "w", noun: "Weekly limit", percent: percent, resetsAt: reset)
                    : Meter(id: "session", title: "\(span.title.prefix(1).uppercased() + span.title.dropFirst()) limit",
                            label: span.label, percent: percent, resetsAt: reset, short: minutes < 1440)
            }
            let kind = model.kind
            return Meter(id: "\(kind.label)-\(weekly ? "weekly" : "interval")", title: "\(kind.title) · \(span.title)",
                         label: kind.label, noun: "\(kind.title) limit", percent: percent, resetsAt: reset, short: minutes < 1440)
        }
    }
}
