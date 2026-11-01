#if DEBUG
// Runs the real local Calendar pipeline into an in-memory store from an isolated test app.
// No vault generation, cloud provider calls, production preferences or production store writes.
import Foundation
import SwiftData

enum AppleCalendarAcceptanceTests {
    @MainActor static func run() async -> Int32 {
        guard Bundle.main.bundleIdentifier == "ai.sentientos.calendar-verification" else {
            Log("Calendar verification requires its isolated test app")
            return 1
        }
        do {
            let env = ProcessInfo.processInfo.environment
            guard let selection = UserDefaults(suiteName: "jesai.Sentient-OS-macOS")?.data(forKey: AppleCalendarSource.selectionKey),
                  let ids = try? JSONDecoder().decode([String].self, from: selection), !ids.isEmpty else {
                Log("Calendar verification: no selected calendars")
                return 1
            }
            AppleCalendarSource.saveSelection(Set(ids))
            if !AppleCalendarSource.hasAccess {
                guard env["CALENDAR_ACCEPTANCE_REQUEST_ACCESS"] == "1" else {
                    Log("Calendar verification: Calendar permission required")
                    return 77
                }
                guard try await AppleCalendarSource.requestAccess() else {
                    Log("Calendar verification: Calendar permission was not granted")
                    return 77
                }
            }
            guard let model = ModelLocator.resolve() else {
                Log("Calendar verification: local model unavailable")
                return 1
            }
            let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            let store = CycleStore(modelContainer: container)
            let engine = Engine(modelPath: model, maxNumTokens: AppleCalendarConnector.contextSize)
            try await engine.load()
            let run = IterativeRun(modelPath: model, store: store)
            let progress = await run.runCalendar(AppleCalendarConnector(calendarIDs: Set(ids)), engine: engine) { p in
                Log("Calendar verification: read=\(p.done)/\(p.total) unresolved=\(p.failed) committed=\(p.survivors)")
            }
            await engine.unload()
            let published = progress.successfulSources.contains("Apple Calendar") && progress.failed == 0
            let checkpoint = await store.pointer(AppleCalendarSource.bucketKey)
            Log("Calendar verification complete: published=\(published) checkpoint=\(checkpoint != nil) events=\(progress.done) failed=\(progress.failed)")
            return published && checkpoint != nil ? 0 : 1
        } catch {
            Log("Calendar verification failed: \(String(describing: type(of: error)))")
            return 1
        }
    }
}
#endif
