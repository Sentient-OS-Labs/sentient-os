// IterativeRun+AppleCalendar.swift
// Classifies a complete local calendar window, then validates and saves it atomically.
// Previews are ephemeral; failed or cancelled batches never count unsaved notes as kept.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation

private enum CalendarRunFailure: Error { case analysis, model, storage, deadline }

extension IterativeRun {
    func runCalendar(_ connector: AppleCalendarConnector, engine: Engine,
                     onProgress: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        var p = RunProgress()
        var generations = 0, runtimeFailures = 0
        var notes: [NoteDraft] = []
        let name = "Apple Calendar"
        let deadline = Date().addingTimeInterval(Self.sourceTimeCapSeconds)
        var diagnosticPhase: Diagnostics.Phase = .snapshot
        await store.invalidateCalendarSnapshot()
        AppleCalendarSource.recordIssue()
        SourceHealth.recordReadOutcome(source: "apple_calendar", outcome: "incomplete")
        do {
            let buckets = try await withExtractionTimeout(Self.extractionTimeoutSeconds) { try connector.buckets(since: [:]) }
            guard buckets.count == 1, let snapshot = buckets.first?.snapshot else { throw AppleCalendarSource.ReadError.invalidEvent }
            var cache = try await store.calendarRetryCache(for: snapshot)
            // Persist pruning before model work so edited or newly sensitive content is removed.
            guard await store.saveCalendarRetryCache(cache) == .saved else { throw CalendarRunFailure.storage }
            p.total = snapshot.events.count
            onProgress(p)
            var pending = snapshot.events.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) })
                .map { (event: $0, reason: Optional<Triage.ReplyFailure>.none) }
            // Keep successful decisions in memory. A bounded recovery pass visits only invalid
            // replies, after rebuilding the engine; no event is committed until all are resolved.
            for pass in 0..<2 {
                var deferred: [(event: AppleCalendarSource.Event, reason: Triage.ReplyFailure?)] = []
                for (event, previousFailure) in pending {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw CalendarRunFailure.deadline }
                    var seconds = 0.0
                    var loaded = false
                    do {
                        diagnosticPhase = .extract
                        let artifact = try await withExtractionTimeout(Self.extractionTimeoutSeconds) { try connector.load(event.candidate) }
                        loaded = true
                        var decision = Triage.calendarInputDecision(for: artifact)
                        if decision == nil, let saved = cache.survivors[event.id] {
                            decision = Triage.Outcome(verdict: .survivor, title: saved.title, summary: saved.summary, reason: .survivor)
                        }
                        if decision == nil {
                            if generations >= Self.preemptiveReloadEvery {
                                try await engine.reload(); generations = 0
                            }
                            let prompt = Triage.prompt(for: artifact, currentDate: Date())
                            var failure = previousFailure
                            let attempts = pass == 0 ? 0..<2 : 2..<3
                            for attempt in attempts {
                                try Task.checkCancellation()
                                guard Date() < deadline else { throw CalendarRunFailure.deadline }
                                diagnosticPhase = .generate
                                let correction = failure.map { Triage.calendarRetryInstruction(for: $0) } ?? ""
                                let result = try await engine.generate(prompt: prompt + correction, samplingSeed: attempt)
                                generations += 1; seconds += result.totalTime
                                switch Triage.calendarReply(result.text, for: artifact) {
                                case .success(let outcome): decision = outcome
                                case .failure(let reason):
                                    Log("Apple Calendar reply deferred: \(reason.rawValue), attempt=\(attempt + 1), bytes=\(result.text.utf8.count)")
                                    failure = reason
                                    if attempt == attempts.upperBound - 1 {
                                        if pass == 1 {
                                            Diagnostics.report(.modelOutputInvalid, phase: .parse, reason: "calendar_reply", error: reason, source: "apple_calendar", counts: [.bytes: result.text.utf8.count, .retries: attempt])
                                        }
                                        throw reason
                                    }
                                }
                                if decision != nil { break }
                            }
                        }
                        guard let decision else { throw Triage.ReplyFailure.invalidJSON }
                        try Task.checkCancellation()
                        runtimeFailures = 0
                        switch decision.verdict {
                        case .survivor:
                            if !event.revision.isEmpty, cache.survivors[event.id] == nil {
                                cache.survivors[event.id] = .init(revision: event.revision, summary: decision.summary, title: decision.title)
                                guard await store.saveCalendarRetryCache(cache) == .saved else { throw CalendarRunFailure.storage }
                            }
                            notes.append(NoteDraft(kind: .appleCalendar, sourceID: event.id, folder: name,
                                itemDate: event.start, text: decision.summary + "\n" + event.schedule,
                                title: decision.title, reminderFlagged: false))
                        case .junk: p.junk += 1
                        case .sensitive: p.sensitive += 1
                        }
                        p.lastTitle = decision.title
                        p.lastSummary = decision.summary.isEmpty ? nil : decision.summary
                        p.lastVerdict = decision.verdict
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as AppleCalendarSource.ReadError { throw error }
                    catch let error as CalendarRunFailure { throw error }
                    catch let reason as Triage.ReplyFailure where pass == 0 {
                        deferred.append((event, reason)); runtimeFailures = 0
                        p.lastTitle = "Calendar event awaiting another try"
                        p.lastSummary = "Other events will finish before this event is tried again."
                        p.lastVerdict = nil
                    }
                    catch {
                        Diagnostics.report(.sourceReadFailed, phase: diagnosticPhase, error: error, source: "apple_calendar", flags: [.retriable: true], terminal: true)
                        p.failed += 1
                        p.lastTitle = "Analysis deferred"
                        p.lastVerdict = nil
                        if !loaded {
                            p.extractionFailed += 1; runtimeFailures = 0
                            p.lastTitle = "Calendar event unavailable"
                            p.lastSummary = "An event could not be read. Calendar analysis will retry this window."
                            Log("Apple Calendar event deferred: \(String(describing: type(of: error)))")
                        } else if let reason = error as? Triage.ReplyFailure {
                            p.parseFailures += 1; runtimeFailures = 0
                            p.lastSummary = "The local model returned an incomplete answer. Completed safe summaries are saved for the next attempt."
                            Log("Apple Calendar analysis deferred: \(reason.rawValue)")
                        } else {
                            runtimeFailures += 1
                            p.lastSummary = "The on-device model could not finish. This calendar window remains queued for another analysis."
                            Log("Apple Calendar generation failed: \(String(describing: type(of: error)))")
                        }
                    }
                    p.lastPath = name; p.lastFilePath = nil; p.lastPrompt = nil; p.lastSeconds = seconds > 0 ? seconds : nil
                    p.totalSeconds += seconds; p.done += pass == 0 ? 1 : 0
                    onProgress(p)
                    if runtimeFailures == 3 || runtimeFailures >= 6 {
                        do { try await engine.reload(); generations = 0 }
                        catch { throw CalendarRunFailure.model }
                        if runtimeFailures >= 6 { throw CalendarRunFailure.model }
                    }
                }
                if deferred.isEmpty { break }
                try Task.checkCancellation()
                guard Date() < deadline else { throw CalendarRunFailure.deadline }
                diagnosticPhase = .generate
                do { try await engine.reload(); generations = 0 }
                catch is CancellationError { throw CancellationError() }
                catch {
                    p.failed += deferred.count; p.parseFailures += deferred.count
                    throw CalendarRunFailure.model
                }
                pending = deferred
                p.lastTitle = "Retrying Calendar analysis"
                p.lastSummary = "Read \(p.done) calendar events. Retrying \(pending.count) events; completed results remain in memory."
                p.lastVerdict = nil
                onProgress(p)
            }
            try Task.checkCancellation()
            guard p.failed == 0 else { throw CalendarRunFailure.analysis }
            guard Date() < deadline else { throw CalendarRunFailure.deadline }
            diagnosticPhase = .validate
            try await withExtractionTimeout(Self.extractionTimeoutSeconds) { try snapshot.validate() }
            try Task.checkCancellation()
            guard Date() < deadline else { throw CalendarRunFailure.deadline }
            diagnosticPhase = .commit
            let result = await store.commitCalendarSnapshot(snapshot, notes: notes)
            guard result == .saved else {
                try Task.checkCancellation()
                p.diskFull = result == .diskFull
                throw CalendarRunFailure.storage
            }
            // Lifetime counters, like kept counts, describe the saved batch. A cancelled,
            // changed or failed snapshot must not count rejected events again on retry.
            p.survivors = notes.count
            for _ in notes { LifetimeStats.bump(.survivor) }
            for _ in 0..<p.junk { LifetimeStats.bump(.junk) }
            for _ in 0..<p.sensitive { LifetimeStats.bump(.sensitive) }
            p.successfulSources.insert(name)
            AppleCalendarSource.clearIssue()
            SourceHealth.recordReadOutcome(source: "apple_calendar", outcome: "ok")
            if snapshot.events.isEmpty {
                p.quietReads += 1
                p.finishSourceRead(name: name, label: name, summary: nil, items: 0)
                p.lastTitle = "No events in selected calendars"
                p.lastSummary = "No events were found in the analysis window: the past seven days, today, and the next thirty days."
            }
        } catch is CancellationError {
            AppleCalendarSource.recordIssue()
            p.lastPath = name; p.lastPrompt = nil; p.lastVerdict = nil
            p.lastTitle = "Calendar analysis paused"
            p.lastSummary = "Completed safe summaries are saved for retry. The schedule will appear after the full window is checked."
            p.sourceReadFailures[name] = p.lastSummary
        } catch {
            Diagnostics.report(.sourceReadDegraded, phase: diagnosticPhase, error: error, source: "apple_calendar",
                               counts: [.attempted: p.done, .failed: p.failed], flags: [.partial: true, .previousStateRetained: true])
            if let failure = error as? CalendarRunFailure {
                switch failure {
                case .model: AppleCalendarSource.recordIssue(.model, attempted: p.done, failed: p.failed)
                case .analysis:
                    AppleCalendarSource.recordIssue(p.extractionFailed == p.failed ? .incomplete : .model,
                                                    attempted: p.done, failed: p.failed)
                case .storage: AppleCalendarSource.recordIssue(.storage)
                case .deadline: AppleCalendarSource.recordIssue(.deadline)
                }
            } else { AppleCalendarSource.recordIssue(error) }
            let message = AppleCalendarSource.issueMessage(UserDefaults.standard.string(forKey: AppleCalendarSource.issueKey) ?? "incomplete")
                ?? "Calendar analysis did not finish. Try analysis again."
            p.failSourceRead(name: name, message: message, countFailure: p.failed == 0)
            Log("Apple Calendar snapshot not published: \(String(describing: type(of: error)))")
        }
        onProgress(p)
        return p
    }
}
