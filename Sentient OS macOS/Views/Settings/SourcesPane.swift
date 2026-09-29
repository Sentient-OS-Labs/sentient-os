//
// SourcesPane.swift
// Settings' Knowledge Sources scaffold. The picker is shared with onboarding so both
// surfaces expose the same catalog, account connections, and persisted source selection.
// Doc: Documentation - Settings.md
//

import SwiftUI

struct SourcesPane: View {
    var body: some View {
        SettingsPane(title: "Knowledge Sources",
                     whisper: "The context your Sentient learns from, every night.") {
            KnowledgeSourcesPicker()
        }
    }
}

#Preview("Knowledge Sources pane") {
    SourcesPane()
        .background(Theme.bg)
        .frame(width: 720, height: 720)
}
