// Formats server-reported hosted allowance without inferring time from a local clock.
// The reset instant is supplied by the service and displayed in the user's time zone.
// Doc: Views/Settings/Documentation - Settings.md

import Foundation

enum SentientUsagePresentation {
    static func remaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "Daily Sidekick allowance used" }
        if seconds < 60 { return "Less than a minute left today" }
        let minutes = Int(min(seconds, 3_600) / 60)
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") left today"
    }

    static func reset(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return "Resets \(formatter.string(from: date)) (\(timeZone.abbreviation(for: date) ?? timeZone.identifier))"
    }
}
