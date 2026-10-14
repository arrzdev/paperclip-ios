import Foundation

/// ISO 8601 timestamps as the server sends them (`2026-10-13T22:21:01.003Z`),
/// with or without fractional seconds.
enum PaperclipDate {
    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Always three fraction digits, rounded to the millisecond. The formatter's
    /// own fraction truncates, so a parsed `.123` could come back as `.122`;
    /// `updatedSince` must echo the server's timestamp exactly.
    static func format(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1000)
        let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        return String(whole.dropLast()) + String(format: ".%03dZ", fraction)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid ISO 8601 date: \(text)"
                )
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
        return encoder
    }()
}
