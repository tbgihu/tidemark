import Foundation
import Testing
@testable import TidemarkCore

@Suite struct DeepSeekTests {
    static let response = """
    {"is_available":true,"balance_infos":[
      {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},
      {"currency":"USD","total_balance":"4.5","granted_balance":"0.00","topped_up_balance":"4.50"}]}
    """

    @Test func balancesPerCurrency() throws {
        let snapshot = try DeepSeek.Balance.decode(Data(Self.response.utf8)).snapshot
        #expect(snapshot.money.map(\.id) == ["balance-CNY", "granted-CNY", "balance-USD"])
        #expect(snapshot.money.map(\.amount) == [110, 10, Decimal(string: "4.5")])
        #expect(snapshot.money.map(\.currency) == ["CNY", "CNY", "USD"])
        #expect(snapshot.headline?.id == "balance-CNY" && snapshot.meters.isEmpty && snapshot.plan == nil)
    }

    @Test func toleratesOddAnswers() throws {
        let odd = try DeepSeek.Balance.decode(Data("""
            {"is_available":false,"balance_infos":[{"currency":"usd","total_balance":0},{"currency":"CNY"},{"total_balance":"1"}]}
            """.utf8)).snapshot
        #expect(odd.money.map(\.id) == ["balance-USD"] && odd.money[0].amount == 0)
        #expect(odd.plan == "Insufficient balance")
        #expect(try DeepSeek.Balance.decode(Data(#"{"balance_infos":[]}"#.utf8)).snapshot.isEmpty)
        #expect(throws: (any Error).self) { try DeepSeek.Balance.decode(Data(#"{"error":{"message":"x"}}"#.utf8)) }
    }

    @Test func fetchAndIdentify() async throws {
        let recorder = Canned.Seen()
        let snapshot = try await DeepSeek.key.fetch(Canned.context(Canned.http(Self.response, seen: recorder),
                                                                   Credential(secret: "sk-abcd")))
        #expect(snapshot.money.count == 3)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance" && request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-abcd")

        let identity = try await DeepSeek.key.identify(Credential(secret: "sk-abcd"), Canned.http(Self.response))
        #expect(identity.name == "DeepSeek Key …abcd" && DeepSeek.key.accountID(identity.id).hasPrefix("deepseek-"))
        await #expect(throws: FetchFailure.unauthorized) {
            try await DeepSeek.key.identify(Credential(secret: "sk-x"), Canned.http(#"{"error":{"type":"authentication_error"}}"#, status: 401))
        }
        await #expect(throws: FetchFailure.rateLimited(20)) {
            try await DeepSeek.key.fetch(Canned.context(Canned.http("", status: 429, headers: ["Retry-After": "20"]),
                                                        Credential(secret: "sk-x")))
        }
    }
}
