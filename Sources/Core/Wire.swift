import Foundation

/// Lenient readers for providers' responses: numbers sent as JSON numbers or as strings, moments sent as ISO 8601 or
/// as Unix times in seconds or milliseconds, and trimmed strings. A field of the wrong shape reads as nil, so it is
/// skipped rather than failing the response.
enum Wire {
    /// A number sent as a JSON number or a numeric string ("12", "-0.5", "1.5e-05"), kept exact. Anything else fails
    /// to decode: read it with `KeyedDecodingContainer.number(_:)` so a field of the wrong shape is skipped.
    struct Number: Decodable, Equatable, Sendable {
        let decimal: Decimal
        var double: Double { NSDecimalNumber(decimal: decimal).doubleValue }
        /// Truncated toward zero; never traps, however large.
        var int: Int { NSDecimalNumber(decimal: decimal).intValue }

        init(_ decimal: Decimal) { self.decimal = decimal }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard let value = Wire.decimal(text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
                }
                decimal = value
            } else {
                decimal = try container.decode(Decimal.self)
            }
        }
    }

    /// A moment sent as ISO 8601, or as a Unix time in seconds or milliseconds (a number or a numeric string).
    struct Moment: Decodable, Equatable, Sendable {
        let date: Date

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self), let date = ISO8601.date(text) {
                self.date = date
            } else if let date = Wire.epoch(try? Number(from: decoder).double) {
                self.date = date
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a moment")
            }
        }
    }

    /// A decimal as JSON writes numbers, from a string: "12", "-0.5", "1.5e-05", surrounding whitespace allowed.
    /// Anything else (hex, a leading "+" or ".", trailing text, which `Decimal(string:)` would quietly cut short) is nil.
    static func decimal(_ text: String) -> Decimal? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = body.split(omittingEmptySubsequences: false) { $0 == "e" || $0 == "E" }
        guard (1...2).contains(parts.count), Cents.parse(String(parts[0])) != nil else { return nil }
        if parts.count == 2 {
            let exponent = parts[1].first == "-" || parts[1].first == "+" ? parts[1].dropFirst() : parts[1]
            guard (1...2).contains(exponent.count), exponent.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        }
        guard let value = Decimal(string: body, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    /// A number from `JSONSerialization`, or a numeric string; never a Boolean, never infinite.
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            number.doubleValue.isFinite ? number.doubleValue : nil
        case let text as String: decimal(text).map { NSDecimalNumber(decimal: $0).doubleValue }
        default: nil
        }
    }

    /// A Unix time in seconds or milliseconds (told apart by size); nil for zero, negative or absurd values.
    static func epoch(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        guard seconds < 32_503_680_000 else { return nil }                // the year 3000
        return Date(timeIntervalSince1970: seconds)
    }

    /// A moment from `JSONSerialization`: an ISO 8601 string, or a Unix time in seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String, let date = ISO8601.date(text) { return date }
        return epoch(double(value))
    }

    /// A share used, 0–100, of a limit; nil without a positive limit.
    static func percent(used: Double, of limit: Double) -> Double? {
        guard limit > 0, used.isFinite, limit.isFinite else { return nil }
        return min(max(used / limit * 100, 0), 100)
    }
}

extension KeyedDecodingContainer {
    /// A number at `key`, sent as a number or a string; nil when missing, null or of another shape.
    func number(_ key: Key) -> Wire.Number? { (try? decodeIfPresent(Wire.Number.self, forKey: key)) ?? nil }

    /// A moment at `key`, as ISO 8601 or a Unix time; nil when missing, null or of another shape.
    func moment(_ key: Key) -> Date? { ((try? decodeIfPresent(Wire.Moment.self, forKey: key)) ?? nil)?.date }

    /// A non-empty, trimmed string at `key`; nil otherwise.
    func text(_ key: Key) -> String? {
        guard let value = (try? decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
