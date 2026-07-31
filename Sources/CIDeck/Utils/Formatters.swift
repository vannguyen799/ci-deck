import Foundation

enum Fmt {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// "3m ago", "2h ago"
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 5 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// "45s", "2m 10s", "1h 04m"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Truncates a commit subject to keep rows single-line.
    static func clip(_ text: String, max limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Percent-encodes a value for use inside a query string.
    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
