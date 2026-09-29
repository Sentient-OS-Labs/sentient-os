//  OnboardingDoubleTapSamples.swift
//  The native Mail and Messages fixtures used by the Double Tap lesson, with shared window
//  controls, material, and caret anchors. Replies stay in their compose fields; nothing sends.
//  Doc: Documentation - Onboarding.md (this folder).

import SwiftUI

struct DoubleTapDemoCaretAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Sample content stays together so replacing the story cannot disturb the choreography.
private enum DemoEmail {
    static let sender = "Alex Morgan"
    static let subject = "Quick update before the client call"
    static let message = "Hey, how's the website refresh looking? I have a call with the client this afternoon and want to make sure I'm up to speed."
    static let reply = """
    Hey Alex, we're in good shape. We've finished the new pages and fixed the mobile issues, so we're just waiting on the client's final photos. If those come through tomorrow, we'll be ready to launch on Friday.

    Best,
    John
    """
}

struct DoubleTapDemoEmailWindow: View {
    let replied: Bool
    let waiting: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 6) {
                    DemoTrafficLights()
                    Spacer()
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.23))
                }
                Text("Mail")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.horizontal, 20)
            .frame(height: 42)
            .accessibilityHidden(true)

            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    Text("A")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.055), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.065), lineWidth: 1))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(DemoEmail.sender)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.83))
                        Text("to you")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.33))
                    }
                    Spacer()
                    Text("Just now")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(DemoEmail.subject)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(DemoEmail.message)
                        .font(.system(size: 14))
                        .lineSpacing(6)
                        .foregroundStyle(.white.opacity(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }

                replyField
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(DemoWindowSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample email")
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 10))
                Text("Reply to Alex")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(replied ? "Draft" : "")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.white.opacity(0.32))

            ZStack(alignment: .topLeading) {
                // The final text always participates in layout. The email never grows on paste.
                Text(DemoEmail.reply)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(replied ? 1 : 0)
                    .accessibilityHidden(!replied)

                DemoReplyCaret(replied: replied, waiting: waiting, reduceMotion: reduceMotion)
            }
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        }
        .padding(18)
        .background(.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(replied ? 0.12 : 0.075), lineWidth: 1))
        .accessibilityLabel(replied ? "Your draft reply" : "Empty reply field")
    }
}

private enum DemoMessage {
    static let recipient = "Maya"
    static let incoming = "Yo, want to grab dinner tonight?\nGot a place in mind?"
    static let reply = "Yo sup, let's hit my favorite restaurant in downtown SF. Their kimchi is so good. You down for 7?"
    static let blue = Color(red: 10.0 / 255, green: 132.0 / 255, blue: 1)
}

struct DoubleTapDemoMessageWindow: View {
    let replied: Bool
    let waiting: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    DemoTrafficLights()
                    Spacer()
                    Image(systemName: "video")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                }
                HStack(spacing: 9) {
                    Text("M")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(DemoMessage.recipient)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("iMessage")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 62)
            .background(.white.opacity(0.022))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Messages with Maya")

            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)

            VStack(spacing: 14) {
                Text("Today 5:42 PM")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)

                HStack {
                    Text(DemoMessage.incoming)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 17))
                        .accessibilityLabel("Maya: \(DemoMessage.incoming)")
                    Spacer(minLength: 80)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Spacer(minLength: 20)
            composeField
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(DemoWindowSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample iMessage conversation")
    }

    private var composeField: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.27))
                .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    Text(DemoMessage.reply)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(replied ? 1 : 0)
                        .accessibilityHidden(!replied)

                    Text("iMessage")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.28))
                        .padding(.leading, 5)
                        .opacity(replied ? 0 : 1)
                        .accessibilityHidden(true)

                    DemoReplyCaret(replied: replied, waiting: waiting, reduceMotion: reduceMotion)
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)

                // Decorative only: the lesson drafts into the composer, and never sends.
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(replied ? DemoMessage.blue : .white.opacity(0.14))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.022), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(replied ? 0.18 : 0.12), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(replied ? "Draft reply to Maya" : "Empty iMessage field")
        }
    }
}

private struct DemoReplyCaret: View {
    let replied: Bool
    let waiting: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !waiting || reduceMotion)) { context in
            let pulse = reduceMotion ? 1 : 0.55 + 0.45 * cos(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 1.4)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(replied ? 0 : 0.5 * pulse))
                .frame(width: 1.5, height: 18)
        }
        .anchorPreference(key: DoubleTapDemoCaretAnchor.self, value: .bounds) { $0 }
        .accessibilityHidden(true)
    }
}

/// The Sidekick film's active window controls (RecipeShop.tsx), shared by both native samples.
private struct DemoTrafficLights: View {
    private static let colors: [Color] = [
        Color(red: 1, green: 95.0 / 255, blue: 87.0 / 255),            // #ff5f57
        Color(red: 254.0 / 255, green: 188.0 / 255, blue: 46.0 / 255), // #febc2e
        Color(red: 40.0 / 255, green: 200.0 / 255, blue: 64.0 / 255),  // #28c840
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.colors.indices, id: \.self) { index in
                Circle().fill(Self.colors[index]).frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DemoWindowSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.036, green: 0.037, blue: 0.043))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.19), .white.opacity(0.065)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 32, y: 18)
    }
}
