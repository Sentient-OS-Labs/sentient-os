//
//  SettingsView.swift
//  Sentient OS macOS
//
//  The Settings page — a modern two-pane layout: a quiet sidebar of sections on the left
//  (with the About footer: version + the open-source link), the selected pane on the right,
//  and the trust ribbon riding the foot. Every pane is real and lives beside this file:
//  SourcesPane · FrontierModelPane · DoubleTapPane · ProactivePane · ShareKnowledgePane · SystemPane · HealthPane.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    /// The sections, in sidebar order.
    enum Pane: CaseIterable, Identifiable {
        case sources, frontierModel, doubleTap, proactive, shareKnowledge, system, health

        var id: Self { self }
        var title: String {
            switch self {
            case .sources:   return "Knowledge Sources"
            case .frontierModel: return "Frontier Model Choice"
            case .doubleTap: return "Double Tap"
            case .proactive: return "Proactive & Sidekick"
            case .shareKnowledge: return "Give AIs Knowledge"
            case .system:    return "System"
            case .health:    return "Permissions & Health"
            }
        }
        var icon: String {
            switch self {
            case .sources:   return "tray.full"
            case .frontierModel: return "cpu"
            case .doubleTap: return "hand.tap"
            case .proactive: return "sparkles"
            case .shareKnowledge: return "antenna.radiowaves.left.and.right"
            case .system:    return "gearshape"
            case .health:    return "checkmark.shield"
            }
        }
    }

    @Bindable private var navigation = MainNavigation.shared
    private var selection: Pane { navigation.settingsPane }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            detail
        }
        .background(Theme.bg.ignoresSafeArea())
        .frame(minWidth: 1000, minHeight: 640)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeNavigationButton()
                .padding(.top, 24)

            Text("Settings")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 27)
                .padding(.bottom, 18)

            VStack(spacing: 4) {
                ForEach(Pane.allCases) { pane in
                    SidebarRow(pane: pane, selected: selection == pane) { navigation.settingsPane = pane }
                }
            }

            Spacer(minLength: 20)
            aboutFooter
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 22)
        .frame(width: 248)
        .background(Color(white: 0.065).ignoresSafeArea())
    }

    /// The About corner — what used to want its own tab, tucked where it belongs.
    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHairline(opacity: 0.09).padding(.bottom, 2)
            HStack(spacing: 8) {
                OrbMark(size: 17)
                Text("Sentient OS").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }
            Text("Version \(UpdateController.currentVersionString)")
                .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
            footerLink("Open source on GitHub", icon: "arrow.up.right",
                       url: "https://github.com/Sentient-OS-Labs/sentient-os")
            footerLink("Report an issue", icon: "arrow.up.right",
                       url: "https://github.com/Sentient-OS-Labs/sentient-os/issues")
        }
        .padding(.horizontal, 14)
    }

    private func footerLink(_ title: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12))
                Image(systemName: icon).font(.system(size: 9))
            }
            .foregroundStyle(SettingsStyle.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                switch selection {
                case .sources:   SourcesPane()
                case .frontierModel: FrontierModelPane()
                case .doubleTap: DoubleTapPane()
                case .proactive: ProactivePane()
                case .shareKnowledge: ShareKnowledgePane()
                case .system:    SystemPane()
                case .health:    HealthPane()
                }
            }
            .id(selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selection == .sources || selection == .health { trustFooter }
        }
    }

    /// The trust ribbon — in Settings it rides ONLY Knowledge Sources and Permissions & Health,
    /// the panes where the files story is the message (what we read · what the grants allow);
    /// boilerplate on every pane would cheapen it.
    private var trustFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield").font(.system(size: selection == .sources ? 10.5 : 12)).foregroundStyle(Theme.Ink.label)
            Text(PrivacyCopy.trustRibbon)
                .font(.system(size: selection == .sources ? 11.5 : 13)).foregroundStyle(Theme.Ink.label)
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
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? .white : SettingsStyle.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(pane.title)
                    .font(.system(size: 15, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.78))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.white.opacity(selected ? 0.10 : (hovered ? 0.04 : 0)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview("Settings") {
    SettingsView().frame(width: 1120, height: 800)
        .preferredColorScheme(.dark)
}
