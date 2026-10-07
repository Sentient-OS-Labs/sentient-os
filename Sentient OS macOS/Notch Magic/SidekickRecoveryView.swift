// The expanded notch's error, two immediate answers, and separate editable steering field.
// Draft and timing live in SidekickRecovery, so dismissing or moving displays cannot erase them.
// Doc: Documentation - Sidekick - Notch Window & Visual.md
import SwiftUI

struct SidekickRecoveryView: View {
    @Bindable var recovery: SidekickRecovery
    let question: SidekickQuestion
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = question.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Sidekick needs your help", systemImage: "exclamationmark.circle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.58))
                            ScrollView {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 64)
                            .accessibilityLabel("Complete error")
                        }
                    }
                    Text(question.question)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(question.answers.indices, id: \.self) { index in
                            Button { recovery.answer(id: question.id, choice: index) } label: {
                                Text(question.answers[index])
                                    .font(.system(size: 12, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                    .padding(8)
                                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.16)))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            HStack(spacing: 12) {
                TextField("Tell Sidekick what to do", text: $recovery.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Your guidance")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(recovery.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send guidance")
                .help("Send guidance")
            }
            .padding(8)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .preferredColorScheme(.dark)
    }
    private func send() { recovery.answer(id: question.id) }
}
