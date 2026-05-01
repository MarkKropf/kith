import Foundation

enum KithJSON {
    /// Standard kith JSON encoder: ISO-8601 UTC with fractional seconds, sorted
    /// keys, no extra whitespace (single-record `--json`) or pretty (multi-line
    /// only used in tests).
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(KithDateFormatter.string(from: date))
        }
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return enc
    }

    /// Encode one record as a single line of JSON suitable for JSONL streams.
    static func line<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

enum KithDateFormatter {
    /// ISO-8601 UTC with fractional seconds: `YYYY-MM-DDTHH:MM:SS.sssZ`.
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    static func string(from date: Date) -> String {
        return formatter().string(from: date)
    }

    static func date(from string: String) -> Date? {
        return formatter().date(from: string)
    }
}
