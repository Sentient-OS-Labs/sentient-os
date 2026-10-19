// Home's permanent Double Tap lesson and quiet, temporary notch cue. The ready hint waits
// for visible Home, never takes focus, and acknowledges only a completed viewing or click.
// Doc: Documentation - Views - Home, Processing & Shared UI.md
import SwiftUI
import AppKit

struct HomeDoubleTapButton: View {
    let active: Bool
    @Binding var presented: Bool
    var onViewAnalysis: () -> Void
    @AppStorage(ShortcutPreferences.storageKey) private var shortcutRaw = ShortcutKey.rightCommand.rawValue
    @AppStorage(DoubleTap.enabledKey) private var enabled = true
    @AppStorage(ProcessingPlan.initialCompletedKey) private var completedAt = 0.0
    @AppStorage(SidekickDiscovery.readyHintSeenKey) private var seenAt = 0.0
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var hovered = false
    @State private var homeIsKey = false
    @State private var noticeVisible = false
    @State private var highlight = 0.0

    private var key: ShortcutKey { ShortcutKey(rawValue: shortcutRaw) ?? .rightCommand }
    private var reduced: Bool { (motionOverride ?? systemReduced) || lowPower }
    private var ready: Bool { completedAt > 0 && enabled }
    private var offerNotice: Bool {
        active && homeIsKey && ready && !presented
            && SidekickDiscovery.readyHintPending(completedAt: completedAt, seenAt: seenAt)
    }
    private struct NoticeIdentity: Equatable {
        let eligible: Bool
        let completion: Double
    }

    var body: some View {
        Button {
            if ready { seenAt = completedAt }
            presented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: key.discoverySymbol).font(.system(size: 14.5, weight: .semibold))
                Text("Double Tap").font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(hovered || noticeVisible || presented ? .white : Theme.Ink.bright)
            .padding(.horizontal, 11).frame(height: 40)
            .background(Capsule().fill(.white.opacity(hovered || presented ? 0.07 : 0)))
            .background(Capsule().fill(Theme.Ink.gold.opacity(0.10 * highlight)))
            .overlay(Capsule().strokeBorder(Theme.Ink.gold.opacity(0.55 * highlight), lineWidth: 1))
            .shadow(color: Theme.Ink.gold.opacity(0.20 * highlight), radius: 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .onHover { hovered = $0 }
        .accessibilityIdentifier("navigation.doubleTap")
        .accessibilityLabel("Double Tap")
        .accessibilityValue(enabled ? (completedAt > 0 ? "Ready" : "Ready after your first analysis") : "Turned off")
        .help(ready ? "Draft a reply with two taps of \(key.label)."
              : (enabled ? "Double Tap unlocks after your first analysis." : "Double Tap is turned off."))
        .overlay(alignment: .bottom) {
            if noticeVisible {
                Text("Double Tap is ready")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Color(white: 0.065), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Ink.gold.opacity(0.24), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.35), radius: 9, y: 4)
                    .fixedSize().offset(y: 37)
                    .accessibilityIdentifier("doubleTap.readyHint")
                    .allowsHitTesting(false)
                    .transition(SidekickStyle.entrance(reduced))
            }
        }
        .popover(isPresented: $presented) {
            lesson
        }
        .background(SidekickWindowPresence(requiresKeyWindow: true) { homeIsKey = $0 }
            .allowsHitTesting(false).accessibilityHidden(true))
        .task(id: NoticeIdentity(eligible: offerNotice, completion: completedAt)) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-discovery" {
                Log("Discovery hint: eligible=\(offerNotice), active=\(active), presented=\(presented)")
            }
            #endif
            guard offerNotice else { noticeVisible = false; highlight = 0; return }
            let completion = completedAt
            do {
                // Let Home's own entrance settle before drawing attention to a new capability.
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
                withAnimation(reduced ? .easeOut(duration: 0.15) : .smooth(duration: 0.45)) {
                    noticeVisible = true; highlight = 1
                }
                NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                    userInfo: [.announcement: "Double Tap is ready. Tap \(key.spokenLabel) twice in a reply box.",
                               .priority: NSAccessibilityPriorityLevel.low.rawValue])
                try await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeOut(duration: reduced ? 0.15 : 1.2)) { highlight = 0.35 }
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
                // Hiding Home cancels this task before acknowledgement, so the hint can wait.
                seenAt = completion
                #if DEBUG
                if ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-discovery" { Log("Discovery hint acknowledged") }
                #endif
                withAnimation(.easeOut(duration: 0.25)) { noticeVisible = false; highlight = 0 }
            } catch {
                #if DEBUG
                if ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-discovery" { Log("Discovery hint interrupted") }
                #endif
                noticeVisible = false; highlight = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private var lesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 17) {
                DoubleTapKeyLesson(key: key, animating: active && presented && !reduced)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Double Tap").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                    Text("Replies in your voice.")
                        .font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                }
            }
            if !enabled {
                Text("Double Tap is turned off.")
                    .font(.system(size: 13)).foregroundStyle(SidekickStyle.ink)
                Button("Turn on Double Tap") {
                    enabled = true
                    if completedAt > 0 { seenAt = completedAt }
                }.buttonStyle(SidekickPressStyle())
            } else if completedAt <= 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Ready after your first analysis.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                        .accessibilityIdentifier("doubleTap.waiting")
                    Text("Your first analysis gives Double Tap your personal context. Then click a reply box and tap \(key.label) twice.")
                        .font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary).lineSpacing(3)
                }
                Button {
                    presented = false; onViewAnalysis()
                } label: {
                    Label("View analysis", systemImage: "arrow.up.right")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                        .padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("doubleTap.viewAnalysis")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Click a reply box, then tap **\(key.label) twice**.")
                        .font(.system(size: 13)).foregroundStyle(SidekickStyle.ink).lineSpacing(3)
                        .accessibilityIdentifier("doubleTap.instructions")
                    Text("Your draft appears right where you’re typing. Review it, then send.")
                        .font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary).lineSpacing(3)
                }
            }
            Text("One tap opens Sidekick.")
                .font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(22).frame(width: 302)
        .background(Theme.Ink.cardBG).preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doubleTap.lesson")
    }
}

private struct DoubleTapKeyLesson: View {
    let key: ShortcutKey
    let animating: Bool
    @State private var pressed = false
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: key.discoverySymbol)
                .font(.system(size: 25, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 56, height: 50)
                .background(Color(white: pressed ? 0.15 : 0.10), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(pressed ? Theme.Ink.gold.opacity(0.6) : .white.opacity(0.16), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.5), radius: 0, y: pressed ? 1 : 3)
                .scaleEffect(pressed ? 0.95 : 1).offset(y: pressed ? 2 : 0)
                .animation(.easeOut(duration: 0.1), value: pressed)
            HStack(spacing: 5) {
                ForEach(1...2, id: \.self) { index in
                    Circle().fill(taps >= index || !animating ? Theme.Ink.gold : .white.opacity(0.18))
                        .frame(width: 3, height: 3)
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: animating) {
            guard animating else { pressed = false; taps = 0; return }
            do {
                while !Task.isCancelled {
                    taps = 0
                    try await Task.sleep(for: .milliseconds(600))
                    for count in 1...2 {
                        pressed = true; taps = count
                        try await Task.sleep(for: .milliseconds(120))
                        pressed = false
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch { pressed = false; taps = 0 }
        }
    }
}

struct HomeNotchHint: View {
    let coordinator: CommandCoordinator
    @AppStorage(ShortcutPreferences.storageKey) private var shortcutRaw = ShortcutKey.rightCommand.rawValue
    @AppStorage(NotchPreferences.clickEnabledKey) private var clickable = true
    @AppStorage(SidekickDiscovery.notchUsesKey) private var uses = 0
    @State private var hovered = false
    private var key: ShortcutKey { ShortcutKey(rawValue: shortcutRaw) ?? .rightCommand }

    var body: some View {
        if uses < SidekickDiscovery.notchLearningUses && !coordinator.run.isRunning && coordinator.phase == .hidden {
            Button { coordinator.openNotchFromHome() } label: {
                HStack(spacing: 5) {
                    Text(clickable ? "Try the notch" : "Press \(key.label)")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                }
                .font(.system(size: 11.5)).foregroundStyle(hovered ? SidekickStyle.ink : SidekickStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityIdentifier("sidekick.notchHint")
            .accessibilityLabel("Open Sidekick in the notch")
            .help(clickable ? "Sidekick is in your notch, too. Click it or press \(key.label) from any app."
                  : "Press \(key.label) to open Sidekick from any app.")
        }
    }
}

private extension ShortcutKey {
    var discoverySymbol: String {
        switch self {
        case .rightCommand, .leftCommand: "command"
        case .rightOption, .leftOption: "option"
        case .rightControl, .leftControl: "control"
        }
    }
}
