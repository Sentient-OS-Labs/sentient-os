//
//  RootView.swift
//  Sentient OS macOS
//
//  The home window's switchboard: the Constellation home (idle) ⟷ the full-screen
//  ProcessingView takeover (the fancy morph between them is a coming build phase — today
//  they cross-fade). Analyze Now runs whatever the dev source picker has armed (read via
//  SourceSelection); the picker itself and all debug controls live in DevToolsView, a sheet
//  behind the home's DEV TOOLS button.
//

import SwiftUI

struct RootView: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow

    @State private var isProcessing = false
    @State private var showDevTools = false
    @State private var customRoots: [URL] = []   // session-only custom folders (dev picker)
    @State private var fdaGranted = Permissions.hasFullDiskAccess()

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    private static let modelPath = ModelLocator.resolve()
    private static let processingLimit: Int? = nil   // nil = process the whole selection

    /// The sources Analyze Now will process — the dev picker's selection (folders + DB sources).
    private var selectedSources: [RunSource] {
        SourceSelection.current(customRoots: customRoots, fdaGranted: fdaGranted)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if isProcessing, let modelPath = Self.modelPath {
                ProcessingView(store: store, modelPath: modelPath,
                               sources: selectedSources, limit: Self.processingLimit) {
                    withAnimation(.easeInOut(duration: 0.3)) { isProcessing = false }
                }
                .transition(.opacity)
            } else {
                constellation.transition(.opacity)
            }
        }
        .frame(minWidth: 920, minHeight: 660)
        .sheet(isPresented: $showDevTools) {
            DevToolsView(store: store, customRoots: $customRoots) {
                showDevTools = false
                withAnimation(.easeInOut(duration: 0.3)) { isProcessing = true }
            }
        }
        .onChange(of: showDevTools) { _, open in
            if !open { fdaGranted = Permissions.hasFullDiskAccess() }   // may have changed in the sheet
        }
    }

    private var constellation: some View {
        let sources = selectedSources
        return ConstellationHome(
            thingsUnderstood: LifetimeStats.analyzed,
            analyzeEnabled: !sources.isEmpty && Self.modelPath != nil,
            modelMissing: Self.modelPath == nil,
            sources: .init(
                files: sources.contains { if case .files = $0 { return true } else { return false } },
                whatsapp: sources.contains { if case .whatsapp = $0 { return true } else { return false } },
                imessage: sources.contains { if case .imessage = $0 { return true } else { return false } },
                notes: sources.contains(.notes)),
            onAnalyze: { withAnimation(.easeInOut(duration: 0.3)) { isProcessing = true } },
            onOpenVault: { openWindow(id: DatabaseView.windowID) },
            onOpenBriefings: { openWindow(id: BriefingsView.windowID) },
            onShowDevTools: { showDevTools = true })
    }
}
