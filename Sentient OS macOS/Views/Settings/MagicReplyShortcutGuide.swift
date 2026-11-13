import CoreText
import SwiftUI

/// A keyboard and instruction teach the optional Settings shortcut.
struct MagicReplyShortcutGuide: View {
    let key: ShortcutKey

    static let instructionFont: Font = {
        guard let url = Bundle.main.url(forResource: "InstrumentSerif-Regular", withExtension: "ttf"),
              let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider) else {
            Log("Onboarding: could not load bundled Instrument Serif")
            return .system(size: 30, weight: .regular, design: .serif)
        }
        return Font(CTFontCreateWithGraphicsFont(font, 30, nil, nil))
    }()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsKeyboard: Bool { key == .rightCommand || key == .rightOption }

    var body: some View {
        VStack(spacing: 12) {
            Text(showsKeyboard ? "Double tap your \(key.spokenLabel) key" : "Double tap your Sentient key")
            .font(Self.instructionFont)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if showsKeyboard {
                GeometryReader { geometry in
                    OnboardingDoubleTapKeyboard(pressed: false, inviting: true,
                        reduceMotion: reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled,
                        key: key, action: {})
                        .scaleEffect(geometry.size.width / 760, anchor: .topLeading)
                }
                .aspectRatio(760.0 / 200, contentMode: .fit)
                .frame(maxWidth: 600)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            Text("Start with a reply box focused in a message or email.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 152)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("magicReply.shortcutGuide")
    }
}

#Preview("Magic Reply shortcut") {
    VStack(spacing: 24) {
        MagicReplyShortcutGuide(key: .rightCommand)
        MagicReplyShortcutGuide(key: .rightOption)
        MagicReplyShortcutGuide(key: .leftControl)
    }
    .frame(width: 640)
    .padding(32)
    .background(.black)
    .preferredColorScheme(.dark)
}
