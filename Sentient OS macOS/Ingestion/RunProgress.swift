// RunProgress.swift
// The complete analysis snapshot shared by local ingestion and remote source reads.
// Keeps source loading, summaries and retryable failures distinct from item verdicts.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation

nonisolated struct RunProgress: Sendable {
    var total = 0
    var done = 0
    var survivors = 0
    var junk = 0
    var sensitive = 0
    var failed = 0
    var parseFailures = 0          // §7.13: junk that was actually a garbled/unparseable model reply
    var extractionFailed = 0       // §7.8/B10: item whose CONTENT extraction failed (corrupt file), not the engine
    var lastPath: String?
    var lastItemDate: Date?        // source date for the current item's preview footer
    var lastFilePath: String?      // absolute path (for the thumbnail)
    var lastPrompt: String?        // the EXACT prompt fed to the model for this item (dev prompt pane)
    var lastTitle: String?
    var lastSummary: String?
    var lastVerdict: Verdict?
    var lastSeconds: Double?
    var totalSeconds: Double = 0   // sum over successful generations (for avg)
    /// Remote reads report source state separately from per-item triage verdicts.
    nonisolated struct SourceRead: Sendable {
        enum Status: Sendable { case reading, summarized, quiet, failed }
        let name: String
        let status: Status

        var caption: String {
            switch status {
            case .reading: "READING SOURCE"
            case .summarized: "SUMMARY"
            case .quiet: "SOURCE CHECKED"
            case .failed: "NEEDS ATTENTION"
            }
        }
    }
    var sourceRead: SourceRead?
    var quietReads = 0
    var sourceReadFailures: [String: String] = [:]
    var successfulSources: Set<String> = []
    /// The run stopped early because the Mac's disk is full: either the free-space pre-flight
    /// refused to start, or a per-item commit reported `.diskFull` mid-run. Everything up to the
    /// halt is saved (marks are per-item atomic); nothing after it was read. The caller shows the
    /// disk-full screen / morning caution instead of running the cloud tail (which writes too).
    var diskFull = false
    var mailDeferred = 0
    var mailIncomplete = false

    /// Carry the complete card together. An update without a completed item keeps the prior card.
    mutating func updateLastItem(from progress: RunProgress) {
        guard progress.lastPath != nil else { return }
        lastPath = progress.lastPath; lastFilePath = progress.lastFilePath; lastPrompt = progress.lastPrompt
        lastItemDate = progress.lastItemDate
        lastTitle = progress.lastTitle; lastSummary = progress.lastSummary; lastVerdict = progress.lastVerdict
        lastSeconds = progress.lastSeconds; sourceRead = progress.sourceRead
    }
    mutating func beginSourceRead(name: String, label: String, prompt: String) {
        sourceRead = SourceRead(name: name, status: .reading)
        lastTitle = "Reading \(name)"
        lastSummary = "Finding and summarizing useful context."
        lastPath = label; lastPrompt = prompt
        lastItemDate = nil
        lastVerdict = nil; lastFilePath = nil; lastSeconds = nil
    }

    mutating func finishSourceRead(name: String, label: String, summary: String?, items: Int) {
        sourceReadFailures.removeValue(forKey: name)
        successfulSources.insert(name)
        // Committed windows arrive newest first. A quiet older window must not erase the
        // source's useful summary; beginSourceRead resets the card for the next source/run.
        if summary == nil, sourceRead?.name == name, sourceRead?.status == .summarized { return }
        sourceRead = SourceRead(name: name, status: summary == nil ? .quiet : .summarized)
        lastTitle = summary == nil ? "No new summary" : "\(name) summary"
        lastSummary = summary ?? "No summary to add from this sample."
        lastPath = label + (items > 0 ? " · \(items) item\(items == 1 ? "" : "s") checked" : "")
        lastVerdict = summary == nil ? nil : .survivor
        lastFilePath = nil; lastSeconds = nil
        lastItemDate = nil
    }

    mutating func failSourceRead(name: String, message: String, countFailure: Bool = true) {
        sourceRead = SourceRead(name: name, status: .failed)
        lastTitle = "\(name) needs another try"
        lastSummary = message; lastPath = name
        lastVerdict = nil; lastFilePath = nil; lastSeconds = nil; lastPrompt = nil
        lastItemDate = nil
        sourceReadFailures[name] = message
        successfulSources.remove(name)
        if countFailure { failed += 1 }
    }

    /// Preserve failures across pauses, clearing them only when that source succeeds on retry.
    mutating func mergeSourceResults(from previous: RunProgress) {
        sourceReadFailures = previous.sourceReadFailures.merging(sourceReadFailures) { _, current in current }
        for name in successfulSources { sourceReadFailures.removeValue(forKey: name) }
    }
}
