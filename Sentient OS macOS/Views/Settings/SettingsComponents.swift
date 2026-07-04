//
//  SettingsComponents.swift
//  Sentient OS macOS
//
//  Shared building blocks for the Settings window's panes. The philosophy: form encodes content —
//  prose for stories, hairline toggle lines for switches, chips for sources, status dots for
//  health, bordered fields only for actual input. No uniform card rows.
//  Pieces: SettingsPane (scaffold) · SettingsGroup · SettingsProse · SettingToggleLine ·
//  SettingsPillButton · ChipFlow · SettingsChip · StatusLine · SettingsTextBox · SettingsHairline.
//

import SwiftUI

/// The right-pane scaffold every settings pane uses: an italic serif title (the editorial voice),
/// an optional serif-italic whisper under it, then the scrolling body — capped to an editorial
/// measure so a wide window never stretches lines unreadable.
struct SettingsPane<Content: View>: View {
    let title: String
    var whisper: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.serif(27)).italic()
                    .foregroundStyle(.white)
                if let whisper {
                    Text(whisper)
                        .font(.serif(12.5, weight: .regular)).italic()
                        .foregroundStyle(Theme.Ink.body)
                        .padding(.top, 7)
                }
                content
                    .padding(.top, 26)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 38).padding(.top, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A labelled group — the mono-caps whisper above whatever form the group's content takes.
struct SettingsGroup<Content: View>: View {
    let label: String
    var badge: String? = nil          // e.g. "coming soon" on a not-yet-wired group
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                MonoCaps(label, size: 9.5, tracking: 2.4, color: Theme.Ink.label)
                if let badge {
                    MonoCaps("· \(badge)", size: 8, tracking: 1.6, color: Theme.Ink.deepMuted)
                }
            }
            content
        }
    }
}

/// Editorial body prose — explanation that reads as voice, not as a widget. No box.
struct SettingsProse: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A switch on a hairline line — title, quiet subtitle, toggle. No box, no icon.
struct SettingToggleLine: View {
    let title: String
    let sub: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).tint(Theme.Ink.green)
        }
        .padding(.vertical, 5)
    }
}

/// A small capsule button — the standard quiet action (Fix…, Copy, Regenerate…). `tint` carries
/// the danger/success variants; the default is bright ink with a hairline ring.
struct SettingsPillButton: View {
    let title: String
    var tint: Color = Theme.Ink.bright
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(
                    tint == Theme.Ink.bright ? Color.white.opacity(0.16) : tint.opacity(0.4),
                    lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Wraps chips onto as many rows as the width needs — like text, not a grid. Rows stay
/// left-aligned and tidy no matter how many custom folders the user adds.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? max(0, x - spacing) : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A source/option pill — the connector form (the Analysis popover's chips, grown up a size).
/// ON is a small celebration: a green wash + green ring + the green dot, so a selected source
/// visibly counts. The label ink is ALWAYS pure white — the dot/wash/ring carry the on/off
/// state, never a dimmed label (dim gray on OLED black was unreadable). `detail` carries counts
/// ("12 chats"). Pure action chips ("+ Add Folder") pass `isAction: true`: no dot, a bright
/// dashed border — an invitation, not a source.
struct SettingsChip: View {
    let label: String
    var detail: String? = nil
    let on: Bool
    var isAction: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 7) {
                if !isAction {
                    Circle()
                        .fill(on ? Theme.Ink.green : .white.opacity(0.4))
                        .frame(width: 5, height: 5)
                }
                Text(label)
                    .font(.system(size: 12, weight: on || isAction ? .medium : .regular))
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail).font(.system(size: 10.5))
                        .foregroundStyle(on ? Theme.Ink.green.opacity(0.85) : .white.opacity(0.62))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(isAction ? Color.white.opacity(0.05) : (on ? Theme.Ink.green.opacity(0.13) : Color.clear),
                        in: Capsule())
            .overlay {
                if isAction {
                    Capsule().strokeBorder(Color.white.opacity(0.32),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    Capsule().strokeBorder(on ? Theme.Ink.green.opacity(0.38) : Color.white.opacity(0.16),
                                           lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// A lit status LED: bright core + double soft glow (tight halo, wide bloom). Shared by
/// StatusLine and the collapsed codex summary.
struct HealthDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().fill(.white.opacity(0.35)).frame(width: 2.5, height: 2.5))
            .frame(width: 6.5, height: 6.5)
            .shadow(color: color.opacity(0.85), radius: 3)
            .shadow(color: color.opacity(0.45), radius: 8)
    }
}

/// Shared "warmth" for the info tips: once one tip has opened, sibling tips open instantly for a
/// short window (the native-menu feel) instead of each re-waiting the hover delay.
@MainActor @Observable
final class TipWarmth {
    static let shared = TipWarmth()
    private var lastInteraction = Date.distantPast

    var isWarm: Bool { Date().timeIntervalSince(lastInteraction) < 0.5 }
    func touch() { lastInteraction = Date() }
}

/// The tiny info icon beside a permission name. Hover 0.15s to open the explanation (a small
/// popover); while any tip is warm, siblings open instantly.
struct InfoTip: View {
    let text: String
    @State private var shown = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Ink.label.opacity(0.75))
            .onHover { inside in
                hoverTask?.cancel()
                if inside {
                    if TipWarmth.shared.isWarm {
                        shown = true
                        TipWarmth.shared.touch()
                    } else {
                        hoverTask = Task {
                            try? await Task.sleep(for: .seconds(0.15))
                            guard !Task.isCancelled else { return }
                            shown = true
                            TipWarmth.shared.touch()
                        }
                    }
                } else {
                    if shown { TipWarmth.shared.touch() }   // keep siblings warm on the way out
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                Text(text)
                    .font(.system(size: 11.5))
                    .lineSpacing(2.5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(width: 250, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// One health line — a verdict dot, the thing being checked, its state in mono-caps, and a
/// fix affordance when something's red. The Permissions & Health form.
struct StatusLine: View {
    enum Health { case ok, warn, bad }

    let title: String
    let health: Health
    let note: String                    // "granted" / "not granted" / "logged in"
    var tip: String? = nil              // the info-icon explanation (InfoTip)
    var fixTitle: String = "Fix…"
    var fix: (() -> Void)? = nil

    /// Punchier than the ink palette on purpose — these are status LEDs, not labels.
    private var dot: Color {
        switch health {
        case .ok:   return Theme.Ink.green
        case .warn: return Color(red: 1.0, green: 0.72, blue: 0.30)
        case .bad:  return Color(red: 1.0, green: 0.36, blue: 0.36)
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            HealthDot(color: dot)
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.Ink.statusInk)
                if let tip { InfoTip(text: tip) }
            }
            Spacer(minLength: 12)
            MonoCaps(note, size: 8.5, tracking: 1.6,
                     color: health == .ok ? Theme.Ink.label : dot)
            if health != .ok, let fix {
                SettingsPillButton(title: fixTitle, action: fix)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A multiline text box — the one bordered input surface in Settings. Autosaves through its
/// binding (pair with @AppStorage at the call site); shows a quiet placeholder while empty.
struct SettingsTextBox: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder insets must mirror the editor's first line exactly: the editor sits at
            // (horizontal 7 + NSTextView's ~5pt line-fragment padding, vertical 8) → (12, 8).
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.statusInk)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7).padding(.vertical, 8)
        }
        .frame(minHeight: 64)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// The hairline that separates lines inside a group.
struct SettingsHairline: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }
}
