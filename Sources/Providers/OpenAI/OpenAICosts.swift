import Foundation

// API organisations: what an OpenAI organisation spent, read with an Admin API key from
// `GET /v1/organization/costs` (daily buckets), cached per organisation in a `CostLedger` like Claude's.

extension OpenAI {
    /// One page of `GET /v1/organization/costs`: cents per UTC day, summed over the rows of each bucket.
    struct CostPage: Equatable, Sendable {
        var days: [Date: Decimal]
        var nextPage: String?

        /// Strict where a lenient reading would show a wrong amount: a row without an amount, or in a currency other
        /// than USD, fails the page, as does `has_more` without a cursor. Unknown fields are ignored; a bucket with
        /// no rows costs nothing. Amounts are dollars, as JSON numbers, read exactly.
        static func decode(_ data: Data) throws -> CostPage {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            var days: [Date: Decimal] = [:]
            for bucket in raw.data {
                guard let start = Wire.epoch(bucket.start_time?.double) else { throw FetchFailure.unreadable }
                let day = CostCalendar.day(start)
                var sum = days[day] ?? 0
                for row in bucket.results ?? [] {
                    guard let amount = row.amount, (amount.currency ?? "usd").lowercased() == "usd",
                          let dollars = amount.value?.decimal else { throw FetchFailure.unreadable }
                    sum += dollars * 100
                }
                days[day] = sum
            }
            if raw.has_more == true, raw.next_page?.isEmpty ?? true { throw FetchFailure.unreadable }
            return CostPage(days: days, nextPage: raw.has_more == true ? raw.next_page : nil)
        }

        private struct Raw: Decodable {
            let data: [Bucket]
            let has_more: Bool?
            let next_page: String?
        }

        private struct Bucket: Decodable {
            let start_time: Wire.Number?
            let results: [Row]?
        }

        private struct Row: Decodable {
            let amount: Amount?
        }

        private struct Amount: Decodable {
            let value: Wire.Number?
            let currency: String?
        }
    }

    /// What a pasted key looks like: only an Admin API key reads costs.
    enum KeyShape: Equatable { case admin, project, unknown }

    static func keyShape(_ key: String) -> KeyShape {
        if key.hasPrefix("sk-admin-") { return .admin }
        if key.hasPrefix("sk-proj-") || key.hasPrefix("sk-svcacct-") || key.hasPrefix("sk-None-") { return .project }
        if key.hasPrefix("sk-") && !key.hasPrefix("sk-ant-") { return .project }
        return .unknown
    }
}
