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
}

struct HomePersonalSetupPanel: View {
    static let width: CGFloat = 360
    let selectedFeature: HomePersonalFeature?
    let emphasizeSetup: Bool
    let active: Bool
    var previewEnabled = true
    let onSelectFeature: (HomePersonalFeature) -> Void
    let onFinishSetup: () -> Void
    @State private var hoveredFeature: HomePersonalFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Finish Sentient Setup to unlock:")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SidekickStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            ForEach(HomePersonalFeature.allCases) { feature in
                featureButton(feature)
                Rectangle().fill(.white.opacity(0.045)).frame(height: 1)
            }

            // The rewards lead directly to the one setup action.
            Button(action: onFinishSetup) {
                HStack(spacing: 16) {
                    Text("Finish setup").font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color(white: 0.08))
                .padding(.horizontal, 17).frame(height: 46)
                .background(.white, in: Capsule())
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

    private func featureButton(_ feature: HomePersonalFeature) -> some View {
        let selected = selectedFeature == feature
        let fillOpacity: Double = selected ? 0.045 : (previewEnabled && hoveredFeature == feature ? 0.025 : 0)
        return Button { onSelectFeature(feature) } label: {
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
                Image(systemName: selected ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .medium)).padding(.top, 4)
            }
            .foregroundStyle(selected ? SidekickStyle.ink : SidekickStyle.secondary)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(fillOpacity),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(selected ? 0.08 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        // Outset the button, not its text: every row keeps the same alignment, with
        // a real clickable gutter around the icon and disclosure arrow.
        .padding(.horizontal, -12).padding(.vertical, 3)
        .onHover { hovering in
            if hovering { hoveredFeature = feature }
            else if hoveredFeature == feature { hoveredFeature = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredFeature)
        .animation(.easeOut(duration: 0.12), value: selectedFeature)
        .disabled(!previewEnabled)
        .help(previewEnabled ? "Show an example" : "Examples are available after your current task")
        .accessibilityLabel(feature.title + ". " + feature.detail)
        .accessibilityValue(selected ? "Example open" : "Example closed")
        .accessibilityHint("Show an example without sending a request")
        .accessibilityIdentifier("personalSetup.feature." + feature.rawValue)
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
        Suggestion(id: "subscriptions", title: "Find subscriptions to cancel", symbol: "creditcard",
                   prompt: "Find my recurring subscriptions using billing emails and account pages I can access. Show prices and renewal dates, and ask which I want to cancel. Don't assume a subscription is unused or cancel anything without my approval."),
        Suggestion(id: "followups", title: "Catch missed follow-ups", symbol: "arrowshape.turn.up.left",
                   prompt: "Check my recent email conversations, plus iMessage and WhatsApp if installed and accessible, for up to three follow-ups I owe, including unanswered requests and commitments I made. Explain what needs attention and prepare a draft for each, leaving everything unsent. Ask which inbox or account to use if needed."),
        Suggestion(id: "purchase", title: "Research a purchase", symbol: "magnifyingglass",
                   prompt: "Help me research a purchase. First ask what I'm buying, my budget, and what matters most. Then compare suitable options using current prices, specifications, and owner reviews. Give me a short recommendation with sources and total delivered prices where available."),
        Suggestion(id: "meeting", title: "Prep my next meeting", symbol: "calendar.badge.clock",
                   prompt: "Get me ready for my next meeting. Find it in my calendar, check the relevant recent conversation and linked documents, and open the materials I'll need. Prepare a private brief with key decisions, outstanding commitments, and questions to ask. Ask for any missing access or meeting details."),
        Suggestion(id: "trip", title: "Plan my trip", symbol: "airplane",
                   prompt: "Help me plan a trip. First ask where and when I'm going, my departure city, budget, and preferences. Compare travel and accommodation options with current prices and build a practical itinerary with booking links. Don't book or pay for anything without my approval."),
        Suggestion(id: "catchup", title: "Catch me up", symbol: "text.bubble",
                   prompt: "Catch me up on what needs my attention. First ask which inbox or project to check and how far back to look. Then review the available recent conversations and calendar items, summarize important changes and deadlines with links, and suggest the next actions. Leave messages and calendar events unchanged.")
    ]
    static let initialSuggestions = Array(suggestions.prefix(4))
    // These are draft starters, not tasks. Rotate only after Home accepts the draft.
    let onSelect: (String) -> Bool
    @State private var visible = initialSuggestions
    @State private var queued = Array(suggestions.dropFirst(4))
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reducedMotion: Bool { motionOverride ?? systemReducedMotion }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                ForEach(0..<4) { slot in
                    // Reserve each initial slot's width, so a replacement cannot
                    // move its neighbors or switch between the row and grid.
                    ZStack {
                        suggestionLabel(Self.initialSuggestions[slot])
                            .fixedSize(horizontal: true, vertical: false)
                            .hidden().accessibilityHidden(true)
                    }
                    .overlay { suggestionButton(at: slot) }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                ForEach(0..<4) { slot in suggestionButton(at: slot) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Try Sidekick")
    }

    private func suggestionLabel(_ suggestion: Suggestion) -> some View {
        HStack(spacing: 7) {
            Image(systemName: suggestion.symbol).font(.system(size: 12))
            Text(suggestion.title).font(.system(size: 11)).lineLimit(2)
        }
        .foregroundStyle(SidekickStyle.secondary)
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 43, maxHeight: 43)
    }

    private func suggestionButton(at slot: Int) -> some View {
        let suggestion = visible[slot]
        return ZStack {
            Button {
                // An outgoing button can briefly coexist with its replacement during
                // the transition. Ignore a stale click instead of rotating twice.
                guard visible[slot].id == suggestion.id, onSelect(suggestion.prompt) else { return }
                withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) {
                    visible[slot] = queued.removeFirst()
                    queued.append(suggestion)
                }
            } label: {
                suggestionLabel(suggestion)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.07), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(SidekickPressStyle())
            .accessibilityIdentifier("sidekick.suggestion." + suggestion.id)
            .accessibilityHint("Fill the message box; review before sending")
            .id(suggestion.id)
            .transition(reducedMotion ? .identity : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 5)),
                removal: .opacity.combined(with: .offset(y: -5))))
        }
        .frame(height: 43)
        .clipped()
    }
}

struct HomePersonalFeaturePreview: View {
    let feature: HomePersonalFeature
    let onClose: () -> Void
    var isActive = true
    var availableHeight: CGFloat = 520
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    @State private var pageRevision = 0
    private var reducedMotion: Bool { motionOverride ?? systemReducedMotion }

    var body: some View {
        GeometryReader { geometry in
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
                Text(feature.title).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SidekickStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("EXAMPLE").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.5).foregroundStyle(SidekickStyle.secondary)
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    example(width: max(1, geometry.size.width - 40))
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            onContentHeightChange($0 + 55) // fixed close/title row and hairline
                        }
                        .id("showcase-top")
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: pageRevision) { _, _ in
                    proxy.scrollTo("showcase-top", anchor: .top)
                }
            }
        }
        }
        .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("personalSetup.preview." + feature.rawValue)
    }

    @ViewBuilder private func example(width: CGFloat) -> some View {
        switch feature {
        case .doubleTap:
            HomeDoubleTapShowcase(reducedMotion: reducedMotion, compact: width < 430)
        case .proactive:
            HomeProactiveShowcase(width: width, reducedMotion: reducedMotion, onNavigate: { pageRevision &+= 1 })
        case .knowledge:
            HomeKnowledgeShowcase(reducedMotion: reducedMotion, compact: width < 430, isActive: isActive,
                                  availableHeight: max(0, availableHeight - 95),
                                  onNavigate: { pageRevision &+= 1 }, onClose: onClose)
        case .sidekick:
            HomeSidekickShowcase(reducedMotion: reducedMotion, compact: width < 430, onNavigate: { pageRevision &+= 1 })
        }
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
