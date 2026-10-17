// The expanded notch shows an error or a clarification with two answers, plus editable guidance.
// Draft and timing live in SidekickRecovery, so dismissing or moving displays cannot erase them.
// Doc: Documentation - Sidekick - Notch Window & Visual.md
import SwiftUI
import AppKit

/// The same content measurement drives the shell, scroll viewport, and mouse hit area.
/// Short questions take only the space they need; overflow keeps the steering field visible.
struct SidekickRecoveryLayout {
    static let questionFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let answerFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let errorFont = NSFont.systemFont(ofSize: 12)
    static let errorLineHeight = NSLayoutManager().defaultLineHeight(for: errorFont)
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let labelHeight: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
    static let answerSpacing: CGFloat = 8
    static let answerPadding: CGFloat = 8
    static let scrollHPad: CGFloat = 2
    static let scrollVPad: CGFloat = 4
    static let errorVPad: CGFloat = 4
    static let fieldSpacing: CGFloat = 8
    static let fieldHeight: CGFloat = 40
    static let topPad: CGFloat = 4
    static let bottomPad: CGFloat = 8

    let size: CGSize
    let scrollHeight: CGFloat
    let errorHeight: CGFloat
    let answerWidth: CGFloat

    init(content: SidekickRecoveryContent, metrics: NotchMetrics) {
        let maximum = metrics.size(for: .recovery)
        let textWidth = maximum.width - 2 * (metrics.hPad + Self.scrollHPad)
        let buttonWidth = (textWidth - Self.answerSpacing) / 2
        answerWidth = buttonWidth
        let questionHeight = content.question.map { Self.height($0.question, font: Self.questionFont, width: textWidth) } ?? 0
        let answersHeight = (content.question?.answers ?? []).map {
            max(18, Self.height($0, font: Self.answerFont, width: buttonWidth - 2 * Self.answerPadding))
                + 2 * Self.answerPadding
        }.max() ?? 0
        let chromeHeight = metrics.topRowHeight + metrics.topPad + metrics.bottomPad
            + Self.topPad + Self.bottomPad + Self.fieldSpacing + Self.fieldHeight
        let availableScrollHeight = max(0, maximum.height - chromeHeight)
        let questionAndAnswersHeight = questionHeight + answersHeight + 2 * Self.scrollVPad
            + (content.question == nil ? 0 : Self.sectionSpacing)
        let errorChrome = Self.labelHeight + 6 + (content.question == nil ? 0 : Self.sectionSpacing)
        // Give the question and answers room first. A long error can scroll in the remaining
        // space; long questions/answers still scroll as a group above the fixed input.
        errorHeight = content.error.map {
            let lineHeight = Self.errorLineHeight
            let available = min(content.question == nil ? availableScrollHeight : 64, max(lineHeight + 2 * Self.errorVPad,
                                       availableScrollHeight - questionAndAnswersHeight - errorChrome))
            let lines = max(1, floor((available - 2 * Self.errorVPad) / lineHeight))
            // Whole lines and an inset keep the first/last lines clear of the scroll edges.
            return min(Self.height($0, font: Self.errorFont, width: textWidth), lines * lineHeight)
                + 2 * Self.errorVPad
        } ?? 0
        let contentHeight = questionAndAnswersHeight + (content.error == nil ? 0 : errorChrome + errorHeight)
        scrollHeight = min(contentHeight, availableScrollHeight)
        size = CGSize(width: maximum.width, height: chromeHeight + scrollHeight)
    }

    private static func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height)
    }
}

struct SidekickRecoveryView: View {
    @Bindable var recovery: SidekickRecovery
    let content: SidekickRecoveryContent
    let layout: SidekickRecoveryLayout
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }

    private var canSend: Bool { !recovery.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: SidekickRecoveryLayout.fieldSpacing) {
            ScrollView {
                VStack(alignment: .leading, spacing: SidekickRecoveryLayout.sectionSpacing) {
                    if let error = content.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(content.question == nil ? "Couldn’t finish this" : "One thing to resolve",
                                  systemImage: content.question == nil ? "exclamationmark.circle" : "bubble.left.and.bubble.right")
                                .font(Font(SidekickRecoveryLayout.labelFont))
                                .frame(height: SidekickRecoveryLayout.labelHeight, alignment: .leading)
                                .foregroundStyle(.white.opacity(0.78))
                            ScrollView {
                                Text(error)
                                    .font(Font(SidekickRecoveryLayout.errorFont))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, SidekickRecoveryLayout.errorVPad)
                            }
                            .scrollIndicators(.hidden)
                            .frame(height: layout.errorHeight)
                            .mask { scrollEdges }
                            .accessibilityLabel("Complete error")
                        }
                    }
                    if let question = content.question {
                        Text(question.question)
                            .font(Font(SidekickRecoveryLayout.questionFont))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        HStack(alignment: .top, spacing: SidekickRecoveryLayout.answerSpacing) {
                            ForEach(question.answers.indices, id: \.self) { index in
                                Button { recovery.answer(id: question.id, choice: index) } label: {
                                    Text(question.answers[index])
                                        .font(Font(SidekickRecoveryLayout.answerFont))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                        .padding(SidekickRecoveryLayout.answerPadding)
                                        .frame(width: layout.answerWidth, alignment: .leading)
                                }
                                .buttonStyle(NotchRecoveryChoiceStyle())
                                .foregroundStyle(.white)
                                .accessibilityHint("Answer Sidekick and continue this task")
                            }
                        }
                    }
                }
                .padding(.vertical, SidekickRecoveryLayout.scrollVPad)
                .padding(.horizontal, SidekickRecoveryLayout.scrollHPad)
            }
            .scrollIndicators(.hidden)
            .frame(height: layout.scrollHeight)
            .mask { scrollEdges }
            HStack(spacing: 12) {
                TextField(content.question == nil ? "Add a detail, or try again" : "Or type your answer", text: $recovery.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($fieldFocused)
                    .onSubmit(send)
                    .accessibilityLabel(content.question == nil ? "Guidance for retrying" : "Your answer to Sidekick")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background {
                            Circle().fill(.white.opacity(0.90))
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .accessibilityLabel("Send guidance")
                .accessibilityHint("Send your reply and continue this task")
                .help("Send guidance")
            }
            .padding(8)
            .frame(height: SidekickRecoveryLayout.fieldHeight)
            .background(.white.opacity(fieldFocused ? 0.10 : 0.06), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(.white.opacity(fieldFocused ? 0.34 : 0.11), lineWidth: 0.75)
            }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: fieldFocused)
        }
        .padding(.top, SidekickRecoveryLayout.topPad)
        .padding(.bottom, SidekickRecoveryLayout.bottomPad)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }
    // A soft boundary makes partially scrolled lines recede instead of being sliced against
    // the heading or input. Content padding keeps complete lines outside the fade at either end.
    private var scrollEdges: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
        }
        .allowsHitTesting(false)
    }
    private func send() {
        guard canSend else { return }
        recovery.answer(id: content.id)
    }
}

/// Quiet glass buttons retain their measured layout while pointer/press feedback changes.
private struct NotchRecoveryChoiceStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reduceMotion: Bool { motionOverride ?? systemReduceMotion }
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.11 : 0.065)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(hovering ? 0.25 : 0.15), .white.opacity(0.07)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: hovering)
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: configuration.isPressed)
    }
}
