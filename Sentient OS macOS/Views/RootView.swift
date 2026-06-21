//
//  RootView.swift
//  Sentient OS macOS
//
//  The main window's switchboard: the proactive HomeView (idle) ⟷ the full-screen
//  ProcessingView takeover (today they cross-fade). RootView owns the analyze/source state and
//  feeds HomeView its live context; Analyze Now (in the home's Analysis popover) runs whatever
//  the dev source picker has armed (SourceSelection). The picker + all debug controls live in
//  DevToolsView, a sheet reached from the Analysis popover's DEV TOOLS link.
//

import SwiftUI

struct RootView: View {
    @State private var isProcessing = false
    @State private var showDevTools = false
    @State private var customRoots: [URL] = []   // session-only custom folders (dev picker)
    @State private var fdaGranted = Permissions.hasFullDiskAccess()

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    private static let modelPath = ModelLocator.resolve()

    /// The sources Analyze Now will process — the dev picker's selection (folders + DB sources).
    private var selectedSources: [RunSource] {
        SourceSelection.current(customRoots: customRoots, fdaGranted: fdaGranted)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if isProcessing, let modelPath = Self.modelPath {
                // Same engine + UI as the dev "start on device" buttons; .auto = backfill new
                // buckets, catch up the rest. (Gmail is a dev-tools leg; the home button is on-device.)
                ProcessingView(modelPath: modelPath,
                               connectors: RunSource.connectors(from: selectedSources),
                               mode: .auto) {
                    withAnimation(.easeInOut(duration: 0.3)) { isProcessing = false }
                }
                .transition(.opacity)
            } else {
                home.transition(.opacity)
            }
        }
        .frame(minWidth: 1040, minHeight: 800)
        .sheet(isPresented: $showDevTools) {
            DevToolsView(customRoots: $customRoots)
        }
        .onChange(of: showDevTools) { _, open in
            if !open { fdaGranted = Permissions.hasFullDiskAccess() }   // may have changed in the sheet
        }
    }

    private var home: some View {
        let sources = selectedSources
        return HomeView(
            thingsUnderstood: LifetimeStats.analyzed,
            sources: .init(
                files: sources.contains { if case .files = $0 { return true } else { return false } },
                whatsapp: sources.contains { if case .whatsapp = $0 { return true } else { return false } },
                imessage: sources.contains { if case .imessage = $0 { return true } else { return false } },
                notes: sources.contains(.notes)),
            analyzeEnabled: !sources.isEmpty && Self.modelPath != nil,
            modelMissing: Self.modelPath == nil,
            onAnalyze: { withAnimation(.easeInOut(duration: 0.3)) { isProcessing = true } },
            onShowDevTools: { showDevTools = true })
    }
}
