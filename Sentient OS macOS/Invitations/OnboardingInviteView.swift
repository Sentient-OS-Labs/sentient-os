// Onboarding's corner invitation: code entry, verified redemption, and the lifetime gift overlay.
// Only an explicit successful redemption presents the gift; restored receipts show the saved pass.
// Doc: ../Views/Onboarding/Documentation - Onboarding.md

import SwiftUI

struct OnboardingInviteView: View {
    @Binding var isPresentingGift: Bool
    @State private var program = InviteProgram.shared
    @State private var code = ""
    @State private var expanded = true
    @State private var hovering = false
    @State private var redemption: Task<Void, Never>?
    @FocusState private var codeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ticket
#if DEBUG
    // Replay the entry and reveal on a developer's Mac without discarding its permanent grant.
    @AppStorage("dev.invites.replay") private var replayInvitation = false
#endif

    private var hasAccess: Bool {
#if DEBUG
        if replayInvitation { return false }
#endif
        return program.snapshot?.hasLifetimeAccess == true
    }
    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.55, bounce: 0.12) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if !isPresentingGift {
                Group {
                    if hasAccess {
                        InviteTicketFace(claimed: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Sentient OS lifetime access is saved")
                    } else if expanded {
                        entryTicket
                    } else {
                        Button {
                            program.clearError()
                            withAnimation(motion) {
                                expanded = true
                            } completion: {
                                if expanded && !isPresentingGift { codeFocused = true }
                            }
                        } label: {
                            InviteTicketFace()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Have a gift code? Enter your code.")
                        .help("Redeem your invitation")
                        .onHover { hovering = $0 }
                        .rotationEffect(.degrees(reduceMotion ? 0 : (hovering ? 0 : -2)))
                        .offset(y: hovering && !reduceMotion ? -4 : 0)
                        .animation(motion, value: hovering)
                    }
                }
                .frame(width: 332)
                .matchedGeometryEffect(id: "invite-ticket", in: ticket)
                .padding(.trailing, 36).padding(.bottom, 44)
                .transition(.opacity)
            }

            if isPresentingGift {
                InviteCelebration(ticketNamespace: ticket) {
                    withAnimation(motion) { isPresentingGift = false; expanded = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .task { await program.refresh(createIfNeeded: false) }
        .onDisappear {
            redemption?.cancel()
            redemption = nil
            isPresentingGift = false
        }
    }

    private var entryTicket: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Have a gift code?").font(.system(size: 26, weight: .medium))
                Spacer()
                Button {
                    codeFocused = false
                    withAnimation(motion) { expanded = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(InvitePaper.ink.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain).disabled(program.isRedeeming)
                .accessibilityLabel("Close invite code field")
            }
            .padding(.horizontal, 22).frame(height: 86)
            InvitePerforation()

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    TextField("Enter invite code", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .autocorrectionDisabled()
                        .tint(InvitePaper.ink)
                        .focused($codeFocused)
                        .onSubmit(redeem)
                        .onChange(of: code) { program.clearError() }
                        .accessibilityLabel("Invite code")
                    Button(action: redeem) {
                        Group {
                            if program.isBusy {
                                ProgressView().controlSize(.small).tint(InvitePaper.light)
                            } else {
                                Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .frame(width: 32, height: 32)
                        .foregroundStyle(InvitePaper.light)
                        .background(InvitePaper.ink, in: RoundedRectangle(cornerRadius: 7))
                        .opacity(program.isBusy || !InviteSnapshot.isValidCode(code) ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(program.isBusy || !InviteSnapshot.isValidCode(code))
                    .accessibilityLabel("Redeem invite code")
                }
                .padding(.leading, 12).padding(.trailing, 5).frame(height: 44)
                .background(.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(InvitePaper.ink.opacity(codeFocused ? 0.4 : 0.15), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .disabled(program.isRedeeming)

                if let error = program.errorMessage {
                    Text(error).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.16, blue: 0.12))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(program.isRedeeming ? "Checking your invitation…" : "Redeem your invitation.")
                        .font(.system(size: 10)).opacity(0.6)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .foregroundStyle(InvitePaper.ink)
        .environment(\.colorScheme, .light)
        .modifier(InviteTicketMaterial())
    }

    private func redeem() {
        guard redemption == nil, !program.isBusy, InviteSnapshot.isValidCode(code) else { return }
        codeFocused = false
        let submittedCode = code
        redemption = Task {
            defer { redemption = nil }
            let redeemed = await program.redeem(submittedCode)
            guard !Task.isCancelled else { return }
            if redeemed {
                withAnimation(motion) {
                    isPresentingGift = true
#if DEBUG
                    replayInvitation = false
#endif
                }
            } else {
                codeFocused = true
            }
        }
    }
}
