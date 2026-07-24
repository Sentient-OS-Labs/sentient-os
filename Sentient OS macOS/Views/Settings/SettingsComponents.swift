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

/// The right-pane scaffold every settings pane uses: a bold display title (the editorial voice),
/// an optional quiet whisper under it, then the scrolling body — capped to an editorial
/// measure so a wide window never stretches lines unreadable.
struct SettingsPane<Content: View>: View {
    let title: LocalizedStringKey
    var whisper: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .display(27)
                    .foregroundStyle(.white)
                if let whisper {
                    Text(whisper)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.72))
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
    let label: LocalizedStringKey
    var badge: LocalizedStringKey? = nil          // e.g. "coming soon" on a not-yet-wired group
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))
                if let badge {
                    HStack(spacing: 4) {
                        Text("·")
                        Text(badge)
                    }
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            content
        }
    }
}

/// Editorial body prose — explanation that reads as voice, not as a widget. No box.
struct SettingsProse: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    /// Engine / runtime strings that must not go through the String Catalog.
    init(verbatim string: String) { self.text = Text(verbatim: string) }

    var body: some View {
        text
            .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A switch on a hairline line — title, quiet subtitle, toggle. No box, no icon.
struct SettingToggleLine: View {
    let title: LocalizedStringKey
    let sub: LocalizedStringKey
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
    private let title: Text
    var tint: Color = Theme.Ink.bright
    let action: () -> Void

    init(title: LocalizedStringKey, tint: Color = Theme.Ink.bright, action: @escaping () -> Void) {
        self.title = Text(title)
        self.tint = tint
        self.action = action
    }

    /// Runtime labels (caution banners, etc.) that are not catalog keys.
    init(verbatim title: String, tint: Color = Theme.Ink.bright, action: @escaping () -> Void) {
        self.title = Text(verbatim: title)
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            title
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
/// dashed border — an invitation, not a source. `locked` (knowledge-base-only mode's
/// Gmail/Calendar) is the one deliberate exception to the always-white rule: a lock in place of
/// the dot, softened ink, no action — unavailable, with the hover tip explaining why.
struct SettingsChip: View {
    private let label: Text
    var detail: String? = nil
    let on: Bool
    var isAction: Bool = false
    var locked: Bool = false
    var action: (() -> Void)? = nil

    @State private var lockHover = false

    init(label: LocalizedStringKey, detail: String? = nil, on: Bool,
         isAction: Bool = false, locked: Bool = false, action: (() -> Void)? = nil) {
        self.label = Text(label)
        self.detail = detail
        self.on = on
        self.isAction = isAction
        self.locked = locked
        self.action = action
    }

    /// Folder names / runtime labels that must not go through the String Catalog.
    init(verbatim label: String, detail: String? = nil, on: Bool,
         isAction: Bool = false, locked: Bool = false, action: (() -> Void)? = nil) {
        self.label = Text(verbatim: label)
        self.detail = detail
        self.on = on
        self.isAction = isAction
        self.locked = locked
        self.action = action
    }

    @ViewBuilder var body: some View {
        if locked {
            chip
                .onHover { lockHover = $0 }
                .overlay(alignment: .top) {
                    if lockHover { LockedChipTip().offset(y: -32) }
                }
                .animation(.easeInOut(duration: 0.15), value: lockHover)
        } else {
            chip
        }
    }

    private var chip: some View {
        Button { if !locked { action?() } } label: {
            HStack(spacing: 7) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                } else if !isAction {
                    Circle()
                        .fill(on ? Theme.Ink.green : .white.opacity(0.4))
                        .frame(width: 5, height: 5)
                }
                label
                    .font(.system(size: 12, weight: on || isAction ? .medium : .regular))
                    .foregroundStyle(.white.opacity(locked ? 0.55 : 1))
                if let detail {
                    Text(verbatim: detail).font(.system(size: 10.5))
                        .foregroundStyle(on ? Theme.Ink.green.opacity(0.85) : .white.opacity(0.62))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(isAction ? Color.white.opacity(0.05) : (on && !locked ? Theme.Ink.green.opacity(0.13) : Color.clear),
                        in: Capsule())
            .overlay {
                if isAction {
                    Capsule().strokeBorder(Color.white.opacity(0.32),
                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    Capsule().strokeBorder(on && !locked ? Theme.Ink.green.opacity(0.38)
                                                         : Color.white.opacity(locked ? 0.10 : 0.16),
                                           lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The instant hover notice on a locked (knowledge-base-only) connector chip — the system
/// tooltip's delay made it look like there was none. Shared by SettingsChip and SourceChip.
struct LockedChipTip: View {
    var body: some View {
        Text("Only supported on ChatGPT Plus")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(white: 0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .fixedSize()
            .allowsHitTesting(false)
            .transition(.opacity)
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
    let text: LocalizedStringKey
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

    let title: LocalizedStringKey
    let health: Health
    let note: LocalizedStringKey        // "granted" / "not granted" / "logged in"
    var tip: LocalizedStringKey? = nil  // the info-icon explanation (InfoTip)
    var fixTitle: LocalizedStringKey = "Fix…"
    var fix: (() -> Void)? = nil

    /// Status-LED colors — warn stays punchier than the ink amber on purpose.
    private var dot: Color {
        switch health {
        case .ok:   return Theme.Ink.green
        case .warn: return Color(red: 1.0, green: 0.72, blue: 0.30)
        case .bad:  return Theme.Ink.red
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
            Text(note)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(health == .ok ? Theme.Ink.label : dot)
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
    let placeholder: LocalizedStringKey
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

/// The hairline that separates lines inside a group — or, a touch brighter, whole groups.
/// `color` is for the one semantic exception: the red line guarding System's destructive tail.
struct SettingsHairline: View {
    var color: Color = .white
    var opacity: Double = 0.06

    var body: some View {
        Rectangle().fill(color.opacity(opacity)).frame(height: 1)
    }
}
