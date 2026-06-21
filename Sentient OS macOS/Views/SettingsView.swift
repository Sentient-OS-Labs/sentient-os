//
//  SettingsView.swift
//  Sentient OS macOS
//
//  The Settings window — opened from the home's top-bar gear (its own window, native close).
//  A tasteful, intentional placeholder for now: an About block + the sections that are coming,
//  shown as elegant rows rather than a blank panel. Full settings (sources & folders, cloud
//  mirror, compute, notifications) land in the Phase-5 settings build.
//

import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    OrbMark(size: 21)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sentient OS")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        MonoCaps("Version \(appVersion)", size: 8.5, tracking: 1.6, color: Theme.Ink.deepMuted)
                    }
                }
                .padding(.top, 26)

                MonoCaps("Settings", size: 10, tracking: 2.6, color: Theme.Ink.label)
                    .padding(.top, 28)

                VStack(spacing: 10) {
                    row("Sources & folders", "Choose what Sentient reads", "folder")
                    row("Cloud mirror", "Your knowledge, offered to your AIs", "antenna.radiowaves.left.and.right")
                    row("Compute", "Which model organizes your knowledge", "cpu")
                    row("Notifications", "When Sentient reaches out", "bell")
                }
                .padding(.top, 14)

                Spacer(minLength: 24)

                MonoCaps("More settings coming soon", size: 8.5, tracking: 1.8, color: Theme.Ink.deepMuted)
                HStack(spacing: 8) {
                    Image(systemName: "shield").font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
                    Text("Private by design. Your files never leave this Mac.")
                        .font(.system(size: 12)).foregroundStyle(Theme.Ink.label)
                }
                .padding(.top, 9).padding(.bottom, 22)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    private func row(_ title: String, _ sub: String, _ icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundStyle(Theme.Ink.bright).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            }
            Spacer(minLength: 8)
            MonoCaps("Soon", size: 8, tracking: 1.4, color: Theme.Ink.deepMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 1))
    }
}

#Preview("Settings") {
    SettingsView().frame(width: 560, height: 620)
}
