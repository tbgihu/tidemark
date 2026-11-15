import Foundation

// Console organisations: what an organisation spent, read with an Admin API key from the Admin API's cost report
// (`GET /v1/organizations/cost_report`, daily buckets), cached per organisation in a `CostLedger`.

/// One page of `GET /v1/organizations/cost_report`: cents per UTC day, summed over the rows of each bucket.
struct CostPage: Equatable, Sendable {
    var days: [Date: Decimal]
    var nextPage: String?

    /// Strict where a lenient reading would show a wrong amount: a row whose amount isn't a decimal string, a
    /// currency other than USD, or `has_more` without a cursor fails the page. Unknown fields are ignored; a bucket
    /// with no rows (or one the API leaves out) costs nothing.
    static func decode(_ data: Data) throws -> CostPage {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var days: [Date: Decimal] = [:]
        for bucket in raw.data {
            guard let start = ISO8601.date(bucket.starting_at) else { throw Unreadable() }
            let day = CostCalendar.day(start)
            var sum = days[day] ?? 0
            for row in bucket.results ?? [] {
                guard (row.currency ?? "USD").uppercased() == "USD", let amount = Cents.parse(row.amount) else {
                    throw Unreadable()
                }
                sum += amount
            }
            days[day] = sum
        }
        if raw.has_more == true, raw.next_page?.isEmpty ?? true { throw Unreadable() }
        return CostPage(days: days, nextPage: raw.has_more == true ? raw.next_page : nil)
    }

    struct Unreadable: Error {}

    private struct Raw: Decodable {
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
    }

    private struct Bucket: Decodable {
        let starting_at: String
        let results: [Row]?
    }

    private struct Row: Decodable {
        let amount: String
        let currency: String?
    }
}

/// `GET /v1/organizations/me`: the organisation an Admin API key belongs to.
struct Organization: Equatable, Sendable {
    let id: String
    let name: String

    static func decode(_ data: Data) throws -> Organization {
        struct Raw: Decodable { let id: String; let name: String?; let type: String? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, raw.type == nil || raw.type == "organization" else { throw CostPage.Unreadable() }
        let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Organization(id: id, name: name.isEmpty ? "API organisation" : name)
    }
}

/// What a pasted key looks like. Only an Admin API key can read costs; a workspace key is turned away before any
/// request, with a word on why.
enum AdminKey {
    enum Shape: Equatable { case admin, workspace, unknown }

    static func clean(_ text: String) -> String { text.filter { !$0.isWhitespace && !$0.isNewline } }

    static func shape(_ key: String) -> Shape {
        if key.hasPrefix("sk-ant-admin") { return .admin }
        if key.hasPrefix("sk-ant-api") { return .workspace }
        return .unknown
    }
}
