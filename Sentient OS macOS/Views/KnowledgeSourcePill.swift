//
// KnowledgeSourcePill.swift
// Icon-led source buttons shared by onboarding and Settings. Featured pills fill their
// column; compact pills wrap. A green check means selected for analysis, not verified access.
// Doc: Settings/Documentation - Settings.md
//

import SwiftUI
import AppKit

struct KnowledgeSourcePill: View {
    let label: String
    var detail: String? = nil
    var asset: String? = nil
    var systemImage = "puzzlepiece.extension"
    var iconPath: String? = nil
    var selected = false
    var featured = false
    var locked = false
    var isAction = false
    var trailingSymbol: String? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var included: Bool { selected && !locked }
    private var iconSize: CGFloat { featured ? 24 : 18 }
    private var statusSymbol: String? {
        if locked { return "lock.fill" }
        if let trailingSymbol { return trailingSymbol }
        if isAction { return nil }
        return included ? "checkmark" : "plus"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: featured ? 11 : 8) {
                icon.opacity(locked ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: featured ? 13.5 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(locked ? 0.55 : 1))
                        .lineLimit(featured ? 2 : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: featured ? nil : 180, alignment: .leading)
                    if let detail {
                        Text(detail).font(.system(size: 10.5))
                            .foregroundStyle(Theme.Ink.body)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if featured { Spacer(minLength: 4) }
                if let symbol = statusSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: included ? .semibold : .regular))
                        .foregroundStyle(included ? Theme.Ink.green : .white.opacity(0.5))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, featured ? 16 : 13)
            .padding(.vertical, featured ? 10 : 8)
            .frame(maxWidth: featured ? .infinity : nil, minHeight: featured ? 50 : 36)
            .background(included ? Theme.Ink.green.opacity(0.10)
                        : Color.white.opacity(hovering && !locked ? 0.07 : 0.025), in: Capsule())
            .overlay {
                Capsule().strokeBorder(included ? Theme.Ink.green.opacity(0.38)
                    : .white.opacity(locked ? 0.10 : (hovering ? 0.34 : 0.19)), lineWidth: 1)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(locked)
        .offset(y: hovering && !locked && !reduceMotion ? -1 : 0)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: included)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(locked ? CodexAuth.connectorLockedTip
            : isAction ? "" : "\(selected ? "Selected for analysis" : "Not selected")\(detail.map { ", \($0)" } ?? "")")
        .help(locked ? CodexAuth.connectorLockedTip
              : isAction ? label : selected ? "Selected for analysis and nightly updates."
              : "Choose how Sentient uses \(label).")
    }

    @ViewBuilder private var icon: some View {
        if let asset {
            ConnectorLogo(asset: asset, size: iconSize)
        } else if let iconPath, let image = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: iconSize, height: iconSize).accessibilityHidden(true)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: featured ? 19 : 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: iconSize, height: iconSize).accessibilityHidden(true)
        }
    }
}

#Preview("Source pills") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 18) {
            KnowledgeSourcePill(label: "Gmail", asset: "GmailMark", selected: true, featured: true, action: {})
            KnowledgeSourcePill(label: "Outlook Calendar", asset: "OutlookMark", featured: true, action: {})
        }
        ChipFlow {
            KnowledgeSourcePill(label: "Apple Notes", asset: "AppleNotesMark", action: {})
            KnowledgeSourcePill(label: "Granola", asset: "GranolaMark", action: {})
            KnowledgeSourcePill(label: "Add Folder", systemImage: "folder.badge.plus", isAction: true, action: {})
        }
    }
    .padding(36).frame(width: 680).background(Theme.bg)
}
