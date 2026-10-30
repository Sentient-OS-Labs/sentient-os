// Initial creation resumes on-device bookmarks, but replays unfinished cloud stages.
// Task-local scope keeps everyday incremental imports and explicit developer reads unchanged.
import Foundation

nonisolated enum InitialAnalysisRecovery {
    @TaskLocal static var replayCloudStages = false
}
