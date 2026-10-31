#!/usr/bin/env python3
"""Render production model-selection views with offline display-state fixtures.

Usage: python3 Scripts/render_model_selection.py /absolute/output/directory
Compiles the actual Settings/onboarding views. Only their initial tab/plan and runtime
services are supplied by fixtures; no account, installer, Keychain, or network is used.
Unrelated onboarding privacy chrome is omitted. Only the new renderer process creates windows.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'

def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

STUBS = r'''
import SwiftUI
import AppKit
import Observation

enum Verdict { case survivor, junk, sensitive }
@MainActor enum Fixture {
    static var tab: FrontierEngineTab = .chatgpt
    static var signedIn = false
}
@MainActor enum ModelBackend: String {
    case chatgpt, claude, custom, sentient
    static let key = "fixture.backend"
    static var current: Self = .chatgpt
}
@MainActor enum CustomProvider {
    enum Preset: String { case openRouter, lmStudio, custom
        var defaultBaseURL: String { "http://localhost:1234/v1" }
    }
    static let presetKey = "fixture.preset", baseURLKey = "fixture.url", modelNameKey = "fixture.model"
    static let reasoningKey = "fixture.reasoning", visionVerifiedKey = "fixture.vision"
    static let apiKeyAccount = "fixture", apiKey: String? = nil
    struct Config { var isUsable = false; var isConfigured = false }
    static let current = Config()
}
@MainActor final class CodexSetup {
    static let shared = CodexSetup()
    var loggedIn = Fixture.signedIn
    var loggingIn = false, preparing = false, installing = false, installGaveUp = false, installed = true
    var loginURL: URL? = nil
    var loginStatusLine: String? = nil, installStatus: String? = nil
    func refreshInstalled() async {}
    func refreshLoginStatus() async {}
    func ensureCurrent() async -> Bool { true }
    func startLogin() async -> UUID? { fatalError("No login in render fixture") }
    func cancelLogin(ifAttempt: UUID) async {}
}
@MainActor final class ClaudeSetup {
    static let shared = ClaudeSetup()
    var loggedIn = Fixture.signedIn
    var loggingIn = false, preparing = false, installing = false, installGaveUp = false, installed = true
    var verifyingLogin = false, verificationPending = false
    var plan: String? = "Max", loginURL: URL? = nil
    var loginActionTitle = "Sign in with Claude"
    var loginStatusLine: String? = nil, installStatus: String? = nil
    func refreshInstalled() async {}
    func refreshLoginStatus() async {}
    func ensureCurrent() async -> Bool { true }
    func startLogin() { fatalError("No login in render fixture") }
}
@MainActor final class SentientSetup {
    static let shared = SentientSetup()
    var preparing = false, ready = false, configured = false
    var status: String? = nil
    func prepare() async -> Bool { fatalError("No hosted provider in render fixture") }
    func refresh() async {}
}
@MainActor enum CodexAuth {
    struct Plan { var displayName = "Plus" }
    static var knowledgeBaseOnly = false
    static let connectorLockedTip = "Connect an account first."
    static func currentPlan() -> Plan? { Fixture.signedIn ? Plan() : nil }
    static func refreshPlan() async throws -> Plan? { currentPlan() }
    static func isLimited() -> Bool { false }
}
@MainActor enum Keychain {
    static func delete(_ key: String) { fatalError("No Keychain in render fixture") }
    static func set(_ key: String, _ value: String) { fatalError("No Keychain in render fixture") }
}
enum CodexTrigger { case probe; @TaskLocal static var current: Self = .probe }
@MainActor enum CodexCLI {
    enum Verdict { case available, notInstalled, notWorking(String) }
    static func probeCustomEndpoint() async -> Verdict { fatalError("No provider calls in render fixture") }
}
@MainActor final class ComputerUseSetup {
    enum Backend { case cua, openAI }
    static func instance(for backend: Backend) -> ComputerUseSetup { ComputerUseSetup() }
    func install() async { fatalError("No installer in render fixture") }
}
@MainActor @Observable final class MainNavigation {
    static let shared = MainNavigation()
    enum ModelSettingsSection: String, CaseIterable, Identifiable {
        case main = "Main AI", doubleTap = "Double Tap"
        var id: Self { self }
    }
    var modelSettingsSection = ModelSettingsSection.main
}
struct SidekickWindowPresence: View { let action: (Bool)->Void; var body: some View { EmptyView() } }
// These branches aren't rendered: hosted service is gated off, and onboarding has no Double Tap selection.
struct SentientInferencePanel: View { var body: some View { EmptyView() } }
struct DoubleTapModelSettings: View { var body: some View { EmptyView() } }
struct OnboardingTelemetryConsent: View { var body: some View { EmptyView() } }
'''
MAIN = r'''
@main @MainActor struct Render {
    static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let name = CommandLine.arguments[2]
        Fixture.tab = name.contains("claude") ? .claude : name.contains("endpoint") ? .openRouter : .chatgpt
        Fixture.signedIn = name.contains("ready")
        ModelBackend.current = Fixture.tab == .claude ? .claude : .chatgpt
        let suite = "sentient.model-render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ModelBackend.current.rawValue, forKey: ModelBackend.key)
        let onboarding = name.contains("onboarding")
        let width: CGFloat = onboarding ? 1180 : name.contains("narrow") ? 650 : 800
        let height: CGFloat = onboarding ? 880 : 820
        let content = Group {
            if onboarding { OnboardingFrontierModelView(onContinue: {}) }
            else { FrontierModelPane() }
        }
        .frame(width: width, height: height)
        .background(Color.black)
        .defaultAppStorage(defaults)
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        window.orderOut(nil)
        let file = output.appendingPathComponent(name + ".png")
        try png.write(to: file)
        print(file.path)
    }
}
'''

def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    files = ['Views/Settings/SettingsComponents.swift', 'Views/ModelSelectionDesign.swift',
             'Views/FrontierEngineTab.swift', 'Views/FrontierEnginePicker.swift',
             'Views/Onboarding/OnboardingCodexSteps.swift', 'Views/Onboarding/OnboardingFrontierModelView.swift',
             'Views/Settings/FrontierModelPane.swift', 'Views/LoginLinkButton.swift',
             'Views/Theme.swift', 'Views/GlowButton.swift', 'Views/Permissions/PermissionWindowAtmosphere.swift',
             'Views/Settings/PrivacyCopy.swift']
    with tempfile.TemporaryDirectory(prefix='sentient-model-render-') as build:
        build = Path(build)
        paths = []
        for relative in files:
            source = (APP / relative).read_text().split('#Preview(')[0]
            source = source.replace('@State private var tab: FrontierEngineTab = .chatgpt', '@State private var tab: FrontierEngineTab = Fixture.tab')
            source = source.replace('@State private var plan: CodexAuth.Plan?', '@State private var plan: CodexAuth.Plan? = CodexAuth.currentPlan()')
            source = source.replace('tab = activeTab.visibleTab', 'tab = Fixture.tab')
            path = build / Path(relative).name
            path.write_text(source)
            paths.append(str(path))
        helpers = declaration((APP/'Views/Onboarding/OnboardingView.swift').read_text(), 'struct OnboardingNextButton:')
        fixture = build / 'Fixture.swift'
        fixture.write_text(STUBS + '\n' + helpers + '\n' + MAIN)
        executable = build / 'render'
        subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
                        str(fixture), *paths, '-o', str(executable)], check=True)
        for state in ['settings-claude-ready', 'settings-chatgpt', 'settings-endpoint-narrow', 'onboarding-claude-ready', 'onboarding-chatgpt']:
            subprocess.run([str(executable), str(output), state], check=True, timeout=30)

if __name__ == '__main__':
    main()
