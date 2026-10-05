// IterativeRun+AppleMail.swift
// Account/generation frontiers, deferred-body retries and periodic reconciliation for Mail.
// Every classification is committed atomically with progress. Doc: Ingestion/Documentation - Ingestion Pipeline.md

import Foundation

private enum MailRunFailure: Error { case deadline, model, storage }

extension IterativeRun {
    /// Uses the run's single local engine; all disk work is on a utility task, away from UI work.
    func runMail(_ connector: AppleMailConnector, engine: Engine,
                 onProgress: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        var p = RunProgress()
        var generations = 0
        var modelFailures = 0
        let deadline = Date().addingTimeInterval(3600)
        var diagnosticPhase: Diagnostics.Phase = .snapshot
        defer {
            if !Task.isCancelled, p.failed > 0 || p.extractionFailed > 0 {
                Diagnostics.report(.sourceReadDegraded, phase: .complete, reason: "mail_deferred", source: "apple_mail",
                                   counts: [.attempted: p.done, .failed: p.failed, .deferred: p.mailDeferred, .skipped: p.extractionFailed],
                                   flags: [.partial: p.mailIncomplete, .retriable: true])
            }
        }
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try AppleMailSnapshot(root: AppleMailSource.root(), selected: connector.accounts)
            }.value
            let available = Set(snapshot.accounts.map(\.id))
            guard connector.accounts.isSubset(of: available) else { throw AppleMailError.access }
            let accounts = connector.accounts.sorted()
            for (offset, account) in accounts.enumerated() {
                try Task.checkCancellation()
                let remaining = AppleMailConnector.maximumMessagesPerPass - p.done
                guard remaining > 0 else { p.mailIncomplete = true; break }
                // Share the pass across accounts so one large archive cannot starve another inbox.
                let accountBudget = max(1, remaining / (accounts.count - offset))
                let bucket = "appleMail:" + account
                let rows = snapshot.rows.filter { $0.account == account }
                var state = try await store.mailCheckpoint(bucket)
                    ?? AppleMailCheckpoint(generation: snapshot.generation, top: rows.first?.id ?? 0)
                var receipts = try await store.mailReceipts(bucket)
                let work = state.prepare(generation: snapshot.generation, rows: rows, now: Date(), limit: accountBudget)
                // Remove pending summaries of rows now excluded or absent. Receipts are survivors
                // only; deletion therefore leaves no rejected-message ledger.
                let eligible = Set(rows.filter { !$0.excluded }.map(\.id))
                let eligibleKeys = Set(rows.filter { !$0.excluded }.map { AppleMailSource.messageKey(salt: state.salt, row: $0) })
                let invalid = Set(receipts.values.filter {
                    $0.messageKey.map { !eligibleKeys.contains($0) }
                        ?? ($0.generation != snapshot.generation || !eligible.contains($0.rowID))
                }.map(\.identity))
                diagnosticPhase = .commit
                let start = await store.commitMail(bucketKey: bucket, state: state, remove: invalid)
                guard start == .saved else { p.diskFull = start == .diskFull; throw MailRunFailure.storage }
                for identity in invalid { receipts.removeValue(forKey: identity) }
                try await Task.detached(priority: .utility) { try snapshot.indexFiles(account: account) }.value
                p.mailDeferred += state.deferred.count
                p.total += work.count
                onProgress(p)
                for item in work {
                    try Task.checkCancellation()
                    if Date() >= deadline { throw MailRunFailure.deadline }
                    let row = item.row
                    var retry = false, draft: NoteDraft?, receipt: AppleMailReceiptValue?
                    var remove = Set<String>()
                    var decision: Triage.Outcome?
                    var seconds: Double?
                    var loadedBody = false
                    var failureReason: String?
                    if !row.excluded || row.previewJunk {
                        do {
                            diagnosticPhase = .extract
                            let message = try await Task.detached(priority: .utility) { try snapshot.body(row, includeJunkPreview: true) }.value
                            loadedBody = true
                            let forcedJunk = row.excluded || AppleMailMIME.excluded(message.headers)
                            let identity = AppleMailSource.identity(salt: state.salt, row: row, message: message)
                            remove = Set(receipts.values.filter {
                                $0.generation == snapshot.generation && $0.rowID == row.id && $0.identity != identity
                            }.map(\.identity))
                            if forcedJunk { remove.insert(identity) }
                            let hash = AppleMailSource.contentDigest(message, sent: row.sent)
                            receipt = AppleMailReceiptValue(identity: identity, contentHash: hash,
                                generation: snapshot.generation, rowID: row.id,
                                messageKey: AppleMailSource.messageKey(salt: state.salt, row: row))
                            if forcedJunk || receipts[identity]?.contentHash != hash {
                                if generations >= 40 {
                                    do { try await engine.reload(); generations = 0 }
                                    catch { throw MailRunFailure.model }
                                }
                                // Raw routing headers, attachments and paths stay outside the model input.
                                let artifact = AppleMailSource.artifact(row: row, identity: identity, message: message)
                                let prompt = Triage.prompt(for: artifact, currentDate: Date())
                                var parsed: Triage.Outcome?
                                // One fresh attempt can recover transient formatting failures. Never guess
                                // missing privacy decisions or save a partially parsed response.
                                for attempt in 0..<2 {
                                    try Task.checkCancellation()
                                    diagnosticPhase = .generate
                                    let response = try await engine.generate(prompt: prompt + (attempt == 0 ? "" : Triage.mailRetryInstruction))
                                    generations += 1
                                    seconds = (seconds ?? 0) + response.totalTime
                                    switch Triage.mailReply(response.text) {
                                    case .success(let result): parsed = result
                                    case .failure(let reason):
                                        Log("Apple Mail reply deferred: \(reason.rawValue), attempt=\(attempt + 1), bytes=\(response.text.utf8.count)")
                                        if attempt == 1 {
                                            Diagnostics.report(.modelOutputInvalid, phase: .parse, reason: "mail_reply", error: reason, source: "apple_mail", counts: [.bytes: response.text.utf8.count, .retries: 1])
                                            throw reason
                                        }
                                    }
                                    if parsed != nil { break }
                                }
                                guard let parsed else { throw Triage.ReplyFailure.invalidJSON }
                                // Metadata policy wins even if the model calls a promotion useful.
                                // Sensitive always wins over junk; only safe previews reach the card.
                                let outcome = forcedJunk && parsed.verdict != .sensitive
                                    ? Triage.Outcome(verdict: .junk, title: parsed.title, summary: parsed.summary, reason: .modelJunk)
                                    : parsed
                                decision = outcome
                                modelFailures = 0
                                if outcome.verdict == .survivor {
                                    draft = NoteDraft(kind: .appleMail, sourceID: identity, folder: "Apple Mail", itemDate: row.date,
                                        text: outcome.summary, title: outcome.title, reminderFlagged: false)
                                } else { remove.insert(identity); receipt = nil }
                            }
                        } catch AppleMailMIME.Failure.noText {
                            // A fully decoded empty body has nothing to classify. Download stubs
                            // have a separate unavailable error and stay in the deferred queue.
                            decision = Triage.Outcome(verdict: .junk, title: nil, summary: "", reason: .emptySummary)
                            remove = Set(receipts.values.filter { $0.generation == snapshot.generation && $0.rowID == row.id }.map(\.identity))
                        } catch AppleMailMIME.Failure.excluded {
                            // Header policy rejection stores neither headers nor an identity.
                            remove = Set(receipts.values.filter { $0.generation == snapshot.generation && $0.rowID == row.id }.map(\.identity))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            if loadedBody {
                                Diagnostics.report(.sourceReadFailed, phase: diagnosticPhase, error: error, source: "apple_mail", flags: [.retriable: true], terminal: true)
                            }
                            retry = true; receipt = nil; draft = nil
                            if loadedBody {
                                p.failed += 1
                                // Malformed JSON is a deferred classification, not a broken GPU.
                                // Repeated bad outputs must not starve all remaining message bodies.
                                if let reason = error as? Triage.ReplyFailure {
                                    p.parseFailures += 1; modelFailures = 0
                                    failureReason = "The local model returned an incomplete answer. This email remains queued for another analysis."
                                    Log("Apple Mail analysis deferred: \(reason.rawValue)")
                                } else {
                                    modelFailures += 1
                                    failureReason = "The on-device model could not finish. This email remains queued for another analysis."
                                    Log("Apple Mail generation failed: \(String(describing: type(of: error)))")
                                }
                            } else {
                                p.extractionFailed += 1
                                let reason = (error as? AppleMailMIME.Failure).map { String(describing: $0) }
                                    ?? (error as? AppleMailError).map { String(describing: $0) } ?? "readError"
                                if let mime = error as? AppleMailMIME.Failure,
                                   [.malformed, .unsupported, .invalidTransferEncoding, .invalidText].contains(mime) {
                                    failureReason = "This message uses an unsupported or damaged format. It remains queued; the rest of your mail can still be analyzed."
                                }
                                Log("Apple Mail body deferred: \(reason)")
                            }
                        }
                    }
                    try Task.checkCancellation()
                    var next = state
                    next.finish(item, retry: retry)
                    diagnosticPhase = .commit
                    let outcome = await store.commitMail(bucketKey: bucket, state: next, note: draft, receipt: receipt, remove: remove)
                    guard outcome == .saved else { p.diskFull = outcome == .diskFull; throw MailRunFailure.storage }
                    p.mailDeferred += next.deferred.count - state.deferred.count
                    state = next
                    for identity in remove { receipts.removeValue(forKey: identity) }
                    if let receipt { receipts[receipt.identity] = receipt }
                    // Display/counters only after a successful commit. Junk text stays in this ephemeral card.
                    // Keep the previous card intact if this attempt is cancelled or cannot be saved.
                    p.lastPath = "Apple Mail"; p.lastFilePath = nil; p.lastPrompt = nil
                    p.lastItemDate = row.date.timeIntervalSince1970 > 0 ? row.date : nil
                    p.lastTitle = nil; p.lastSummary = nil; p.lastVerdict = nil
                    p.lastSeconds = seconds; p.totalSeconds += seconds ?? 0
                    if let decision {
                        LifetimeStats.bump(decision.verdict)
                        switch decision.verdict {
                        case .survivor: p.survivors += 1; p.lastTitle = decision.title; p.lastSummary = decision.summary
                        case .junk: p.junk += 1; p.lastTitle = decision.title; p.lastSummary = decision.summary
                        case .sensitive: p.sensitive += 1
                        }
                        p.lastVerdict = decision.verdict
                        if decision.reason == .emptySummary {
                            p.lastTitle = "No message text"
                            p.lastSummary = "This email has no readable body text. Attachments are not analyzed."
                        }
                    } else if retry {
                        p.lastTitle = loadedBody ? "Analysis deferred" : "Message unavailable"
                        p.lastSummary = loadedBody
                            ? failureReason ?? "This email will be analyzed again on the next run."
                            : failureReason ?? "The message body could not be read. Open Mail, then try analysis again."
                    } else if receipt != nil {
                        p.lastTitle = "Already analyzed"
                        p.lastSummary = "No changes since the previous analysis."
                    } else {
                        p.junk += 1
                        p.lastVerdict = .junk
                        p.lastTitle = "Message skipped"
                        p.lastSummary = "Deleted messages and drafts are not analyzed."
                    }
                    p.done += 1
                    onProgress(p)
                    if modelFailures == 3 || modelFailures >= 6 {
                        do { try await engine.reload() }
                        catch { throw MailRunFailure.model }
                        // Leave remaining rows untouched if inference keeps failing after reload.
                        if modelFailures >= 6 { throw MailRunFailure.model }
                    }
                }
                state.completePass(rows: rows, now: Date())
                diagnosticPhase = .commit
                let end = await store.commitMail(bucketKey: bucket, state: state)
                guard end == .saved else { p.diskFull = end == .diskFull; throw MailRunFailure.storage }
                if state.backfillBefore != nil || rows.contains(where: { $0.id > state.highWater }) { p.mailIncomplete = true }
            }
            AppleMailHealth.save(deferred: p.mailDeferred, incomplete: p.mailIncomplete, failed: false)
        } catch is CancellationError {
            p.mailIncomplete = true
            AppleMailHealth.save(deferred: p.mailDeferred, incomplete: true, failed: false)
        }
        catch MailRunFailure.deadline {
            Diagnostics.report(.sourceReadDegraded, phase: diagnosticPhase, reason: "deadline", source: "apple_mail", flags: [.partial: true, .retriable: true])
            p.mailIncomplete = true
            AppleMailHealth.save(deferred: p.mailDeferred, incomplete: true, failed: false)
        } catch {
            Diagnostics.report(.sourceReadDegraded, phase: diagnosticPhase, error: error, source: "apple_mail", flags: [.partial: true, .retriable: true])
            p.failed += 1; p.mailIncomplete = true
            let issue: AppleMailHealth.Issue = error is MailRunFailure
                ? (error as? MailRunFailure == .storage ? .storage : .model) : .read
            AppleMailHealth.save(deferred: p.mailDeferred, incomplete: true, failed: true, issue: issue)
            Log("Apple Mail read incomplete: \(String(describing: type(of: error)))")
        }
        onProgress(p)
        return p
    }
}

/// Structural health only; no message identifiers, subjects, paths or bodies in preferences.
nonisolated enum AppleMailHealth {
    static let key = "sources.appleMail.health"
    enum Issue { case read, model, storage }
    static func save(deferred: Int, incomplete: Bool, failed: Bool, issue: Issue = .read) {
        let failureText: String
        switch issue {
        case .read: failureText = "Apple Mail could not be read. Check Full Disk Access and open Mail, then try again."
        case .model: failureText = "The on-device model could not finish Apple Mail analysis. Saved progress will resume next time."
        case .storage: failureText = "Apple Mail analysis could not save progress. Check available disk space, then try again."
        }
        let text = failed ? failureText
            : deferred > 0 ? "\(deferred) messages need a download or another local analysis. Open Mail to finish downloading, then analyze again."
            : incomplete ? "Apple Mail has more history to read. Analysis will resume next time."
            : "Downloaded mail is up to date. Junk previews are not saved; attachments are not analyzed."
        UserDefaults.standard.set(text, forKey: key)
    }
}
