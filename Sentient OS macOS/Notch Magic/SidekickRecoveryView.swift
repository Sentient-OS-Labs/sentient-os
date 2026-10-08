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

    var body: some View {
        VStack(alignment: .leading, spacing: SidekickRecoveryLayout.fieldSpacing) {
            ScrollView {
                VStack(alignment: .leading, spacing: SidekickRecoveryLayout.sectionSpacing) {
                    if let error = content.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(content.question == nil ? "Sidekick couldn’t finish" : "Sidekick needs your help", systemImage: "exclamationmark.circle")
                                .font(Font(SidekickRecoveryLayout.labelFont))
                                .frame(height: SidekickRecoveryLayout.labelHeight, alignment: .leading)
                                .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.58))
                            ScrollView {
                                Text(error)
                                    .font(Font(SidekickRecoveryLayout.errorFont))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, SidekickRecoveryLayout.errorVPad)
                            }
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
                        HStack(alignment: .top, spacing: SidekickRecoveryLayout.answerSpacing) {
                            ForEach(question.answers.indices, id: \.self) { index in
                                Button { recovery.answer(id: question.id, choice: index) } label: {
                                    Text(question.answers[index])
                                        .font(Font(SidekickRecoveryLayout.answerFont))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                        .padding(SidekickRecoveryLayout.answerPadding)
                                        .frame(width: layout.answerWidth, alignment: .leading)
                                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.16)))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .padding(.vertical, SidekickRecoveryLayout.scrollVPad)
                .padding(.horizontal, SidekickRecoveryLayout.scrollHPad)
            }
            .frame(height: layout.scrollHeight)
            .mask { scrollEdges }
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
            .frame(height: SidekickRecoveryLayout.fieldHeight)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, SidekickRecoveryLayout.topPad)
        .padding(.bottom, SidekickRecoveryLayout.bottomPad)
        .preferredColorScheme(.dark)
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
    private func send() { recovery.answer(id: content.id) }
}
