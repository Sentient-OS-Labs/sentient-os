import AppKit

/// Captures document text and visual context together. Accessibility remains the primary source;
/// a screenshot also covers diagrams, canvas content and gaps in an app's accessibility tree.
@MainActor enum SummaryCapture {
    static func capture(displayID: CGDirectDisplayID, target: SummaryAccessibility.Target?) async throws -> SummarySource {
        guard target?.pid != getpid() else { throw SummaryAccessibility.Failure.ownApplication }
        guard Permissions.hasAccessibility() else {
            Permissions.requestAccessibility()
            throw SummaryAccessibility.Failure.permission
        }
        #if DEBUG
        let textOnly = UserDefaults.standard.bool(forKey: "summary.disableScreenshots")
        #else
        let textOnly = false
        #endif
        // Start the still promptly, in parallel with AX traversal, while the chosen document is visible.
        async let image: Data? = textOnly ? nil : ScreenCapture.summaryImage(displayID: displayID,
            windowPID: target?.pid, windowTitle: target?.windowTitle, windowFrame: target?.windowFrame)
        var source = SummarySource(application: target?.name ?? "App", scope: "visible screen only; accessibility text unavailable")
        if let target {
            let reader = Task.detached(priority: .userInitiated) { try SummaryAccessibility.read(target) }
            do {
                source = try await withTaskCancellationHandler { try await reader.value }
                    onCancel: { reader.cancel() }
            } catch is CancellationError { throw CancellationError() }
            catch SummaryAccessibility.Failure.permission { throw SummaryAccessibility.Failure.permission }
            catch { /* This application's document is not available through accessibility. */ }
        }
        try Task.checkCancellation()
        do {
            source.image = try await image
        } catch is CancellationError { throw CancellationError() }
        catch ScreenCapture.SummaryFailure.permission { throw ScreenCapture.SummaryFailure.permission }
        catch {
            // The image is supplementary. Keep readable AX text when a window is
            // temporarily uncapturable instead of failing an otherwise valid summary.
            guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error }
            Log("summary screenshot unavailable; continuing with accessibility text")
        }
        if source.text.isEmpty && source.image == nil { throw SummaryAccessibility.Failure.unavailable }
        return source
    }
}
