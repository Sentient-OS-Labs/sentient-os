// AI model choices and provider accounts. Reuses the same setup and credential stores
// as onboarding; merely browsing a provider never selects or signs in to it.
import SwiftUI
import AppKit

struct FrontierModelPane: View {
    typealias Section = MainNavigation.ModelSettingsSection

    @Bindable private var navigation = MainNavigation.shared
    @State private var tab: FrontierEngineTab = .chatgpt
    @State private var codex = CodexSetup.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                onDeviceModelCard
                ModelSelectionHeading(title: "Choose your frontier model",
                                      subtitle: "Your most intelligent AI clicks around for Sidekick and other frontier work.")
                ModelChoiceBar(items: [
                    ModelChoiceItem(id: Section.main.rawValue, title: "Main AI", symbol: "sparkles"),
                    ModelChoiceItem(id: Section.doubleTap.rawValue, title: "Magic Reply", symbol: "touchid")
                ], selection: navigation.modelSettingsSection.rawValue) { raw in
                    if let section = Section(rawValue: raw) { navigation.modelSettingsSection = section }
                }
                if navigation.modelSettingsSection == .main {
                    FrontierEnginePicker(tab: $tab, chatgptHealthy: codex.loggedIn) {
                        OnboardingCodexLoginPanel(settingsStyle: true)
                    }
                    SettingsDetails(title: "How your models work together") {
                        SettingsProse(PrivacyCopy.frontierDetail)
                        SettingsProse(PrivacyCopy.customProvider)
                    }
                } else {
                    SettingsProse("This model drafts your Magic Reply replies. Changing it does not change the main AI.")
                    DoubleTapModelSettings()
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .environment(\.settingsFormStyle, true)
        .task(id: tab == .chatgpt && navigation.modelSettingsSection == .main) { await refreshChatGPT() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshChatGPT() }
        }
    }

    private var onDeviceModelCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.Ink.bright)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Gemma 4 E4B")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Ink.statusInk)
                    Spacer(minLength: 0)
                    Label("On this Mac", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Ink.body)
                }
                Text("Your on-device model understands your life locally.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func refreshChatGPT() async {
        guard tab == .chatgpt, navigation.modelSettingsSection == .main else { return }
        await codex.refreshInstalled()
        await codex.refreshLoginStatus()
    }
}

#Preview("AI Models & Accounts") {
    FrontierModelPane()
        .background(Theme.bg)
        .frame(width: 720, height: 820)
}
