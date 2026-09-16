//
// CalendarEventTime.swift
// Decodes provider wall-clock/time-zone pairs without assuming this Mac's zone. Rejects
// nonexistent or ambiguous local times. Windows IDs use Unicode CLDR's bundled 001 map.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

nonisolated enum CalendarEventTime {
    private static let windows: [String: String] = {
        guard let url = Bundle.main.url(forResource: "WindowsTimeZones", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return mapping
    }()

    static func timeZone(_ name: String) -> TimeZone? {
        TimeZone(identifier: windows[name] ?? name)
    }

    static func date(_ value: Any?) -> Date? {
        guard let pair = value as? [String: Any], var text = pair["dateTime"] as? String,
              let zoneName = pair["timeZone"] as? String, let zone = timeZone(zoneName) else { return nil }
        if text.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil {
            return OutlookMailSource.date(text)
        }
        if text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$"#, options: .regularExpression) != nil { text += ":00" }
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?$"#,
                         options: .regularExpression) != nil else { return nil }
        let pieces = text.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard pieces.count == 6 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2],
                                        hour: pieces[3], minute: pieces[4], second: pieces[5])
        guard let approximate = calendar.date(from: components) else { return nil }
        let anchor = calendar.startOfDay(for: approximate).addingTimeInterval(-1)
        guard let first = calendar.nextDate(after: anchor, matching: components,
                                           matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: anchor, matching: components,
                                          matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last,
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first) == components else { return nil }
        let fraction = text.split(separator: ".", maxSplits: 1).dropFirst().first
            .flatMap { Double("0." + $0) } ?? 0
        return first.addingTimeInterval(fraction)
    }

    static func overlaps(start: Date, end: Date, window: MCPSource.Window) -> Bool {
        start < window.upper && end > window.lower
    }
}
