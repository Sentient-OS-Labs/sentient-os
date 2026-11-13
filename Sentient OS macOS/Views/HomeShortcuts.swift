// Home’s temporary cue for opening Sidekick from the notch.
import SwiftUI

struct HomeNotchHint: View {
    let coordinator: CommandCoordinator
    @AppStorage(ShortcutPreferences.storageKey) private var shortcutRaw = ShortcutKey.rightCommand.rawValue
    @AppStorage(NotchPreferences.clickEnabledKey) private var clickable = true
    @AppStorage(SidekickDiscovery.notchUsesKey) private var uses = 0
    @State private var hovered = false
    private var key: ShortcutKey { ShortcutKey(rawValue: shortcutRaw) ?? .rightCommand }

    var body: some View {
        if uses < SidekickDiscovery.notchLearningUses && !coordinator.run.isRunning && coordinator.phase == .hidden {
            Button { coordinator.openNotchFromHome() } label: {
                HStack(spacing: 5) {
                    Text(clickable ? "Try the notch" : "Press \(key.label)")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                }
                .font(.system(size: 11.5)).foregroundStyle(hovered ? SidekickStyle.ink : SidekickStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityIdentifier("sidekick.notchHint")
            .accessibilityLabel("Open Sidekick in the notch")
            .help(clickable ? "Sidekick is in your notch, too. Click it or press \(key.label) from any app."
                  : "Press \(key.label) to open Sidekick from any app.")
        }
    }
}
