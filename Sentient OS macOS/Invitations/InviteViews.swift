// InviteViews.swift
// The onboarding redemption field, Settings invitation section, and in-app offer content.
// All surfaces use InviteProgram; presentation-only pieces also support offline previews.
// Doc: Views/Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI
import AppKit

struct InviteRedemptionView: View {
    @Environment(\.settingsFormStyle) private var formStyle
    var startsCollapsed = false
    @State private var program = InviteProgram.shared
    @State private var code = ""
    @State private var hasExpanded = false
    @FocusState private var codeFocused: Bool

    private var isCollapsed: Bool {
        startsCollapsed && !hasExpanded && program.snapshot?.hasLifetimeAccess != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if program.snapshot?.hasLifetimeAccess == true {
                Label("Lifetime access unlocked!", systemImage: "checkmark.seal.fill")
                    .font(.system(size: formStyle ? 15 : 13, weight: .medium))
                    .foregroundStyle(Theme.Ink.green)
                Text("Your Sentient OS access is saved.")
                    .font(.system(size: formStyle ? 13 : 11)).foregroundStyle(Theme.Ink.body)
            } else if isCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hasExpanded = true
                    } completion: {
                        codeFocused = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Have an invite code?").font(.system(size: 14, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.white.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show the invite code field")
            } else {
                Text("Have an invite code?")
                    .font(.system(size: formStyle ? 15 : 13, weight: .medium)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    TextField("Enter invite code", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: formStyle ? 14 : 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .focused($codeFocused)
                        .onSubmit(redeem)
                        .accessibilityLabel("Invite code")
                        .onChange(of: code) { _, value in
                            if value.count > 64 { code = String(value.prefix(64)) }
                            program.clearError()
                        }
                    Button(action: redeem) {
                        Group {
                            if program.isBusy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.right").font(.system(size: formStyle ? 15 : 13, weight: .medium)) }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(program.isBusy || !InviteSnapshot.isValidCode(code))
                    .help("Redeem invite code")
                    .accessibilityLabel("Redeem invite code")
                }
                .padding(.leading, 12).padding(.trailing, 6)
                .frame(height: 40)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15)))
                .disabled(program.isRedeeming)
                if let error = program.errorMessage {
                    Text(error).font(.system(size: formStyle ? 13 : 11)).foregroundStyle(Theme.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .trailing : .leading)
        .task { await program.refresh(createIfNeeded: false) }
    }

    private func redeem() {
        guard !program.isBusy, InviteSnapshot.isValidCode(code) else { return }
        Task { await program.redeem(code) }
    }
}

struct InviteSettingsSection: View {
    @Environment(\.settingsFormStyle) private var formStyle
    @State private var program = InviteProgram.shared

    var body: some View {
        SettingsGroup(label: "Invitations") {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = program.snapshot, snapshot.canShare, let code = snapshot.code {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("5 invitations, reserved for you")
                            .font(.system(size: formStyle ? 15 : 13, weight: .medium)).foregroundStyle(.white)
                        Text("Share Sentient OS free\u{00A0}for\u{00A0}life with just 5\u{00A0}people you choose.")
                            .font(.system(size: formStyle ? 14 : 12)).foregroundStyle(Theme.Ink.body)
                    }
                    InviteCopyButton(code: code)
                    if snapshot.redemptionCount > 0 {
                        Text(snapshot.redemptionCount == 1 ? "1 invitation accepted." : "\(snapshot.redemptionCount) invitations accepted.")
                            .font(.system(size: formStyle ? 13 : 11)).foregroundStyle(Theme.Ink.body)
                    }
                } else if let snapshot = program.snapshot, !snapshot.canShare {
                    Text("This invitation offer has closed.")
                        .font(.system(size: formStyle ? 15 : 13)).foregroundStyle(Theme.Ink.body)
                } else {
                    SettingsPillButton(title: program.isBusy ? "Preparing your invitations…" : "View your invitations") {
                        Task { await program.refresh() }
                    }
                    .disabled(program.isBusy)
                }
                InviteRedemptionView(startsCollapsed: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            // Friends can redeem while this pane stays open. Refresh only existing identities.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await program.refresh(createIfNeeded: false, quietly: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await program.refresh(createIfNeeded: false, quietly: true) }
        }
    }
}

struct InviteCopyButton: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let code: String
    var showsCode = true
    @State private var program = InviteProgram.shared
    @State private var copied = false
    @State private var copying = false
    @State private var copyFailed = false

    var body: some View {
        Button {
            guard !copying else { return }
            copying = true
            copied = false
            copyFailed = false
            Task {
                let verified = await program.refresh()
                if verified, program.snapshot?.canShare == true, let currentCode = program.snapshot?.code {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copied = pasteboard.setString(InviteSnapshot.displayCode(currentCode), forType: .string)
                }
                copyFailed = !copied
                copying = false
            }
        } label: {
            HStack(spacing: 10) {
                Text(showsCode ? InviteSnapshot.displayCode(code) : actionTitle)
                    .font(.system(size: formStyle ? 14 : 12, weight: .medium, design: showsCode ? .monospaced : .default))
                Image(systemName: copied ? "checkmark" : (copyFailed ? "arrow.clockwise" : "doc.on.doc"))
                    .font(.system(size: formStyle ? 14 : 12)).frame(width: 16, height: 18)
            }
            .foregroundStyle(copied ? Theme.Ink.green : .white)
            .padding(.horizontal, 12).frame(height: 36)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
            .opacity(copying ? 0.5 : 1)
        }
        .buttonStyle(.plain).disabled(copying || program.isBusy)
        .help(copyFailed ? "Couldn't verify this invite. Click to retry." : (copied ? "Invite code copied" : "Copy invite code"))
        .accessibilityLabel(copyFailed ? "Retry copying invite code" : (copied ? "Invite code copied" : "Copy invite code"))
        .onChange(of: code) { copied = false; copyFailed = false }
    }

    private var actionTitle: String {
        if copying { return "Checking invite…" }
        if copyFailed { return "Try again" }
        return copied ? "Copied" : "Copy invite code"
    }
}

struct InviteBannerView: View {
    let code: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            InviteHandIcon()
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 38).padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(InviteProgram.offerTitle)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(InviteProgram.offerMessage)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                InviteCopyButton(code: code, showsCode: false).padding(.top, 3)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)).frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Dismiss invitation")
            .accessibilityLabel("Dismiss invitation")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
    }
}

/// A ribbon tied around an index finger, drawn as a small monochrome vector.
private struct InviteHandIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Raised finger and the outside of the hand. The bow interrupts the finger outline.
        path.move(to: CGPoint(x: 34, y: 10))
        path.addCurve(to: CGPoint(x: 55, y: 10), control1: CGPoint(x: 38, y: -1), control2: CGPoint(x: 51, y: -1))
        path.move(to: CGPoint(x: 33, y: 39))
        path.addLine(to: CGPoint(x: 33, y: 93))
        path.move(to: CGPoint(x: 33, y: 82))
        path.addLine(to: CGPoint(x: 17, y: 70))
        path.addCurve(to: CGPoint(x: 5, y: 85), control1: CGPoint(x: 6, y: 61), control2: CGPoint(x: -1, y: 77))
        path.addLine(to: CGPoint(x: 29, y: 123))
        path.addCurve(to: CGPoint(x: 39, y: 138), control1: CGPoint(x: 32, y: 130), control2: CGPoint(x: 31, y: 138))
        path.addLine(to: CGPoint(x: 79, y: 138))
        path.addCurve(to: CGPoint(x: 99, y: 96), control1: CGPoint(x: 94, y: 123), control2: CGPoint(x: 99, y: 109))
        path.addLine(to: CGPoint(x: 99, y: 82))
        path.addCurve(to: CGPoint(x: 85, y: 68), control1: CGPoint(x: 99, y: 71), control2: CGPoint(x: 95, y: 68))

        // Three curled fingers.
        path.move(to: CGPoint(x: 54, y: 39))
        path.addLine(to: CGPoint(x: 54, y: 74))
        path.move(to: CGPoint(x: 54, y: 51))
        path.addCurve(to: CGPoint(x: 69, y: 66), control1: CGPoint(x: 65, y: 50), control2: CGPoint(x: 69, y: 54))
        path.addLine(to: CGPoint(x: 69, y: 83))
        path.move(to: CGPoint(x: 69, y: 59))
        path.addCurve(to: CGPoint(x: 85, y: 75), control1: CGPoint(x: 80, y: 58), control2: CGPoint(x: 85, y: 62))
        path.addLine(to: CGPoint(x: 85, y: 92))

        // Two ribbon loops and their loose ends.
        path.move(to: CGPoint(x: 44, y: 23))
        path.addCurve(to: CGPoint(x: 8, y: 10), control1: CGPoint(x: 24, y: 8), control2: CGPoint(x: 15, y: 4))
        path.addCurve(to: CGPoint(x: 44, y: 23), control1: CGPoint(x: -6, y: 29), control2: CGPoint(x: 18, y: 40))
        path.addCurve(to: CGPoint(x: 79, y: 10), control1: CGPoint(x: 63, y: 8), control2: CGPoint(x: 72, y: 4))
        path.addCurve(to: CGPoint(x: 44, y: 23), control1: CGPoint(x: 94, y: 29), control2: CGPoint(x: 69, y: 40))
        path.move(to: CGPoint(x: 28, y: 45))
        path.addLine(to: CGPoint(x: 44, y: 23))
        path.addLine(to: CGPoint(x: 60, y: 45))

        return path.applying(CGAffineTransform(scaleX: rect.width / 104, y: rect.height / 144))
            .applying(CGAffineTransform(translationX: rect.minX + rect.width * 2 / 104,
                                      y: rect.minY + rect.height * 2 / 144))
    }
}

#if DEBUG
#Preview("Invite banner") {
    InviteBannerView(code: "ABCD1234EFAB5678", dismiss: {})
        .frame(width: 380).padding(20).background(.gray.opacity(0.25))
}
#Preview("Invite redemption") {
    InviteRedemptionView().frame(width: 320).padding(28).background(.black)
}
#Preview("Onboarding invite disclosure") {
    InviteRedemptionView(startsCollapsed: true)
        .frame(width: 320).padding(28).background(.black)
}
#endif
