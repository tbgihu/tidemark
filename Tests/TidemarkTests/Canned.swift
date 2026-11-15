import Foundation
@testable import TidemarkCore

/// Canned HTTP answers for providers' fetch and identify tests, recording what was asked.
enum Canned {
    /// The requests a canned transport received, in order.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { all } }
        var urls: [String] { requests.map { $0.url?.absoluteString ?? "" } }
        func add(_ request: URLRequest) { lock.withLock { all.append(request) } }
    }

    /// Answers each request with the (status, body) `answer` gives it.
    static func http(headers: [String: String] = [:], seen: Seen = Seen(),
                     _ answer: @escaping @Sendable (URLRequest) -> (Int, String)) -> HTTP {
        HTTP { request in
            seen.add(request)
            let (status, body) = answer(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    /// Answers every request with `body`.
    static func http(_ body: String, status: Int = 200, headers: [String: String] = [:], seen: Seen = Seen()) -> HTTP {
        http(headers: headers, seen: seen) { _ in (status, body) }
    }

    /// Answers each request with the (status, body) of its route, the key `route` makes of it; 404 otherwise.
    static func http(_ routes: [String: (Int, String)], route: @escaping @Sendable (URLRequest) -> String = { $0.url!.lastPathComponent },
                     unknown: String = "", seen: Seen = Seen()) -> HTTP {
        http(seen: seen) { request in routes[route(request)] ?? (404, unknown) }
    }

    static func context(_ http: HTTP, _ credential: Credential, now: Date = Date(), costs: Costs = Costs()) -> FetchContext {
        FetchContext(account: "a", credential: credential, http: http, now: now, costs: costs)
    }

    /// A cost cache in memory.
    actor Costs: CostCache {
        var ledgers: [String: CostLedger] = [:]
        func ledger(_ account: String) -> CostLedger { ledgers[account] ?? CostLedger() }
        func merge(_ account: String, _ days: [Date: Decimal], covering range: Range<Date>, now: Date) -> CostLedger {
            var ledger = ledger(account)
            ledger.merge(days, covering: range)
            ledgers[account] = ledger
            return ledger
        }
    }
}
