// InviteViews.swift
// The onboarding redemption field, Settings invitation section, and floating offer content.
// All surfaces use InviteProgram; presentation-only pieces also support offline previews.

import SwiftUI
import AppKit

struct InviteRedemptionView: View {
    @State private var program = InviteProgram.shared
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if program.snapshot?.hasLifetimeAccess == true {
                Label("Lifetime access unlocked!", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Ink.green)
                Text("Your Sentient OS access is saved.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
            } else {
                Text("Have an invite code?")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    TextField("Enter invite code", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white)
                        .onSubmit(redeem)
                        .accessibilityLabel("Invite code")
                        .onChange(of: code) { _, value in
                            if value.count > 64 { code = String(value.prefix(64)) }
                            program.clearError()
                        }
                    Button(action: redeem) {
                        Group {
                            if program.isBusy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.right").font(.system(size: 13, weight: .medium)) }
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
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await program.refresh(createIfNeeded: false) }
    }

    private func redeem() {
        guard !program.isBusy, InviteSnapshot.isValidCode(code) else { return }
        Task { await program.redeem(code) }
    }
}

struct InviteSettingsSection: View {
    @State private var program = InviteProgram.shared

    var body: some View {
        SettingsGroup(label: "Invitations") {
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = program.snapshot, snapshot.canShare, let code = snapshot.code {
                    Text(InviteProgram.offerTitle + " " + InviteProgram.offerMessage)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    InviteCopyButton(code: code)
                    if snapshot.redemptionCount > 0 {
                        Text(snapshot.redemptionCount == 1 ? "1 friend joined." : "\(snapshot.redemptionCount) friends joined.")
                            .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    }
                } else if let snapshot = program.snapshot, !snapshot.canShare {
                    Text("The invite offer has ended.")
                        .font(.system(size: 13)).foregroundStyle(Theme.Ink.body)
                } else {
                    SettingsPillButton(title: program.isBusy ? "Checking invites..." : "Get invite code") {
                        Task { await program.refresh() }
                    }
                    .disabled(program.isBusy)
                }
                InviteRedemptionView().frame(maxWidth: 340)
                Text("Lifetime access covers Sentient OS. Your model subscriptions and usage limits still apply. Access is saved to this Mac's Keychain and survives Reset.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
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
    let code: String
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
                Text(InviteSnapshot.displayCode(code))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Image(systemName: copied ? "checkmark" : (copyFailed ? "arrow.clockwise" : "doc.on.doc"))
                    .font(.system(size: 12)).frame(width: 16, height: 18)
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
}

struct InviteBannerView: View {
    let code: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gift")
                .font(.system(size: 18, weight: .light)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(InviteProgram.offerTitle)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Text(InviteProgram.offerMessage)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                InviteCopyButton(code: code).padding(.top, 3)
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
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
#Preview("Invite banner") {
    InviteBannerView(code: "ABCD1234EFAB5678", dismiss: {})
        .frame(width: 380, height: 120).padding(20).background(.gray.opacity(0.25))
}
#Preview("Invite redemption") {
    InviteRedemptionView().frame(width: 320).padding(28).background(.black)
}
#endif
