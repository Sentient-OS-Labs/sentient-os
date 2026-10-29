#!/usr/bin/env python3
"""Render the production hosted panel with real SwiftUI and offline runtime fixtures.

Usage: DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  python3 Scripts/render_sentient_panel.py /absolute/output/directory
The app is not launched. No network, account, Keychain, or real installer is accessed.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


if len(sys.argv) != 2:
    raise SystemExit(__doc__)
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
components = (APP / "Views/Settings/SettingsComponents.swift").read_text()
onboarding = (APP / "Views/Onboarding/OnboardingCodexSteps.swift").read_text()
picker = (APP / "Views/FrontierEnginePicker.swift").read_text()
# Compile the actual declarations, including the real button/form styling; no layout mocks.
views = "\n".join(declaration(components, name) for name in (
    "private struct SettingsFormStyleKey", "private struct SettingsHeadingStyleKey",
    "private struct SettingsCompactLayoutKey", "extension EnvironmentValues", "enum SettingsStyle",
    "struct SettingsGroup<", "extension SettingsGroup where", "struct SettingsProse:",
    "struct SettingsPillButton:", "struct SettingsActionStyle:", "struct SettingsDetails<", "struct HealthDot:",
)) + "\n" + "\n".join(declaration(onboarding, name) for name in (
    "struct MonoWaitLine:", "struct OnboardingStatusText:",
)) + "\n" + declaration(picker, "struct FrontierActiveLine:")

FIXTURE = r'''
import SwiftUI
import AppKit
import Foundation

enum Verdict { case survivor, junk, sensitive }
@MainActor enum ModelBackend: String {
    case chatgpt, sentient
    static let key = "sentient.fixture.backend"
    static var current = Self.chatgpt
}
@MainActor enum HostedInference {
    struct Usage {
        var remainingSeconds: TimeInterval = 3_600
        var resetAt = Date(timeIntervalSince1970: 1_793_318_400)
        var dailyLimitSeconds: TimeInterval = 3_600
        var usedSeconds: TimeInterval = 0
    }
    static var isConfigured = false
    static var allowance = Usage()
    static func validate() async throws -> Usage { allowance }
}
@MainActor final class ClaudeSetup {
    static let shared = ClaudeSetup()
    var installed = true
    var installStatus: String?
    func ensureCurrent() async -> Bool { true }
    func refreshInstalled() async {}
}
@MainActor final class CodexSetup {
    static let shared = CodexSetup()
    var computerUseReady = true
    var outdated = false
    var installStatus: String?
    func ensureCurrent() async -> Bool { true }
    func refreshInstalled() async {}
}
@MainActor final class ComputerUseSetup {
    enum Backend { case openAI }
    static let shared = ComputerUseSetup()
    static func instance(for backend: Backend) -> ComputerUseSetup { shared }
    var ready = true
    var status: String?
    func install() async {}
    func refresh() {}
}
__VIEWS__

@main @MainActor struct Preview {
    static func main() async throws {
        _ = NSApplication.shared
        let suiteName = "sentient.hosted-ui-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for (name, configured, selected, remaining, settings) in [
            ("unavailable", false, false, 3_600.0, true),
            ("available", true, false, 3_600.0, true),
            ("ready", true, true, 3_600.0, true),
            ("exhausted", true, true, 0.0, true),
            ("onboarding-ready", true, true, 3_600.0, false),
        ] {
            guard name == CommandLine.arguments[2] else { continue }
            HostedInference.isConfigured = configured
            HostedInference.allowance.remainingSeconds = remaining
            HostedInference.allowance.usedSeconds = 3_600 - remaining
            ModelBackend.current = selected ? .sentient : .chatgpt
            defaults.set(ModelBackend.current.rawValue, forKey: ModelBackend.key)
            if configured && selected { _ = await SentientSetup.shared.prepare() }
            else { await SentientSetup.shared.refresh() }
            let content = VStack(alignment: .leading, spacing: 24) {
                Text("Your AI").display(28).foregroundStyle(.white)
                SentientInferencePanel()
            }
            .padding(32)
            .frame(width: settings ? 720 : 640, alignment: .leading)
            .background(Theme.bg)
            .environment(\.settingsFormStyle, settings)
            .defaultAppStorage(defaults)
            .preferredColorScheme(.dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Production SwiftUI panel did not render: \(name)")
            }
            let file = output.appendingPathComponent("sentient-\(name).png")
            try png.write(to: file)
            print("\(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) \(file.path)")
        }
    }
}
'''.replace("__VIEWS__", views)

with tempfile.TemporaryDirectory(prefix="sentient-hosted-ui-build-") as directory:
    directory = Path(directory)
    source = directory / "HostedPanelPreview.swift"
    source.write_text(FIXTURE)
    executable = directory / "render"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", str(source),
                    str(APP / "Views/SentientInferencePanel.swift"),
                    str(APP / "Views/SentientUsagePresentation.swift"),
                    str(APP / "Views/Settings/PrivacyCopy.swift"),
                    str(APP / "Views/Theme.swift"),
                    str(APP / "Cloud/HostedInference/SentientSetup.swift"),
                    "-o", str(executable)], check=True)
    # Render each state in a fresh process: SwiftUI's headless renderer may retain display lists
    # across snapshots, otherwise unchanged labels can be omitted from a later bitmap.
    for state in ("unavailable", "available", "ready", "exhausted", "onboarding-ready"):
        subprocess.run([str(executable), str(output), state], check=True, timeout=30)
