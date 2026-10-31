// Shared visual treatment for model selection in Settings and onboarding.
// These views render values and actions only; provider selection and sign-in stay with their owners.
import SwiftUI

struct ModelChoiceItem: Identifiable {
    let id: String
    let title: String
    var symbol: String? = nil
    var active = false
}

struct ModelChoiceBar: View {
    let items: [ModelChoiceItem]
    let selection: String
    let onSelect: (String) -> Void
    @State private var hovered: String?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            choices
            ScrollView(.horizontal) { choices }
                .scrollIndicators(.hidden)
        }
    }

    private var choices: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = selection == item.id
                Button { onSelect(item.id) } label: {
                    HStack(spacing: 7) {
                        if let symbol = item.symbol {
                            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                                .accessibilityHidden(true)
                        }
                        if item.active {
                            Circle().fill(selected ? Color(red: 0.10, green: 0.48, blue: 0.24) : Theme.Ink.green)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        Text(item.title).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(selected ? Color.black.opacity(0.88) : Theme.Ink.bright)
                    .padding(.horizontal, 17)
                    .frame(height: 38)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.94))
                                .matchedGeometryEffect(id: "selection", in: highlight)
                                .shadow(color: Theme.accent.opacity(0.18), radius: 12, y: 2)
                        }
                    }
                    .background(hovered == item.id && !selected ? Color.white.opacity(0.06) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .onHover { hovered = $0 ? item.id : nil }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(item.active ? "In use" : "")
            }
        }
        .padding(5)
        .background(Color.white.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: selection)
    }
}

struct ModelSelectionHeading: View {
    var eyebrow: String? = nil
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            if let eyebrow {
                MonoCaps(eyebrow, size: 10, tracking: 2.3, color: Theme.Ink.label)
            }
            Text(title).display(30).foregroundStyle(Theme.Ink.statusInk)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.Ink.body)
                .lineSpacing(4).multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ModelSelectionPanel<Content: View>: View {
    let title: String
    let subtitle: String
    var centered = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 24) {
            VStack(alignment: centered ? .center : .leading, spacing: 10) {
                Text(title).display(25).foregroundStyle(Theme.Ink.statusInk)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.Ink.body)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            content
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .padding(32)
        .frame(maxWidth: .infinity)
        .background { PermissionWindowAtmosphere() }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct ModelConnectionLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            HealthDot(color: Theme.Ink.green)
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Ink.bright)
        }
    }
}
