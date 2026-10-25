// The optional personal-context invitation lives beside the working Sidekick surface.
// These examples are local presentation only: they never create tasks or claim real results.
import SwiftUI

enum HomePersonalFeature: String, CaseIterable, Identifiable {
    case doubleTap, proactive, knowledge, sidekick
    var id: String { rawValue }

    var title: String {
        switch self {
        case .doubleTap: "Double Tap"
        case .proactive: "Proactive Intelligence"
        case .knowledge: "Knowledge base"
        case .sidekick: "Personal Sidekick"
        }
    }
    var detail: String {
        switch self {
        case .doubleTap: "Replies in your voice, in two taps."
        case .proactive: "Work prepared before you ask."
        case .knowledge: "Your projects, people, and commitments."
        case .sidekick: "Help that already knows your context."
        }
    }
    var symbol: String {
        switch self {
        case .doubleTap: "command"
        case .proactive: "sunrise"
        case .knowledge: "books.vertical"
        case .sidekick: "sparkles"
        }
    }
    var previewTitle: String {
        switch self {
        case .doubleTap: "A reply, already in your voice"
        case .proactive: "Useful work, prepared before you ask."
        case .knowledge: "The details, remembered."
        case .sidekick: "Skip the backstory."
        }
    }
}

struct HomePersonalSetupPanel: View {
    static let width: CGFloat = 360
    let selectedFeature: HomePersonalFeature?
    let emphasizeSetup: Bool
    let active: Bool
    var previewEnabled = true
    let onSelectFeature: (HomePersonalFeature) -> Void
    let onFinishSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Finish Sentient Setup to unlock:")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SidekickStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            ForEach(HomePersonalFeature.allCases) { feature in
                Button { onSelectFeature(feature) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 16).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title).font(.system(size: 14, weight: .medium))
                                .foregroundStyle(SidekickStyle.ink)
                            Text(feature.detail).font(.system(size: 13))
                                .foregroundStyle(SidekickStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: selectedFeature == feature ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium)).padding(.top, 4)
                    }
                    .foregroundStyle(selectedFeature == feature ? SidekickStyle.ink : SidekickStyle.secondary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(selectedFeature == feature ? 0.035 : 0))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!previewEnabled)
                .help(previewEnabled ? "Show an example" : "Examples are available after your current task")
                .accessibilityLabel(feature.title + ". " + feature.detail)
                .accessibilityValue(selectedFeature == feature ? "Example open" : "Example closed")
                .accessibilityHint("Show an example without sending a request")
                .accessibilityIdentifier("personalSetup.feature." + feature.rawValue)
                Rectangle().fill(.white.opacity(0.045)).frame(height: 1)
            }

            // The rewards lead directly to the one setup action.
            Button(action: onFinishSetup) {
                HStack(spacing: 16) {
                    Text("Finish setup").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(SidekickStyle.ink)
                .padding(.horizontal, 17).frame(height: 46)
                .background(Color(white: 0.105), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(emphasizeSetup ? 0.28 : 0.16), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(SidekickPressStyle())
            .background(GlowHalo(active: emphasizeSetup, intensity: 0.27, period: 12, animating: active))
            .padding(.top, 20)
            .accessibilityIdentifier("personalSetup.finish")
            .accessibilityHint("Connect three sources to build your personal context")
        }
        .padding(26)
        .background(Color(white: 0.055), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(.white.opacity(0.095), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personalSetup.panel")
    }
}

struct HomeSidekickInvitation: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sidekick is ready.")
                .font(.system(size: compact ? 30 : 34, weight: .medium))
                .foregroundStyle(SidekickStyle.ink)
            Text("What can I take off your hands?")
                .font(.system(size: compact ? 24 : 27, weight: .regular))
                .foregroundStyle(.white.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidekick.readyInvitation")
    }
}

struct HomeSidekickSuggestions: View {
    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let prompt: String
    }
    static let suggestions = [
        Suggestion(id: "summarize", title: "Summarize a page", symbol: "doc.text",
                   prompt: "Summarize the page I’m looking at. Highlight the key takeaways and any next steps."),
        Suggestion(id: "compare", title: "Compare tools", symbol: "rectangle.split.2x1",
                   prompt: "Help me compare [tool A] and [tool B] for [use case]. Find pricing and the key trade-offs."),
        Suggestion(id: "research", title: "Research a company", symbol: "magnifyingglass",
                   prompt: "Research [company] and give me a concise brief on its product, customers, and competitors."),
        Suggestion(id: "tasks", title: "Turn notes into tasks", symbol: "checklist",
                   prompt: "Turn these notes into a clear task list with priorities: [paste notes]")
    ]
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                ForEach(Self.suggestions) { suggestion in suggestionButton(suggestion).fixedSize(horizontal: true, vertical: false) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                ForEach(Self.suggestions) { suggestion in suggestionButton(suggestion) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Try Sidekick")
    }

    private func suggestionButton(_ suggestion: Suggestion) -> some View {
        Button { onSelect(suggestion.prompt) } label: {
            HStack(spacing: 7) {
                Image(systemName: suggestion.symbol).font(.system(size: 12))
                Text(suggestion.title).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(SidekickStyle.secondary)
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 43)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(SidekickPressStyle())
        .accessibilityIdentifier("sidekick.suggestion." + suggestion.id)
        .accessibilityHint("Fill the message box; review before sending")
    }
}

struct HomePersonalFeaturePreview: View {
    let feature: HomePersonalFeature
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SidekickStyle.secondary)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.055), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close example (Escape)")
                .accessibilityLabel("Close " + feature.title + " example")
                .accessibilityIdentifier("personalSetup.preview.close")
                Text(feature.previewTitle).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SidekickStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("EXAMPLE").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.5).foregroundStyle(SidekickStyle.secondary)
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            ScrollView {
                example.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            Text("Informed by your context. Reviewed by you.")
                .font(.system(size: 10.5)).foregroundStyle(SidekickStyle.secondary)
                .padding(.horizontal, 22).padding(.vertical, 13)
        }
        .background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personalSetup.preview." + feature.rawValue)
    }

    @ViewBuilder private var example: some View {
        switch feature {
        case .doubleTap:
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 10) {
                    Text("A").font(.system(size: 11, weight: .medium))
                        .frame(width: 29, height: 29).background(.white.opacity(0.07), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alex · Northstar").font(.system(size: 11.5, weight: .medium))
                        Text("To you").font(.system(size: 10)).foregroundStyle(SidekickStyle.secondary)
                    }
                }
                Text("How’s the pilot looking? Anything we should cover on tomorrow’s call?")
                    .font(.system(size: 13)).foregroundStyle(SidekickStyle.secondary).lineSpacing(4)
                HStack(alignment: .top, spacing: 13) {
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.3)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Your draft", systemImage: "sparkles").font(.system(size: 11, weight: .medium))
                        Text("Hey Alex, the team’s been using it all week and the feedback’s looking good. Let’s walk through the rollout plan tomorrow; I’ve got a couple of ideas.")
                            .font(.system(size: 13)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(SidekickStyle.ink)
        case .proactive:
            exampleDescription(title: "Your customer brief is ready.",
                               detail: "Pilot feedback, open questions, and a draft follow-up for tomorrow’s call.")
        case .knowledge:
            exampleDescription(title: "Northstar pilot",
                               detail: "Alex owns the pilot. The demo goes out Thursday. Launch is planned for Friday.")
        case .sidekick:
            VStack(alignment: .leading, spacing: 20) {
                Text("“Prep me for the Northstar call.”")
                    .font(.system(size: 14)).foregroundStyle(SidekickStyle.secondary)
                Label {
                    Text("I’ll bring together Alex’s feedback, the pilot notes, and your rollout plan.")
                        .font(.system(size: 15)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles").font(.system(size: 15))
                }
                .foregroundStyle(SidekickStyle.ink)
            }
        }
    }

    private func exampleDescription(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.system(size: 23, weight: .medium)).foregroundStyle(SidekickStyle.ink)
            Text(detail).font(.system(size: 14)).lineSpacing(6).foregroundStyle(SidekickStyle.secondary)
        }
        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
    }
}

#if DEBUG
#Preview("Personal setup reward panel") {
    HomePersonalSetupPanel(selectedFeature: nil, emphasizeSetup: false, active: false,
                           onSelectFeature: { _ in }, onFinishSetup: {})
        .frame(width: HomePersonalSetupPanel.width).padding(30).background(SidekickStyle.base).preferredColorScheme(.dark)
}

#Preview("Personal setup Double Tap example") {
    HomePersonalFeaturePreview(feature: .doubleTap, onClose: {})
        .frame(width: 580, height: 360).padding(30).background(SidekickStyle.base).preferredColorScheme(.dark)
}
#endif
