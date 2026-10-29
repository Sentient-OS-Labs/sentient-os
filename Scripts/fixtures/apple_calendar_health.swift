// Exercise native Calendar projection and health messages without reading EventKit or preferences.
import Foundation

final class MemoryPreferences {
    private var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func string(forKey key: String) -> String? { values[key] as? String }
}
enum UserDefaults { static let standard = MemoryPreferences() }
enum ChatWindowing { static func clampToContext(_ text: String) -> String { text } }
struct NoteDraft {
    let kind: SourceKind; let sourceID: String; let folder: String; let itemDate: Date
    let text: String; let title: String?; let reminderFlagged: Bool
}
@main struct CalendarHealthHarness {
    static func check(_ name: String, _ value: Bool) {
        guard value else { fatalError("FAIL \(name)") }
        print("PASS \(name)")
    }
    static func main() throws {
        AppleCalendarSource.recordIssue(.model, attempted: 212, failed: 8)
        check("health reports precise unresolved counts", AppleCalendarSource.issueMessage("model")!.contains("212 calendar events; 8 could not be analyzed after retries"))
        AppleCalendarSource.recordIssue(.model)
        check("model-load failure clears old counts", UserDefaults.standard.dictionary(forKey: AppleCalendarSource.issueCountsKey) == nil)
        AppleCalendarSource.recordIssue(.model, attempted: 212, failed: 8)
        AppleCalendarSource.saveSelection(["fixture-calendar"])
        check("selection change clears issue and counts", UserDefaults.standard.string(forKey: AppleCalendarSource.issueKey) == nil && UserDefaults.standard.dictionary(forKey: AppleCalendarSource.issueCountsKey) == nil)
        AppleCalendarSource.recordIssue(.model, attempted: 212, failed: 8)
        AppleCalendarSource.clearIssue()
        check("successful commit clears issue and counts", UserDefaults.standard.string(forKey: AppleCalendarSource.issueKey) == nil && UserDefaults.standard.dictionary(forKey: AppleCalendarSource.issueCountsKey) == nil)
        let schedule = "Authoritative schedule"
        let title = "A \"quoted\" title"
        let notes = String(repeating: "line\n\\\"", count: 800)
        let projected = try AppleCalendarSource.project(title: title, notes: notes, location: "", schedule: schedule)
        let fields = try JSONDecoder().decode([String: String].self, from: Data(projected.content.utf8))
        check("native projection retains escaped title", fields["title"] == title)
        check("native projection bounds long notes", fields["truncated"] == "true" && fields["schedule"] == schedule)
        let privateInput = try AppleCalendarSource.project(title: "Access review", notes: "Password: synthetic-fixture-only", location: "", schedule: schedule)
        check("native credential preflight stays sensitive", privateInput.risk == "sensitive")
        print("Calendar native health suite complete")
    }
}
