// Settings embeds the real connection flow. Local-folder access lives with its introduction.
import SwiftUI
import AppKit

struct ShareKnowledgePane: View {
    var body: some View {
        ConnectAIsView(presentation: .settings)
    }
}

/// A quiet location note alongside the connection introduction, never a separate footer.
struct LocalKnowledgeLocation: View {
    @State private var folderError: String?

    var body: some View {
        HStack(spacing: 8) {
            Text("Your knowledge lives locally on this Mac.")
                .foregroundStyle(SettingsStyle.secondary)
            Button("Open folder") {
                let folder = VaultGenerator.vaultRoot
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    folderError = "Your knowledge folder will be available after your first analysis."
                    return
                }
                if !NSWorkspace.shared.open(folder) {
                    folderError = "The knowledge folder couldn’t be opened. Try opening it in Finder."
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Ink.bright)
            .fixedSize()
            .accessibilityLabel("Open local knowledge folder in Finder")
        }
        .font(.system(size: 12))
        .alert("Knowledge folder", isPresented: Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } })) {
            Button("OK", role: .cancel) { folderError = nil }
        } message: {
            Text(folderError ?? "")
        }
    }
}

#Preview("Knowledge Sharing pane") {
    ShareKnowledgePane()
        .frame(width: 714, height: 640)
}
