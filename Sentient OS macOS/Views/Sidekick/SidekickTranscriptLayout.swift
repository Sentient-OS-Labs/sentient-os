import Foundation

/// Presentation only: original events, IDs and task outcomes stay untouched on disk.
nonisolated enum SidekickTranscriptLayout {
    typealias Record = SidekickConversationStore.Record
    struct Row: Identifiable {
        let record: Record
        let showsWork: Bool
        let timeBreak: Date?
        var id: String { record.event.id }
    }

    static func rows(_ records: [Record]) -> [Row] {
        var firstResponse: [UUID: String] = [:]
        for row in records where row.event.kind == .assistantMessage || row.event.kind == .question {
            if firstResponse[row.event.taskID] == nil { firstResponse[row.event.taskID] = row.event.id }
        }
        var result: [Row] = []
        var previousDate: Date?
        for record in records {
            let event = record.event
            guard [.userMessage, .assistantMessage, .question, .answer, .taskFinished].contains(event.kind) else { continue }
            let user = event.kind == .userMessage || event.kind == .answer
            let isEnding = event.kind == .taskFinished
            let visible = !isEnding || firstResponse[event.taskID] == nil
            if visible {
                let separated = result.isEmpty || (user && previousDate.map { event.createdAt.timeIntervalSince($0) > 30 * 60 } == true)
                result.append(Row(record: record,
                    showsWork: firstResponse[event.taskID] == event.id || isEnding,
                    timeBreak: separated ? event.createdAt : nil))
            }
            previousDate = max(previousDate ?? event.createdAt, event.createdAt)
        }
        return result
    }

    /// A hidden success/footer event still has a valid history-search destination.
    static func destination(_ id: String, records: [Record]) -> String {
        guard let ending = records.first(where: { $0.event.id == id }), ending.event.kind == .taskFinished else { return id }
        return records.first(where: {
            $0.event.taskID == ending.event.taskID && ($0.event.kind == .assistantMessage || $0.event.kind == .question)
        })?.event.id ?? id
    }

    static func duration(_ interval: TimeInterval) -> String? {
        guard interval.isFinite, interval >= 0 else { return nil }
        if interval < 1 { return "<1s" }
        let seconds = Int(min(interval, 315_576_000))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, remaining = seconds % 60
        if hours > 0 { return "\(hours)h" + (minutes > 0 ? " \(minutes)m" : "") }
        if minutes > 0 { return "\(minutes)m" + (remaining > 0 ? " \(remaining)s" : "") }
        return "\(remaining)s"
    }

    static func workLabel(state: SidekickConversationStore.TranscriptTaskState?, running: Bool,
                          waiting: Bool, now: Date = Date()) -> String {
        let interval = state?.startedAt.flatMap { start in
            (state?.finished?.event.createdAt ?? (running ? now : nil)).map { $0.timeIntervalSince(start) }
        }
        let elapsed = interval.flatMap(duration)
        if running {
            return (waiting ? "Waiting for your answer" : "Working") + (elapsed.map { " · " + $0 } ?? "…")
        }
        switch state?.finished?.event.outcome {
        case .stopped:
            let reason = state?.finished?.event.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let label = reason == "[stopped by user]" || reason == "stopped by user" ? "Stopped by you" : "Stopped"
            return label + (elapsed.map { " · " + $0 } ?? "")
        case .failed: return "Couldn’t finish" + (elapsed.map { " · " + $0 } ?? "")
        case .interrupted: return "Interrupted" + (elapsed.map { " · " + $0 } ?? "")
        case .success:
            if let elapsed { return state?.hasActivity == true ? "Worked for " + elapsed : "Responded in " + elapsed }
            return state?.hasActivity == true ? "Activity" : "Completed"
        case nil: return "Activity"
        }
    }

    static func timeBreakLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return format(date, template: "jm", calendar: calendar) }
        if days == 1 { return "Yesterday" }
        if (2...6).contains(days) { return "\(days) days ago" }
        return format(date, template: calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMMd" : "MMMMdy", calendar: calendar)
    }

    static func hoverDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return format(date, template: "jm", calendar: calendar) }
        if days == 1 { return "Yesterday, " + format(date, template: "jm", calendar: calendar) }
        if (2...6).contains(days) { return format(date, template: "EEEEjm", calendar: calendar) }
        return format(date, template: calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMMdjm" : "MMMd y jm", calendar: calendar)
    }

    private static func format(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
