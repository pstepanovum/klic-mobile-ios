import Foundation

/// Shared, lazily-built date formatters.
///
/// Allocating an `ISO8601DateFormatter` / `DateFormatter` is expensive (ICU setup), and
/// many call sites ran per row per render or inside socket hot loops. Every formatter
/// here is created once and only read afterwards: `ISO8601DateFormatter` is thread-safe,
/// and `DateFormatter` is thread-safe for formatting/parsing on iOS 7+ as long as it is
/// not mutated after creation — so never change a property on one of these.
///
/// App target only (not compiled into KlicShare / KlicWidgets / KlicBroadcast).
enum KlicDate {
    // MARK: ISO-8601

    /// `2026-10-03T12:34:56.789Z`
    static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `2026-10-03T12:34:56Z` — same output as a default `ISO8601DateFormatter()`.
    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse an ISO-8601 timestamp with or without fractional seconds.
    static func parse(_ iso: String) -> Date? {
        isoFractional.date(from: iso) ?? Self.iso.date(from: iso)
    }

    /// Optional-tolerant variant: nil/empty input returns nil.
    static func parse(optional iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return parse(iso)
    }

    /// ISO-8601 with fractional seconds (`…56.789Z`).
    static func isoFractionalString(_ date: Date) -> String {
        isoFractional.string(from: date)
    }

    /// "Now" stamp in the default `ISO8601DateFormatter()` format (`…56Z`, no fraction).
    static func nowISO() -> String {
        iso.string(from: Date())
    }

    // MARK: Display formatters (user's locale / time zone)

    private static func make(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    private static func make(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = date
        formatter.timeStyle = time
        return formatter
    }

    /// `3:26 PM`
    static let hourMinuteAMPM = make(format: "h:mm a")
    /// `October 3`
    static let monthNameDay = make(format: "MMMM d")
    /// `Oct 3`
    static let monthAbbrevDay = make(format: "MMM d")
    /// `10/03`
    static let monthDaySlash = make(format: "MM/dd")
    /// `10/03/26`
    static let monthDayYearSlash = make(format: "MM/dd/yy")
    /// `2026-10-03 15.26` (file names)
    static let fileStamp = make(format: "yyyy-MM-dd HH.mm")

    /// Locale-aware clock time (`3:26 PM` or `15:26`, honoring the 12/24-hour setting).
    static let shortTime = make(date: .none, time: .short)
    /// `10/3/26, 3:26 PM`
    static let shortDateShortTime = make(date: .short, time: .short)
    /// `Oct 3, 2026`
    static let mediumDate = make(date: .medium, time: .none)
}
