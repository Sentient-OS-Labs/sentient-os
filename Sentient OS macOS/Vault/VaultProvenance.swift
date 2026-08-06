//
//  VaultProvenance.swift
//  Sentient OS macOS
//
//  Source-level provenance for the generated knowledge base. This deliberately does not claim
//  item- or sentence-level lineage: the synthesis model may merge several summaries into one note.
//

import Foundation

nonisolated struct VaultSourceProvenance: Codable, Sendable, Equatable {
    let source: SourceKind
    var incorporatedSummaryCount: Int
    var firstIncorporatedAt: Date
    var lastIncorporatedAt: Date
}

nonisolated struct VaultProvenanceManifest: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var generatedAt: Date
    var containsUntrackedLegacyKnowledge: Bool
    var sources: [VaultSourceProvenance]
}

nonisolated enum VaultProvenanceState: Sendable, Equatable {
    case empty
    case tracked(VaultProvenanceManifest)
    case legacyUnknown
    case pendingUnknown

    func mayContain(_ source: SourceKind) -> Bool {
        switch self {
        case .empty: false
        case .legacyUnknown, .pendingUnknown: true
        case .tracked(let manifest):
            manifest.containsUntrackedLegacyKnowledge
                || manifest.sources.contains { $0.source == source && $0.incorporatedSummaryCount > 0 }
        }
    }
}

actor VaultProvenanceStore {
    static let shared = VaultProvenanceStore()

    private static let activeURL = URL.sentientSupport.appendingPathComponent("vault-provenance-v1.json")
    private static let pendingURL = URL.sentientSupport.appendingPathComponent("vault-provenance-v1.pending.json")

    func state() -> VaultProvenanceState {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.pendingURL.path) { return .pendingUnknown }
        if let manifest = load(Self.activeURL) { return .tracked(manifest) }
        return fm.fileExists(atPath: VaultGenerator.vaultRoot.path) ? .legacyUnknown : .empty
    }

    func prepareBuild(notes: [CloudNote], at now: Date = Date()) throws {
        try prepareBuild(summaryCounts: Self.summaryCounts(notes), at: now)
    }

    func prepareBuild(summaryCounts: [SourceKind: Int], at now: Date = Date()) throws {
        let manifest = VaultProvenanceManifest(
            generatedAt: now,
            containsUntrackedLegacyKnowledge: false,
            sources: Self.entries(summaryCounts: summaryCounts, at: now)
        )
        try write(manifest, to: Self.pendingURL)
    }

    func prepareUpdate(notes: [CloudNote], at now: Date = Date()) throws {
        try prepareUpdate(summaryCounts: Self.summaryCounts(notes), at: now)
    }

    func prepareUpdate(summaryCounts: [SourceKind: Int], at now: Date = Date()) throws {
        let priorState = state()
        var bySource: [SourceKind: VaultSourceProvenance] = [:]
        var legacy = false
        if case .tracked(let manifest) = priorState {
            legacy = manifest.containsUntrackedLegacyKnowledge
            bySource = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.source, $0) })
        } else if priorState != .empty {
            legacy = true
        }

        for entry in Self.entries(summaryCounts: summaryCounts, at: now) {
            if var prior = bySource[entry.source] {
                prior.incorporatedSummaryCount += entry.incorporatedSummaryCount
                prior.lastIncorporatedAt = now
                bySource[entry.source] = prior
            } else {
                bySource[entry.source] = entry
            }
        }
        let manifest = VaultProvenanceManifest(
            generatedAt: now,
            containsUntrackedLegacyKnowledge: legacy,
            sources: bySource.values.sorted { $0.source.rawValue < $1.source.rawValue }
        )
        try write(manifest, to: Self.pendingURL)
    }

    /// Promote only after the vault swap. A failed promotion deliberately leaves `.pending` in
    /// place, which the reader reports as unknown rather than under-claiming provenance.
    func promotePending() {
        guard let pending = load(Self.pendingURL) else { return }
        do {
            try write(pending, to: Self.activeURL)
            try FileManager.default.removeItem(at: Self.pendingURL)
        } catch {
            Log("VaultProvenance: promotion failed — provenance remains conservatively unknown")
        }
    }

    func discardPending() {
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }

    func reset() {
        try? FileManager.default.removeItem(at: Self.activeURL)
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }

    static func summaryCounts(_ notes: [CloudNote]) -> [SourceKind: Int] {
        Dictionary(grouping: notes, by: \.kind).mapValues(\.count)
    }

    private static func entries(summaryCounts: [SourceKind: Int],
                                at date: Date) -> [VaultSourceProvenance] {
        summaryCounts.compactMap { source, count in
            guard count > 0 else { return nil }
            return VaultSourceProvenance(source: source, incorporatedSummaryCount: count,
                                  firstIncorporatedAt: date, lastIncorporatedAt: date)
        }.sorted { $0.source.rawValue < $1.source.rawValue }
    }

    private func load(_ url: URL) -> VaultProvenanceManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(VaultProvenanceManifest.self, from: data),
              manifest.version == VaultProvenanceManifest.currentVersion else { return nil }
        return manifest
    }

    private func write(_ manifest: VaultProvenanceManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}
