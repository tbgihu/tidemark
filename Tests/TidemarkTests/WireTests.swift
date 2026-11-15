import Foundation
import Testing
@testable import TidemarkCore

/// The lenient readers every provider decodes with, and the identity of accounts added with a key.
@Suite struct WireTests {
    struct Fields: Decodable {
        let number: Wire.Number?, moment: Date?, text: String?
        enum Keys: String, CodingKey { case number, moment, text }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            number = c.number(.number)
            moment = c.moment(.moment)
            text = c.text(.text)
        }
    }

    func fields(_ json: String) throws -> Fields { try JSONDecoder().decode(Fields.self, from: Data(json.utf8)) }

    @Test func numbersAreNumbersOrNumericStrings() throws {
        #expect(try fields(#"{"number":12.5}"#).number?.decimal == Decimal(string: "12.5"))
        #expect(try fields(#"{"number":" -0.5 "}"#).number?.decimal == Decimal(string: "-0.5"))
        #expect(try fields(#"{"number":"1.5e-05"}"#).number?.decimal == Decimal(string: "0.000015"))
        #expect(try fields(#"{"number":"0.1"}"#).number?.decimal == Decimal(string: "0.1"), "exact, never through a float")
        for odd in [#""""#, #""12 apples""#, #"".5""#, #""0x10""#, #""NaN""#, #""+1""#, #""1e999""#, "true", "null", "[1]", "{}"] {
            #expect(try fields(#"{"number":\#(odd)}"#).number == nil, "\(odd)")
        }
        #expect(try fields("{}").number == nil)
        #expect(Wire.Number(Decimal(string: "1e30")!).int != 0, "a huge number truncates, never traps")
    }

    @Test func numbersFromJSONSerialization() {
        #expect(Wire.double(12) == 12 && Wire.double("12.5") == 12.5 && Wire.double(" 3 ") == 3)
        #expect(Wire.double(true) == nil && Wire.double("x") == nil && Wire.double(nil) == nil && Wire.double(Double.infinity) == nil)
    }

    @Test func momentsAreISOOrSecondsOrMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_795_392_000)
        #expect(Wire.epoch(1_795_392_000) == date && Wire.epoch(1_795_392_000_000) == date)
        #expect(Wire.epoch(0) == nil && Wire.epoch(-5) == nil && Wire.epoch(1e18) == nil && Wire.epoch(nil) == nil)
        #expect(try fields(#"{"moment":"2026-11-23T00:00:00Z"}"#).moment == date)
        #expect(try fields(#"{"moment":1795392000000}"#).moment == date)
        #expect(try fields(#"{"moment":"1795392000"}"#).moment == date)
        #expect(try fields(#"{"moment":"soon"}"#).moment == nil)
        #expect(Wire.date("2026-11-23T00:00:00Z") == date && Wire.date(1_795_392_000) == date && Wire.date(true) == nil)
    }

    @Test func textIsTrimmedAndNeverEmpty() throws {
        #expect(try fields(#"{"text":" Pro "}"#).text == "Pro")
        #expect(try fields(#"{"text":"  "}"#).text == nil && fields(#"{"text":3}"#).text == nil)
    }

    @Test func percentNeedsALimit() {
        #expect(Wire.percent(used: 25, of: 100) == 25 && Wire.percent(used: 150, of: 100) == 100)
        #expect(Wire.percent(used: 1, of: 0) == nil && Wire.percent(used: .nan, of: 1) == nil)
    }

    @Test func keysAreNamedWithoutRevealingThem() {
        let id = APIKey.fingerprint("sk-secret-1234")
        #expect(id.count == 16 && id == APIKey.fingerprint("sk-secret-1234") && id != APIKey.fingerprint("sk-secret-1235"))
        #expect(!id.contains("1234") && APIKey.hint("sk-secret-1234") == "Key …1234")
        #expect(APIKey.name(Credential(secret: "k", fields: ["name": " Work "]), default: "X") == "Work")
        #expect(APIKey.name(Credential(secret: "k"), default: "X") == "X")
        #expect(APIKey.Region(Credential(secret: "k", fields: ["region": "china"])) == .china)
        #expect(APIKey.Region(Credential(secret: "k", fields: ["region": "mars"])) == .international)
    }

    @Test func keyLoginsWordTheirKey() {
        let texts = LoginTexts.key("admin key", revokeIn: "the Console", costs: true)
        #expect(texts.signedOut == "Key rejected. Re-enter the admin key to see costs.")
        #expect(texts.reauthenticateSpoken == "Re-enter the admin key for")
        #expect(texts.removal("", "").hasSuffix("revoke it in the Console if nothing else uses it."))
        #expect(LoginTexts.key(revokeIn: "x").signedOut == "Key rejected. Re-enter the API key to see usage.")
    }
}
