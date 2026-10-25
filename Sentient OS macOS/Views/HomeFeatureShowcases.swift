// Small, interactive product examples. Every interaction changes local presentation only.
// Synthetic content stays out of the conversation, sources, clipboard and task coordinator.
import SwiftUI

struct HomeProactiveShowcase: View {
    let width: CGFloat
    let reducedMotion: Bool
    let onNavigate: () -> Void
    @State private var opened: Example?

    private enum Example: String, CaseIterable, Identifiable {
        case followup, renewal
        var id: String { rawValue }
        var briefing: Briefing {
            switch self {
            case .followup:
                Briefing(id: "setup-example-followup", kind: .promise,
                    kicker: "FOLLOW-UP · DRAFT READY", title: "You promised Alex a rollout plan.",
                    body: "Your pilot notes are now a concise follow-up, with the SSO question included.",
                    offer: "Read the draft")
            case .renewal:
                Briefing(id: "setup-example-renewal", kind: .deadline,
                    kicker: "RENEWS TOMORROW · $149", title: "That analytics trial is about to renew.",
                    body: "Your trial notes say Pulse wasn’t a fit. A cancellation plan is ready to review.",
                    offer: "Review the plan")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let opened {
                ShowcaseBackButton(title: "Back to your cards", identifier: "personalSetup.proactive.back") {
                    change { self.opened = nil }
                }
                detail(opened)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("personalSetup.proactive.detail." + opened.rawValue)
                    .transition(.opacity)
            } else {
                HStack {
                    Label("Prepared overnight", systemImage: "sunrise")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                    Spacer()
                    MonoCaps("2 READY", size: 8.5, tracking: 1.5, color: Theme.faint)
                }
                let columns = width >= 494 ? 2 : 1
                let cardWidth = (width - CGFloat(columns - 1) * 14) / CGFloat(columns)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), alignment: .top), count: columns),
                          alignment: .leading, spacing: 14) {
                    ForEach(Example.allCases) { example in
                        BriefingCard(briefing: example.briefing, phase: .offer,
                                     onOffer: { change { opened = example } },
                                     onDetail: { change { opened = example } }, onOpenEnvelope: {},
                                     cardWidth: cardWidth, previewBodyLines: 4, previewTitleLines: 3)
                    }
                }
                Text("Sentient prepares the work. You decide what happens next.")
                    .font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func detail(_ example: Example) -> some View {
        let accent = example.briefing.accent
        VStack(alignment: .leading, spacing: 16) {
            MonoCaps(example == .followup ? "DRAFT FOLLOW-UP" : "CANCELLATION PLAN",
                     size: 9, tracking: 1.8, color: accent)
            Text(example == .followup ? "Northstar: next steps" : "Before Pulse renews")
                .font(.system(size: 25, design: .serif)).foregroundStyle(SidekickStyle.ink)
            if example == .followup {
                VStack(alignment: .leading, spacing: 12) {
                    Label("To Alex Chen", systemImage: "envelope")
                        .font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
                    Text("Hey Alex,\n\nHere’s the rollout plan: security review Thursday, then the wider team on Friday. I’ll send the SSO checklist ahead of the review.\n\nCould you confirm who should join from your side?")
                        .font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(SidekickStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .showcasePaper(accent: accent)
                ShowcaseSources(first: "Alex’s email", firstSymbol: "envelope", second: "Pilot notes", secondSymbol: "doc.text")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$149").font(.system(size: 30, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                    Text("/ month, starting tomorrow").font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ShowcaseStep(number: "1", title: "Confirm the workspace", detail: "Check the plan and renewal date in billing.")
                    ShowcaseStep(number: "2", title: "Cancel the renewal", detail: "Keep access until the trial ends.")
                    ShowcaseStep(number: "3", title: "Save the confirmation", detail: "Bring the result back for you to review.")
                }.showcasePaper(accent: accent)
                ShowcaseSources(first: "Billing email", firstSymbol: "envelope", second: "Trial notes", secondSymbol: "doc.text")
            }
            Label("Nothing is sent or changed without your approval.", systemImage: "hand.raised")
                .font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func change(_ update: () -> Void) {
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) {
            update()
            onNavigate()
        }
    }
}

struct HomeDoubleTapShowcase: View {
    let reducedMotion: Bool
    let compact: Bool
    @State private var replay = 0
    @State private var draftVisible = true
    @State private var pressedKey = 0
    @State private var replaying = false
    private let draft = "Hey Alex, yes, let’s expand the pilot. I’ll send the SSO checklist before Thursday’s review; we’re still on track for Friday."

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(spacing: 10) {
                Text("A").font(.system(size: 12, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                    .frame(width: 34, height: 34).background(.white.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Alex Chen").font(.system(size: 12, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                    Text("Northstar · To you").font(.system(size: 10.5)).foregroundStyle(SidekickStyle.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    if reducedMotion { draftVisible.toggle() }
                    else { replaying = true; replay &+= 1 }
                } label: {
                    Label(reducedMotion ? (draftVisible ? "Hide draft" : "Show draft") : "Replay", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(SidekickPressStyle()).foregroundStyle(SidekickStyle.ink).disabled(replaying)
                .accessibilityIdentifier("personalSetup.doubleTap.replay")
            }
            VStack(alignment: .leading, spacing: 10) {
                if !compact {
                    Text("Northstar rollout").font(.system(size: 22, design: .serif)).foregroundStyle(SidekickStyle.ink)
                }
                Text("Can we expand the pilot? What do you need from us before the rollout?")
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(SidekickStyle.secondary)
            }
            VStack(alignment: .leading, spacing: compact ? 10 : 13) {
                HStack {
                    Label("Your reply", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(SidekickStyle.secondary)
                    Spacer()
                    HStack(spacing: 5) {
                        keycap(1)
                        keycap(2)
                    }.accessibilityLabel("Two taps of " + ShortcutPreferences.current.spokenLabel)
                }
                ZStack(alignment: .topLeading) {
                    // Reserve the finished reply's space so replay animates words, not layout.
                    Text(draft).hidden().accessibilityHidden(true)
                    if draftVisible {
                        Text(draft).foregroundStyle(SidekickStyle.ink)
                            .accessibilityIdentifier("personalSetup.doubleTap.draft")
                    } else {
                        Text("Your reply…").foregroundStyle(SidekickStyle.secondary.opacity(0.6))
                    }
                }
                .font(.system(size: compact ? 13 : 13.5)).lineSpacing(compact ? 4 : 5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: compact ? 0 : 66, alignment: .topLeading)
                .transition(.opacity)
                if !compact {
                    Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                    ShowcaseSources(first: "Pilot notes", firstSymbol: "doc.text", second: "Thursday review", secondSymbol: "calendar")
                }
            }
            .showcasePaper(padding: compact ? 12 : 18)
            if !compact {
                Text("Your voice, with the details you didn’t have to type.")
                    .font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
            }
        }
        .task(id: replay) {
            guard replay > 0, !reducedMotion else { return }
            defer { replaying = false; pressedKey = 0 }
            do {
                withAnimation(.easeOut(duration: 0.12)) { draftVisible = false; pressedKey = 1 }
                try await Task.sleep(for: .milliseconds(140))
                pressedKey = 0
                try await Task.sleep(for: .milliseconds(100))
                pressedKey = 2
                try await Task.sleep(for: .milliseconds(160))
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.25)) { draftVisible = true }
            } catch { }
        }
    }

    private func keycap(_ index: Int) -> some View {
        Text(ShortcutPreferences.current.label).font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(pressedKey == index ? 1 : 0.55))
            .padding(.horizontal, 7).frame(height: 24)
            .background(.white.opacity(pressedKey == index ? 0.18 : 0.045), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.13)))
            .offset(y: pressedKey == index ? 1 : 0)
    }
}

struct HomeKnowledgeShowcase: View {
    let reducedMotion: Bool
    let compact: Bool
    @State private var selected: Note = .project

    private enum Note: String, CaseIterable, Identifiable {
        case project, person, commitment
        var id: String { rawValue }
        var title: String {
            switch self {
            case .project: "Northstar pilot"
            case .person: "Alex Chen"
            case .commitment: "Friday rollout"
            }
        }
        var kind: String {
            switch self { case .project: "PROJECT"; case .person: "PERSON"; case .commitment: "COMMITMENT" }
        }
        var detail: String {
            switch self {
            case .project: "Northstar wants to expand from 20 to 80 seats. SSO is the last blocker before the wider rollout."
            case .person: "Alex owns the pilot and coordinates Northstar’s security review. He wants a clear rollout plan for the wider team."
            case .commitment: "Send Alex the SSO checklist before Thursday’s security review. The wider team is scheduled to start Friday."
            }
        }
        var point: UnitPoint {
            switch self {
            case .project: UnitPoint(x: 0.24, y: 0.5)
            case .person: UnitPoint(x: 0.74, y: 0.22)
            case .commitment: UnitPoint(x: 0.74, y: 0.79)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            GeometryReader { geometry in
                Canvas { context, size in
                    for note in [Note.person, .commitment] {
                        var path = Path()
                        path.move(to: point(.project, in: size))
                        path.addLine(to: point(note, in: size))
                        context.stroke(path, with: .color(Theme.knowledgeAccent.opacity(selected == note || selected == .project ? 0.48 : 0.16)), lineWidth: 1)
                    }
                }
                .accessibilityHidden(true)
                ForEach(Note.allCases) { note in
                    Button {
                        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) { selected = note }
                    } label: {
                        VStack(spacing: 8) {
                            Circle().fill(selected == note ? .white : Theme.knowledgeAccent.opacity(0.8))
                                .frame(width: 8, height: 8)
                                .padding(7)
                                .background(Circle().fill(Color(white: 0.045)))
                                .overlay(Circle().strokeBorder(Theme.knowledgeAccent.opacity(selected == note ? 0.8 : 0.18)))
                            Text(note.title).font(.system(size: 13, design: .serif))
                                .foregroundStyle(selected == note ? SidekickStyle.ink : SidekickStyle.secondary)
                        }
                        .frame(width: min(142, geometry.size.width * 0.47), height: 49)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: note.point.x * geometry.size.width, y: note.point.y * geometry.size.height)
                    .accessibilityIdentifier("personalSetup.knowledge." + note.rawValue)
                    .accessibilityAddTraits(selected == note ? .isSelected : [])
                }
            }
            .frame(height: compact ? 96 : 160)
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if !compact { MonoCaps(selected.kind, size: 8.5, tracking: 1.8, color: Theme.knowledgeAccent) }
                Text(selected.title).font(.system(size: compact ? 20 : 24, design: .serif)).foregroundStyle(SidekickStyle.ink)
                Text(selected.detail).font(.system(size: compact ? 13 : 13.5)).lineSpacing(compact ? 3 : 5)
                    .foregroundStyle(SidekickStyle.secondary).fixedSize(horizontal: false, vertical: true)
                if !compact {
                    ShowcaseSources(first: "Alex’s email", firstSymbol: "envelope", second: "Pilot notes", secondSymbol: "doc.text")
                }
            }
            .showcasePaper(accent: Theme.knowledgeAccent, padding: compact ? 12 : 18)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("personalSetup.knowledge.note." + selected.rawValue)
            if !compact {
                Text("Connected notes you can explore, edit, and use with your AIs.")
                    .font(.system(size: 11.5)).foregroundStyle(SidekickStyle.secondary)
            }
        }
    }

    private func point(_ note: Note, in size: CGSize) -> CGPoint {
        CGPoint(x: note.point.x * size.width, y: note.point.y * size.height - 13.5)
    }
}

struct HomeSidekickShowcase: View {
    let reducedMotion: Bool
    let compact: Bool
    let onNavigate: () -> Void
    @State private var briefOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 20) {
            if briefOpen {
                ShowcaseBackButton(title: "Back to the conversation", identifier: "personalSetup.sidekick.back") {
                    change { briefOpen = false }
                }
                VStack(alignment: .leading, spacing: 17) {
                    MonoCaps("CALL BRIEF", size: 9, tracking: 1.8, color: Theme.faint)
                    Text("Northstar, in three points").font(.system(size: 25, design: .serif)).foregroundStyle(SidekickStyle.ink)
                    ShowcaseStep(number: "1", title: "The team wants to expand", detail: "Alex is ready to grow the pilot from 20 to 80 seats.")
                    ShowcaseStep(number: "2", title: "SSO is the open question", detail: "Confirm the identity provider and who owns the security review.")
                    ShowcaseStep(number: "3", title: "Keep Friday on track", detail: "Send the checklist before Thursday’s review, then confirm the rollout.")
                    ShowcaseSources(first: "Pilot notes", firstSymbol: "doc.text", second: "Alex’s email", secondSymbol: "envelope")
                }
                .showcasePaper()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("personalSetup.sidekick.brief")
            } else {
                Text("Prep me for tomorrow’s Northstar call.")
                    .font(.system(size: 13)).foregroundStyle(SidekickStyle.ink)
                    .padding(.horizontal, 15).padding(.vertical, compact ? 9 : 12)
                    .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                    HStack(spacing: 8) {
                        SidekickMark(size: 14, illuminated: false)
                        Text("Sidekick").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SidekickStyle.secondary)
                    }
                    Text("Alex wants to expand the pilot. SSO is the last blocker, and you promised the checklist before Thursday’s review.")
                        .font(.system(size: compact ? 13 : 14)).lineSpacing(compact ? 4 : 5).foregroundStyle(SidekickStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !compact {
                        ShowcaseSources(first: "Pilot notes", firstSymbol: "doc.text", second: "Alex’s email", secondSymbol: "envelope")
                    }
                    Button { change { briefOpen = true } } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "doc.text").font(.system(size: 21, weight: .light))
                                .foregroundStyle(SidekickStyle.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Northstar call brief").font(.system(size: 17, design: .serif)).foregroundStyle(SidekickStyle.ink)
                                Text("3 talking points · Open brief").font(.system(size: 11)).foregroundStyle(SidekickStyle.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(SidekickStyle.secondary)
                        }
                        .padding(compact ? 12 : 17).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(SidekickPressStyle()).accessibilityIdentifier("personalSetup.sidekick.openBrief")
                }
            }
        }
    }

    private func change(_ update: () -> Void) {
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) {
            update()
            onNavigate()
        }
    }
}

private struct ShowcaseSources: View {
    let first: String
    let firstSymbol: String
    let second: String
    let secondSymbol: String
    var body: some View {
        HStack(spacing: 7) {
            source(first, symbol: firstSymbol)
            source(second, symbol: secondSymbol)
        }
    }
    private func source(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 10.5))
            .foregroundStyle(SidekickStyle.secondary).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.white.opacity(0.04), in: Capsule())
    }
}

private struct ShowcaseBackButton: View {
    let title: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "chevron.left").font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SidekickStyle.secondary).padding(.vertical, 4)
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

private struct ShowcaseStep: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(SidekickStyle.secondary).frame(width: 24, height: 24)
                .background(.white.opacity(0.05), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(SidekickStyle.ink)
                Text(detail).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(SidekickStyle.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    func showcasePaper(accent: Color = .white, padding: CGFloat = 18) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(
                LinearGradient(colors: [accent.opacity(0.22), .white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}
