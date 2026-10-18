// One full analysis: local reads, hosted reads, and the existing ProactiveCycle tail.
// The app-owned coordinator supplies cancellation and presentation-independent progress.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation

struct ProcessingRequest {
    var modelPath: String?
    var connectors: [any Connector]
    var mode: IterativeRun.Mode = .auto
    var runGmail = false
    var runCalendar = false
    var mcpSlugs: [String] = []
    var fullCycle = true

    var hasSources: Bool { !connectors.isEmpty || runGmail || runCalendar || !mcpSlugs.isEmpty }

    static func current() -> ProcessingRequest {
        let d = UserDefaults.standard
        return ProcessingRequest(modelPath: ModelLocator.resolve(),
            connectors: RunSource.connectors(from: SourceSelection.current(fdaGranted: Permissions.hasFullDiskAccess())),
            runGmail: ModelBackend.connectorsAvailable && d.bool(forKey: "dbg.run.gmail"),
            runCalendar: ModelBackend.connectorsAvailable && d.bool(forKey: "dbg.run.calendar"),
            mcpSlugs: MCPSource.kbSlugs())
    }
}

@MainActor
final class ProcessingRun {
    struct Result {
        var progress: RunProgress
        var failure: CycleFailure?
        var hadDiagnostics = false
        var complete: Bool {
            failure == nil && !progress.diskFull && progress.sourceReadFailures.isEmpty
                && progress.failed == 0 && progress.extractionFailed == 0
                && !progress.mailIncomplete && progress.mailDeferred == 0 && !hadDiagnostics
        }
    }

    let request: ProcessingRequest
    let scheduled: Bool
    private var unavailableConnectors: Set<String> = []
    private var mode: IterativeRun.Mode { request.mode }
    init(request: ProcessingRequest, scheduled: Bool) { self.request = request; self.scheduled = scheduled }

    func execute(progress: @escaping @Sendable (RunProgress) -> Void,
                 phase: @escaping @Sendable (ProactiveCyclePhase) -> Void,
                 onLine: @escaping @Sendable (String) -> Void) async -> Result {
        await Diagnostics.withOperation("processing") {
            var p = RunProgress()
            if !request.connectors.isEmpty, let path = request.modelPath {
                p = await IterativeRun(modelPath: path).run(request.connectors, mode: mode, onProgress: progress)
            }
            // Cancellation is checked at EVERY leg boundary. Stopping a read must never launch
            // another cloud request or publish the knowledge base while the old task drains.
            if Task.isCancelled || p.diskFull { return Result(progress: p) }
            if request.runGmail { p = await runGmailLeg(base: p, yield: progress) }
            if Task.isCancelled { return Result(progress: p) }
            if request.runCalendar { p = await runCalendarLeg(base: p, yield: progress) }
            if Task.isCancelled { return Result(progress: p) }
            if !request.mcpSlugs.isEmpty { p = await runMCPLeg(base: p, yield: progress) }
            if Task.isCancelled { return Result(progress: p) }
            progress(p)
            var failure: CycleFailure?
            if request.fullCycle {
                failure = await ProactiveCycle.shared.run(scheduled: scheduled,
                    unavailableConnectors: unavailableConnectors, progress: phase, onLine: onLine)
            }
            return Result(progress: p, failure: failure, hadDiagnostics: Diagnostics.current?.hasFailure == true)
        }
    }

    /// Cloud Gmail leg — each weekly window maps onto the SAME bar/card: its prompt → the prompt
    /// pane, its summary → the just-processed card, the windows → the bar (extended past `base`, the
    /// device leg's final counts).
    private func runGmailLeg(base: RunProgress,
                             yield: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        let box = ProgressBox(base)
        let baseTotal = base.total, baseDone = base.done, baseKept = base.survivors, baseJunk = base.junk
        let onProgress: @Sendable (GmailConnect.Progress) -> Void = { ev in
            switch ev {
            case let .windowStart(total, label, prompt):
                // All windows start together (parallel); the bar advances only as they finish below.
                var p = box.value
                p.total = baseTotal + total
                p.lastPrompt = prompt
                p.lastPath = "Gmail · \(label)"
                p.lastItemDate = nil
                box.value = p
                yield(p)
            case let .windowDone(total, label, summary, threads, completed, keptSoFar):
                var p = box.value
                p.total       = baseTotal + total
                p.done        = baseDone + completed
                p.survivors   = baseKept + keptSoFar
                p.junk        = baseJunk + (completed - keptSoFar)   // a window with nothing notable
                p.lastTitle   = "Email · \(label)"
                p.lastSummary = summary
                p.lastVerdict = summary == nil ? .junk : .survivor
                p.lastFilePath = nil
                p.lastPath    = "Gmail · \(label)" + (threads > 0 ? " · \(threads) threads" : "")
                p.lastItemDate = nil
                p.lastSeconds = nil
                box.value = p
                yield(p)
            }
        }
        do {
            // Only the explicit force-initial mode does a full re-read; `.auto` and `.iterative` both
            // use runIterative — which itself falls back to a full initial read when Gmail has no mark
            // yet. (Same auto behavior the scheduler relies on; keeps every entry point in agreement.)
            _ = mode == .initial ? try await GmailConnect.runInitial(onProgress: onProgress)
                                 : try await GmailConnect.runIterative(onProgress: onProgress)
        } catch {
            if Task.isCancelled || error is CancellationError { return box.value }
            if ConnectorReadFailure.isConnectionFailure(error) {
                unavailableConnectors.insert("gmail")
                var p = box.value
                p.failSourceRead(name: "Gmail", message: "Reconnect Gmail to retry this source.")
                return p
            }
            var p = box.value
            Diagnostics.report(.sourceReadFailed, phase: .read, reason: "hosted_source", error: error, source: "gmail")
            p.failSourceRead(name: "Gmail", message: "Gmail could not be read. Your progress is saved; retry analysis.")
            p.lastTitle = "Gmail failed"
            p.lastItemDate = nil
            p.lastSummary = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            p.lastVerdict = .junk
            p.lastFilePath = nil
            box.value = p
            yield(p)
            Log("ProcessingRun.gmail: ✗ \(ErrorLabel(error))")
        }
        return box.value
    }

    /// Cloud Google Calendar leg — twin to the Gmail leg: each date window (a month, or the iterative
    /// since-mark window) maps onto the SAME bar/card, extended past `base` (the prior legs' counts).
    private func runCalendarLeg(base: RunProgress,
                                yield: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        let box = ProgressBox(base)
        let baseTotal = base.total, baseDone = base.done, baseKept = base.survivors, baseJunk = base.junk
        let onProgress: @Sendable (CalendarConnect.Progress) -> Void = { ev in
            switch ev {
            case let .windowStart(step, total, label, prompt):
                var p = box.value
                p.total = baseTotal + total
                p.done  = baseDone + (step - 1)
                p.lastPrompt = prompt
                p.lastPath = "Calendar · \(label)"
                p.lastItemDate = nil
                box.value = p
                yield(p)
            case let .windowDone(step, total, label, summary, events, keptSoFar):
                var p = box.value
                p.total       = baseTotal + total
                p.done        = baseDone + step
                p.survivors   = baseKept + keptSoFar
                p.junk        = baseJunk + (step - keptSoFar)   // a window with nothing notable
                p.lastTitle   = "Calendar · \(label)"
                p.lastSummary = summary
                p.lastVerdict = summary == nil ? .junk : .survivor
                p.lastFilePath = nil
                p.lastPath    = "Calendar · \(label)" + (events > 0 ? " · \(events) events" : "")
                p.lastItemDate = nil
                p.lastSeconds = nil
                box.value = p
                yield(p)
            }
        }
        do {
            // Force-initial only on `.initial`; `.auto`/`.iterative` → runIterative (which falls back
            // to a full initial read when Calendar has no mark yet). Matches the Gmail leg + scheduler.
            _ = mode == .initial ? try await CalendarConnect.runInitial(onProgress: onProgress)
                                 : try await CalendarConnect.runIterative(onProgress: onProgress)
        } catch {
            if Task.isCancelled || error is CancellationError { return box.value }
            if ConnectorReadFailure.isConnectionFailure(error) {
                unavailableConnectors.insert("google-calendar")
                var p = box.value
                p.failSourceRead(name: "Calendar", message: "Reconnect Calendar to retry this source.")
                return p
            }
            var p = box.value
            Diagnostics.report(.sourceReadFailed, phase: .read, reason: "hosted_source", error: error, source: "google-calendar")
            p.failSourceRead(name: "Calendar", message: "Calendar could not be read. Your progress is saved; retry analysis.")
            p.lastTitle = "Calendar failed"
            p.lastItemDate = nil
            p.lastSummary = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            p.lastVerdict = .junk
            p.lastFilePath = nil
            box.value = p
            yield(p)
            Log("ProcessingRun.calendar: ✗ \(ErrorLabel(error))")
        }
        return box.value
    }

    /// The generic connector KB legs (KB-toggled connectors, via MCPSource.runAll — always
    /// iterative-with-fallback, same as the 3am run). The bar gets ONE slot per connector; each
    /// window's label/summary rides the same card, and source failures remain visible through
    /// later sources and the cloud tail without being counted as junk.
    private func runMCPLeg(base: RunProgress,
                           yield: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        let box = ProgressBox(base)
        let baseTotal = base.total, baseDone = base.done
        let onEvent: @Sendable (String, Int, Int, MCPSource.Progress) -> Void = { slug, index, total, ev in
            let name = ConnectorRegistry.displayName(slug: slug)
            switch ev {
            case let .windowStart(_, _, label, prompt):
                var p = box.value
                p.total = baseTotal + total
                p.beginSourceRead(name: name, label: label, prompt: prompt)
                box.value = p
                yield(p)
            case let .windowDone(step, windows, label, summary, items, _):
                var p = box.value
                p.total = baseTotal + total
                // The connector's final window completes its bar slot; inner windows (the Step 3
                // windowed adapters) just refresh the card.
                if step == windows { p.done = baseDone + index + 1 }
                if summary != nil { p.survivors += 1 } else { p.quietReads += 1 }
                p.finishSourceRead(name: name, label: label, summary: summary, items: items)
                box.value = p
                yield(p)
            case let .failed(label, message):
                var p = box.value
                p.total = baseTotal + total
                p.done = baseDone + index + 1
                p.failSourceRead(name: label, message: message)
                box.value = p
                yield(p)
            }
        }
        let (outcomes, limited) = await MCPSource.runAll(selectedSlugs: request.mcpSlugs, onEvent: onEvent)
        unavailableConnectors.formUnion(outcomes.filter { $0.result == "connector_auth" }.map(\.slug))
        var final = box.value
        final.done = max(final.done, baseDone + outcomes.count)
        final.total = max(final.total, baseTotal + outcomes.count)
        box.value = final
        if limited {
            if scheduled { OvernightCaution.record(.usageLimit) }
            Log("ProcessingRun.mcp: usage limit; remaining connector reads skipped")
        }
        return box.value
    }
}

/// Thread-safe holder so the Gmail leg's `@Sendable` progress callback can accumulate onto the
/// device leg's final counts and hand the final value back (mirrors CodexCLI's PipeDrain pattern).
private nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var p: RunProgress
    init(_ p: RunProgress) { self.p = p }
    var value: RunProgress {
        get { lock.lock(); defer { lock.unlock() }; return p }
        set { lock.lock(); p = newValue; lock.unlock() }
    }
}
