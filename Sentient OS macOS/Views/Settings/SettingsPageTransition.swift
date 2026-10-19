import SwiftUI

struct SettingsButtonBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct KnowledgeButtonBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

enum HomePageSource { case settings, knowledge }

/// SwiftUI owns reveal/reversal. Retained pages keep one stable content identity even when
/// changing directly between secondary pages; hidden content is inert and accessibility-hidden.
struct HomePageLayer<Content: View>: View {
    let isPresented: Bool
    let animate: Bool
    let source: Anchor<CGRect>?
    var sourceKind: HomePageSource = .settings
    var retainingContent = false
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    private var reducedMotion: Bool { motionOverride ?? systemReducedMotion }

    var body: some View {
        GeometryReader { proxy in
            let origin = SettingsTransitionGeometry.source(source.map { proxy[$0] }, in: proxy.size)
            ZStack {
                if retainingContent {
                    content()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .modifier(reveal(origin: origin, canvas: proxy.size, progress: isPresented ? 1 : 0))
                } else if isPresented {
                    content()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.modifier(active: reveal(origin: origin, canvas: proxy.size, progress: 0),
                                              identity: reveal(origin: origin, canvas: proxy.size, progress: 1)))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(animate ? (reducedMotion ? .easeOut(duration: 0.16)
                : .spring(response: 0.56, dampingFraction: 0.92)) : nil, value: isPresented)
        }
        .allowsHitTesting(isPresented)
        .disabled(!isPresented)
        .accessibilityHidden(!isPresented)
    }

    private func reveal(origin: CGRect?, canvas: CGSize, progress: CGFloat) -> HomePageReveal {
        HomePageReveal(source: origin, canvas: canvas, sourceKind: sourceKind,
                       revealFromSource: animate && !reducedMotion, progress: progress)
    }
}

/// Settings retains its existing insertion/removal lifetime; Knowledge opts into retention.
struct SettingsPageLayer: View {
    let isPresented: Bool
    let animate: Bool
    let source: Anchor<CGRect>?
    var body: some View {
        HomePageLayer(isPresented: isPresented, animate: animate, source: source) { SettingsView() }
    }
}

/// The only delayed entrance work. Cancellation never changes navigation or hidden state.
nonisolated enum HomePageEntrance {
    static func wait(animate: Bool, reducedMotion: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        if animate && !reducedMotion {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return !Task.isCancelled
    }
}

private struct HomePageReveal: AnimatableModifier {
    let source: CGRect?
    let canvas: CGSize
    let sourceKind: HomePageSource
    let revealFromSource: Bool
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let geometry = revealFromSource ? SettingsTransitionGeometry(source: source, canvas: canvas, progress: progress) : nil
        let frame = geometry?.frame ?? CGRect(origin: .zero, size: canvas)
        let anchor = geometry.map { UnitPoint(x: $0.anchor.x, y: $0.anchor.y) } ?? .center
        let radius = geometry?.cornerRadius ?? 0
        // One modifier tree preserves the retained page's state through animated/direct routes.
        content
            .scaleEffect(geometry?.contentScale ?? 1, anchor: anchor)
            .blur(radius: geometry?.contentBlur ?? 0)
            .opacity(geometry?.contentOpacity ?? Double(min(1, max(0, progress))))
            .background(Color(white: 0.04).opacity(geometry == nil ? Double(min(1, max(0, progress))) : 1))
            .mask {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12 * (1 - min(1, max(0, progress)))), lineWidth: 0.75)
                        .opacity(geometry == nil ? 0 : 1)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    sourceSignature
                        .opacity(geometry == nil ? 0 : Double(max(0, 1 - max(0, progress) * 5)))
                        .position(x: source?.midX ?? 0, y: source?.midY ?? 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // At rest a retained page draws nothing, including its black mask/source glyph.
            // During reversal the actual outgoing content remains intact until progress hits0.
            .opacity(progress > 0 ? 1 : 0)
    }

    @ViewBuilder private var sourceSignature: some View {
        switch sourceKind {
        case .settings:
            Image(systemName: "gearshape")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Ink.bright)
        case .knowledge:
            HStack(spacing: 6) {
                Image(systemName: "books.vertical").font(.system(size: 14.5, weight: .semibold))
                Text("Knowledge").font(.system(size: 13.5, weight: .medium))
            }.foregroundStyle(Theme.Ink.bright)
        }
    }
}
