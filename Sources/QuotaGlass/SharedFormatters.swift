import Foundation

/// Shared date/number formatters. Formatter creation is comparatively
/// expensive, and DateFormatter/NumberFormatter are not documented as
/// thread-safe — usage fetches run on a concurrent task group — so every
/// access goes through a lock. The statics are `nonisolated(unsafe)` only
/// because the formatter classes are not Sendable; the lock makes shared
/// access actually safe.
enum SharedFormatters {
    private static let lock = NSLock()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let consoleDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter
    }()

    private static let resetDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm (EEE)"
        return formatter
    }()

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    /// Parses ISO-8601 with or without fractional seconds.
    static func iso8601Date(from value: String) -> Date? {
        lock.withLock {
            iso8601Fractional.date(from: value) ?? iso8601Plain.date(from: value)
        }
    }

    /// Fractional-seconds ISO-8601 string (Codex auth.json `last_refresh`).
    static func iso8601String(from date: Date) -> String {
        lock.withLock { iso8601Fractional.string(from: date) }
    }

    static func consoleDate(from value: String) -> Date? {
        lock.withLock { consoleDateParser.date(from: value) }
    }

    /// "M/d HH:mm (周X)" reset-time label, matching the previous checker style.
    static func resetString(from date: Date) -> String {
        lock.withLock { resetDateParser.string(from: date) }
    }

    static func usdString(from value: Double) -> String {
        lock.withLock {
            usdFormatter.maximumFractionDigits = value < 10 ? 2 : 0
            return usdFormatter.string(from: NSNumber(value: value)) ?? "$\(value)"
        }
    }
}
