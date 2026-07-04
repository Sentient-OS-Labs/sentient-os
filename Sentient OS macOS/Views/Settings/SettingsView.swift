//
//  SettingsView.swift
//  Sentient OS macOS
//
//  The Settings window — a modern two-pane layout: a quiet sidebar of sections on the left
//  (with the About footer: version + the open-source link), the selected pane on the right,
//  and the trust ribbon riding the foot. Panes live beside this file (SystemPane is real;
//  the rest are styled skeletons in PlaceholderPanes.swift, replaced one phase at a time).
//

import SwiftUI
import AppKit

struct SettingsView: View {
    static let windowID = "settings"

    /// The five sections, in sidebar order.
    enum Pane: CaseIterable, Identifiable {
        case sources, proactive, yourAIs, system, health

        var id: Self { self }
        var title: String {
            switch self {
            case .sources:   return "Knowledge Sources"
            case .proactive: return "Proactive & Sidekick"
            case .yourAIs:   return "Your AIs"
            case .system:    return "System"
            case .health:    return "Permissions & Health"
            }
        }
        var icon: String {
            switch self {
            case .sources:   return "tray.full"
            case .proactive: return "sparkles"
            case .yourAIs:   return "antenna.radiowaves.left.and.right"
            case .system:    return "gearshape"
            case .health:    return "checkmark.shield"
            }
        }
    }

    @State private var selection: Pane = .sources

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            detail
        }
        .background(Theme.bg.ignoresSafeArea())
        .frame(minWidth: 880, minHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OrbMark(size: 19)
                Text("Settings")
                    .font(.serif(16)).italic().foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.top, 20)

            VStack(spacing: 3) {
                ForEach(Pane.allCases) { pane in
                    SidebarRow(pane: pane, selected: selection == pane) { selection = pane }
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 20)
            aboutFooter
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 18)
        .frame(width: 236)
    }

    /// The About corner — what used to want its own tab, tucked where it belongs.
    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 9) {
            MonoCaps("Sentient OS · v\(appVersion)", size: 8, tracking: 1.6, color: Theme.Ink.deepMuted)
            footerLink("Open source on GitHub", icon: "heart.fill",
                       url: "https://github.com/Sentient-OS-Labs/sentient-os")
            footerLink("Report an issue", icon: "ladybug",
                       url: "https://github.com/Sentient-OS-Labs/sentient-os/issues")
        }
        .padding(.horizontal, 10)
    }

    private func footerLink(_ title: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 8.5))
                Text(title).font(.system(size: 10.5))
            }
            .foregroundStyle(Theme.Ink.label)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                switch selection {
                case .sources:   SourcesPane()
                case .proactive: ProactivePanePlaceholder()
                case .yourAIs:   YourAIsPane()
                case .system:    SystemPane()
                case .health:    HealthPanePlaceholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            trustFooter
        }
    }

    /// The trust ribbon — rides every surface, Settings included.
    private var trustFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield").font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
            Text("Private by design. Your files never leave this Mac.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.label)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let pane: SettingsView.Pane
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.Ink.statusInk : Theme.Ink.label)
                    .frame(width: 20)
                Text(pane.title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .white : Theme.Ink.body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Theme.elevated : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Settings") {
    SettingsView().frame(width: 920, height: 640)
}
