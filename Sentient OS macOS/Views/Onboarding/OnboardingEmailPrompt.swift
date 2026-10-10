// OnboardingEmailPrompt.swift
// Required email entry when onboarding reaches the source picker. submit() validates the
// address; the save task uses the secure onboarding contact queue before allowing continuation.
// Doc: Documentation - Onboarding.md

import SwiftUI

struct OnboardingEmailPrompt: View {
    let onSaved: () -> Void

    @State private var email = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "envelope")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Theme.Ink.bright)
                .accessibilityHidden(true)

            Text("What’s your email?")
                .display(27)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                MonoCaps("Email address", size: 9, tracking: 1.5, color: Theme.secondary)
                TextField("Email address", text: $email,
                          prompt: Text(verbatim: "you@example.com").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(errorMessage == nil ? Color.white.opacity(emailFocused ? 0.35 : 0.12)
                                          : Theme.Ink.red.opacity(0.7), lineWidth: 1)
                    }
                    .focused($emailFocused)
                    .disabled(isSaving)
                    .privacySensitive()
                    .accessibilityLabel("Email address")
                    .onSubmit(submit)
                    .onChange(of: email) { errorMessage = nil }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Only your email address is saved to our feedback list. No account is created.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                OnboardingNextButton(title: isSaving ? "Saving…" : "Save & Continue",
                                     enabled: !isSaving && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                     action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 460)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear { emailFocused = true }
        .task(id: isSaving) {
            guard isSaving, let address = MailAccount.normalizedEmail(email) else { return }
            do {
                // A false result still means the address is safely queued for background retry.
                _ = try await MailAccountCloud.onboarding.save([address])
                guard !Task.isCancelled else { return }
                onSaved()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Your email couldn’t be saved on this Mac. Please try again."
                isSaving = false
                emailFocused = true
            }
        }
    }

    private func submit() {
        guard !isSaving else { return }
        guard MailAccount.normalizedEmail(email) != nil else {
            errorMessage = "Enter a valid email address to continue."
            emailFocused = true
            return
        }
        errorMessage = nil
        isSaving = true
    }
}

#Preview("Onboarding email") {
    OnboardingEmailPrompt(onSaved: {})
}
