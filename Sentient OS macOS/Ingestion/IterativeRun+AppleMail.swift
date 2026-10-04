// IterativeRun+AppleMail.swift
// Account/generation frontiers, deferred-body retries and periodic reconciliation for Mail.
// Every classification is committed atomically with progress. Doc: Ingestion/Documentation - Ingestion Pipeline.md

import Foundation

extension IterativeRun {
    /// Uses the run's single local engine; all disk work is on a utility task, away from UI work.
    func runMail(_ connector: AppleMailConnector, engine: Engine,
                 onProgress: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        var p = RunProgress()
        var generations = 0
        var modelFailures = 0
        let deadline = Date().addingTimeInterval(3600)
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
                let start = await store.commitMail(bucketKey: bucket, state: state, remove: invalid)
                guard start == .saved else { p.diskFull = start == .diskFull; throw AppleMailError.database }
                for identity in invalid { receipts.removeValue(forKey: identity) }
                try await Task.detached(priority: .utility) { try snapshot.indexFiles(account: account) }.value
                p.total += work.count
                onProgress(p)
                for item in work {
                    try Task.checkCancellation()
                    if Date() >= deadline { throw AppleMailError.busy }
                    let row = item.row
                    var retry = false, draft: NoteDraft?, receipt: AppleMailReceiptValue?
                    var remove = Set<String>()
                    var decision: Triage.Outcome?
                    var seconds: Double?
                    var loadedBody = false
                    if !row.excluded {
                        do {
                            let message = try await Task.detached(priority: .utility) { try snapshot.body(row) }.value
                            loadedBody = true
                            let identity = AppleMailSource.identity(salt: state.salt, row: row, message: message)
                            remove = Set(receipts.values.filter {
                                $0.generation == snapshot.generation && $0.rowID == row.id && $0.identity != identity
                            }.map(\.identity))
                            let hash = AppleMailSource.contentDigest(message, sent: row.sent)
                            receipt = AppleMailReceiptValue(identity: identity, contentHash: hash,
                                generation: snapshot.generation, rowID: row.id,
                                messageKey: AppleMailSource.messageKey(salt: state.salt, row: row))
                            if receipts[identity]?.contentHash != hash {
                                if generations > 0 && generations % 40 == 0 { try await engine.reload() }
                                let metadata = ["folder": "Apple Mail", "sent": row.sent ? "1" : "0"]
                                let candidate = Candidate(id: identity, kind: .appleMail, itemDate: row.date, metadata: metadata)
                                // Only body + attribution headers reach the on-device model. Bcc,
                                // routing headers, attachments and original .emlx paths do not.
                                let header = ["from", "to", "subject", "date"].map { "\($0): \(message.headers[$0, default: ""] .prefix(1000))" }.joined(separator: "\n")
                                let body = String(decoding: message.text.utf8.prefix(12_000), as: UTF8.self)
                                let artifact = Artifact(candidate: candidate, text: header + "\n\n" + body)
                                let response = try await engine.generate(prompt: Triage.prompt(for: artifact, currentDate: Date()), imageData: nil)
                                generations += 1
                                guard let outcome = Triage.decideMail(response.text) else {
                                    p.parseFailures += 1; throw AppleMailError.missingBody
                                }
                                decision = outcome
                                modelFailures = 0
                                seconds = response.totalTime
                                if outcome.verdict == .survivor {
                                    draft = NoteDraft(kind: .appleMail, sourceID: identity, folder: "Apple Mail", itemDate: row.date,
                                        text: outcome.summary, title: outcome.title, reminderFlagged: false)
                                } else { remove.insert(identity); receipt = nil }
                            }
                        } catch AppleMailMIME.Failure.excluded {
                            // Header policy rejection stores neither headers nor an identity.
                            remove = Set(receipts.values.filter { $0.generation == snapshot.generation && $0.rowID == row.id }.map(\.identity))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            retry = true; receipt = nil; draft = nil
                            if loadedBody {
                                p.failed += 1
                                // Malformed JSON is a deferred classification, not a broken GPU.
                                // Repeated bad outputs must not starve all remaining message bodies.
                                if case AppleMailError.missingBody = error { modelFailures = 0 }
                                else { modelFailures += 1 }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    var next = state
                    next.finish(item, retry: retry)
                    let outcome = await store.commitMail(bucketKey: bucket, state: next, note: draft, receipt: receipt, remove: remove)
                    guard outcome == .saved else { p.diskFull = outcome == .diskFull; throw AppleMailError.database }
                    state = next
                    for identity in remove { receipts.removeValue(forKey: identity) }
                    if let receipt { receipts[receipt.identity] = receipt }
                    // Display/counters only after a successful commit; no rejected content in UI.
                    // Keep the previous card intact if this attempt is cancelled or cannot be saved.
                    p.lastPath = "Apple Mail"; p.lastFilePath = nil; p.lastPrompt = nil
                    p.lastTitle = nil; p.lastSummary = nil; p.lastVerdict = nil
                    p.lastSeconds = seconds; p.totalSeconds += seconds ?? 0
                    if let decision {
                        LifetimeStats.bump(decision.verdict)
                        switch decision.verdict {
                        case .survivor: p.survivors += 1; p.lastTitle = decision.title; p.lastSummary = decision.summary
                        case .junk: p.junk += 1
                        case .sensitive: p.sensitive += 1
                        }
                        p.lastVerdict = decision.verdict
                    } else if retry {
                        p.lastTitle = loadedBody ? "Analysis deferred" : "Message unavailable"
                        p.lastSummary = loadedBody
                            ? "This email will be analyzed again on the next run."
                            : "The message body could not be read. Open Mail, then try analysis again."
                    } else if receipt != nil {
                        p.lastTitle = "Already analyzed"
                        p.lastSummary = "No changes since the previous analysis."
                    } else {
                        p.junk += 1
                        p.lastVerdict = .junk
                    }
                    p.done += 1
                    onProgress(p)
                    if modelFailures == 3 || modelFailures >= 6 {
                        try await engine.reload()
                        // Leave remaining rows untouched if inference keeps failing after reload.
                        if modelFailures >= 6 { throw AppleMailError.busy }
                    }
                }
                state.completePass(rows: rows, now: Date())
                let end = await store.commitMail(bucketKey: bucket, state: state)
                guard end == .saved else { p.diskFull = end == .diskFull; throw AppleMailError.database }
                p.mailDeferred += state.deferred.count
                if state.backfillBefore != nil || rows.contains(where: { $0.id > state.highWater }) { p.mailIncomplete = true }
            }
            AppleMailHealth.save(deferred: p.mailDeferred, incomplete: p.mailIncomplete, failed: false)
        } catch is CancellationError { p.mailIncomplete = true }
        catch {
            p.failed += 1; p.mailIncomplete = true
            AppleMailHealth.save(deferred: p.mailDeferred, incomplete: true, failed: true)
            Log("Apple Mail read incomplete: \(String(describing: type(of: error)))")
        }
        onProgress(p)
        return p
    }
}

/// Structural health only; no message identifiers, subjects, paths or bodies in preferences.
nonisolated enum AppleMailHealth {
    static let key = "sources.appleMail.health"
    static func save(deferred: Int, incomplete: Bool, failed: Bool) {
        let text = failed ? "Apple Mail could not be read. Check Full Disk Access and open Mail, then try again."
            : deferred > 0 ? "\(deferred) messages need a download or another local analysis. Open Mail to finish downloading, then analyze again."
            : incomplete ? "Apple Mail has more history to read. Analysis will resume next time."
            : "Downloaded mail is up to date. Attachments, junk and promotions are excluded."
        UserDefaults.standard.set(text, forKey: key)
    }
}
