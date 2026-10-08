//
//  SettingsComponents.swift
//  Sentient OS macOS
//
//  Settings scaffolds, grouped forms, rows, and controls. The form appearance is scoped to
//  SettingsPane; Knowledge Sources and shared onboarding controls keep their original styling.
//  Doc: Documentation - Settings.md
//

import SwiftUI

/// Opt-in styling keeps shared source pickers and onboarding visually unchanged.
private struct SettingsFormStyleKey: EnvironmentKey {
    static let defaultValue = false
}

/// Headings can use Settings typography without restyling the source picker's controls.
private struct SettingsHeadingStyleKey: EnvironmentKey {
    static let defaultValue = false
}

/// Permissions & Health uses tighter spacing throughout its shared form components.
private struct SettingsCompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsFormStyle: Bool {
        get { self[SettingsFormStyleKey.self] }
        set { self[SettingsFormStyleKey.self] = newValue }
    }

    var settingsHeadingStyle: Bool {
        get { self[SettingsHeadingStyleKey.self] }
        set { self[SettingsHeadingStyleKey.self] = newValue }
    }

    var settingsCompactLayout: Bool {
        get { self[SettingsCompactLayoutKey.self] }
        set { self[SettingsCompactLayoutKey.self] = newValue }
    }
}

enum SettingsStyle {
    static let secondary = Color.white.opacity(0.62)
    static let border = Color.white.opacity(0.12)
    static let control = Color(white: 0.075)
}

/// Readable page title and a centered, bounded measure. Sources retains its existing scaffold.
struct SettingsPane<Content: View>: View {
    @Environment(\.settingsCompactLayout) private var compactLayout
    let title: String
    var whisper: String? = nil
    var legacyLayout = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .display(28)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                if let whisper {
                    Text(whisper)
                        .font(.system(size: legacyLayout ? 12.5 : (compactLayout ? 14 : 15)))
                        .foregroundStyle(.white.opacity(legacyLayout ? 0.72 : 0.62))
                        .lineSpacing(legacyLayout ? 0 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, legacyLayout ? 7 : 8)
                }
                content.padding(.top, legacyLayout ? 26 : (compactLayout ? 20 : 30))
            }
            .frame(maxWidth: legacyLayout || compactLayout ? 640 : 720, alignment: .leading)
            .padding(.horizontal, legacyLayout ? 38 : 40)
            .padding(.top, legacyLayout || compactLayout ? 28 : 38)
            .padding(.bottom, legacyLayout || compactLayout ? 28 : 44)
            .frame(maxWidth: .infinity, alignment: legacyLayout ? .leading : .center)
        }
        .environment(\.settingsFormStyle, !legacyLayout)
    }
}

/// A sentence-case heading above one bordered group of related settings.
/// The original source/onboarding appearance remains the default outside SettingsPane.
struct SettingsGroup<Content: View, Trailing: View>: View {
    @Environment(\.settingsFormStyle) private var formStyle
    @Environment(\.settingsHeadingStyle) private var headingStyle
    @Environment(\.settingsCompactLayout) private var compactLayout
    let label: String
    let badge: String?
    let description: String?
    let inset: CGFloat
    let destructive: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    init(label: String, badge: String? = nil, description: String? = nil,
         inset: CGFloat = 20, destructive: Bool = false,
         @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.badge = badge
        self.description = description
        self.inset = inset
        self.destructive = destructive
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: formStyle ? (compactLayout ? 10 : 14) : 13) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if formStyle || headingStyle {
                        Text(label)
                            .font(.system(size: compactLayout ? 16 : 18, weight: .medium))
                            .foregroundStyle(destructive ? Theme.Ink.red : .white)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        MonoCaps(label, size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
                    }
                    if let badge {
                        if formStyle || headingStyle {
                            Text(badge).font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                        } else {
                            MonoCaps("· \(badge)", size: 8, tracking: 1.6, color: .white.opacity(0.5))
                        }
                    }
                    if Trailing.self != EmptyView.self {
                        Spacer(minLength: 12)
                        trailing
                    }
                }
                if let description { SettingsProse(description) }
            }
            if formStyle {
                content
                    .padding(.horizontal, compactLayout ? min(inset, 16) : inset)
                    .padding(.vertical, compactLayout ? min(inset, 9) : inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(destructive ? Theme.Ink.red.opacity(0.32) : SettingsStyle.border, lineWidth: 1))
            } else {
                content
            }
        }
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(label: String, badge: String? = nil, description: String? = nil,
         inset: CGFloat = 20, destructive: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(label: label, badge: badge, description: description, inset: inset,
                  destructive: destructive, content: content, trailing: { EmptyView() })
    }
}

struct SettingsProse: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: formStyle ? 14 : 11.5))
            .foregroundStyle(formStyle ? SettingsStyle.secondary : Theme.Ink.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared label/control alignment for action rows, menus, and switches.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                if let subtitle { SettingsProse(subtitle) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control.fixedSize(horizontal: true, vertical: false)
        }
        .padding(20)
        .frame(minHeight: 76)
    }
}

struct SettingToggleLine: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let title: String
    let sub: String
    @Binding var isOn: Bool

    var body: some View {
        if formStyle {
            SettingsRow(title: title, subtitle: sub) {
                Toggle(title, isOn: $isOn)
                    .labelsHidden().toggleStyle(.switch).tint(Theme.Ink.green)
                    .controlSize(.regular)
            }
        } else {
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
}

/// A quiet, consistently sized action. Disabled and hover states remain visible on black.
struct SettingsPillButton: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let title: String
    var tint: Color = Theme.Ink.bright
    let action: () -> Void

    var body: some View {
        if formStyle {
            Button(title, action: action)
                .buttonStyle(SettingsActionStyle(tint: tint))
        } else {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(
                        tint == Theme.Ink.bright ? Color.white.opacity(0.16) : tint.opacity(0.4), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
        }
    }
}

struct SettingsActionStyle: ButtonStyle {
    @State private var hovered = false
    var tint: Color = Theme.Ink.bright
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsCompactLayout) private var compactLayout

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compactLayout ? 13 : 14, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, compactLayout ? 12 : 14)
            .frame(minHeight: compactLayout ? 30 : 36)
            .background(hovered && isEnabled ? Color(white: 0.12) : SettingsStyle.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .brightness(configuration.isPressed ? 0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

/// A standard menu picker with the same border, height, and type as action buttons.
struct SettingsMenu<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.inline)
                .menuActionDismissBehavior(.enabled)
        } label: {
            Text(value).font(.system(size: 14)).foregroundStyle(.white.opacity(0.9))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12).padding(.trailing, 32)
        .frame(height: 36)
        .background(SettingsStyle.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SettingsStyle.secondary)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Extra explanation stays available without competing with everyday controls.
struct SettingsDetails<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(.top, 10)
        } label: {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(SettingsStyle.secondary)
        }
        .tint(SettingsStyle.secondary)
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
/// `needsAttention` uses a flat amber dot for a connector that needs reconnecting.
struct SettingsChip: View {
    let label: String
    var detail: String? = nil
    let on: Bool
    var isAction: Bool = false
    var locked: Bool = false
    var needsAttention: Bool = false
    var action: (() -> Void)? = nil

    @State private var lockHover = false

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
                        .fill(needsAttention ? HealthDot.warnAmber : (on ? Theme.Ink.green : .white.opacity(0.4)))
                        .frame(width: 5, height: 5)
                }
                Text(label)
                    .font(.system(size: 12, weight: on || isAction ? .medium : .regular))
                    .foregroundStyle(.white.opacity(locked ? 0.55 : 1))
                if let detail {
                    Text(detail).font(.system(size: 10.5))
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
        Text(CodexAuth.connectorLockedTip)
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
    /// The punchy warn amber every status LED shares — brighter than the ink amber on purpose.
    static let warnAmber = Color(red: 1.0, green: 0.72, blue: 0.30)

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
    @Environment(\.settingsFormStyle) private var formStyle
    let text: String
    @State private var shown = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: formStyle ? 13 : 10))
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
                    .font(.system(size: formStyle ? 13 : 11.5))
                    .lineSpacing(2.5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(width: 250, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// A health row with a verdict, readable status, and an inline fix. Shared permission gates
/// retain their compact labels outside the Settings form.
struct StatusLine: View {
    @Environment(\.settingsFormStyle) private var formStyle
    @Environment(\.settingsCompactLayout) private var compactLayout
    enum Health { case ok, warn, bad }

    let title: String
    let health: Health
    let note: String                    // "granted" / "not granted" / "logged in"
    var tip: String? = nil              // the info-icon explanation (InfoTip)
    var fixTitle: String = "Fix…"
    var fix: (() -> Void)? = nil

    private var dot: Color {
        switch health {
        case .ok:   return Theme.Ink.green
        case .warn: return HealthDot.warnAmber
        case .bad:  return Theme.Ink.red
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            HealthDot(color: dot)
            HStack(spacing: 6) {
                Text(title).font(.system(size: formStyle ? (compactLayout ? 14 : 15) : 12.5))
                    .foregroundStyle(Theme.Ink.statusInk)
                if let tip { InfoTip(text: tip) }
            }
            Spacer(minLength: 12)
            if formStyle {
                Text(note.prefix(1).uppercased() + note.dropFirst())
                    .font(.system(size: 13))
                    .foregroundStyle(health == .ok ? SettingsStyle.secondary : dot)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MonoCaps(note, size: 8.5, tracking: 1.6,
                         color: health == .ok ? Theme.Ink.label : dot)
            }
            if health != .ok, let fix {
                SettingsPillButton(title: fixTitle, action: fix)
            }
        }
        .padding(.vertical, formStyle ? (compactLayout ? 9 : 14) : 6)
    }
}

/// A multiline text box — the one bordered input surface in Settings. Autosaves through its
/// binding (pair with @AppStorage at the call site); shows a quiet placeholder while empty.
struct SettingsTextBox: View {
    @Environment(\.settingsFormStyle) private var formStyle
    @FocusState private var focused: Bool
    let placeholder: String
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder insets must mirror the editor's first line exactly: the editor sits at
            // (horizontal 7 + NSTextView's ~5pt line-fragment padding, vertical 8) → (12, 8).
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: formStyle ? 14 : 11.5)).foregroundStyle(.white.opacity(formStyle ? 0.45 : 0.55))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: formStyle ? 14 : 11.5)).foregroundStyle(Theme.Ink.statusInk)
                .focused($focused)
                .accessibilityLabel(placeholder)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7).padding(.vertical, 8)
        }
        .frame(minHeight: formStyle ? 96 : 64)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(formStyle && focused ? Color.white.opacity(0.38) : Theme.stroke, lineWidth: 1))
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
