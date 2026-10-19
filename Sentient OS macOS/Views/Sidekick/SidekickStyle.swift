import SwiftUI
import AppKit

extension EnvironmentValues {
    // Optional overrides are used by the isolated rendering lab; production follows macOS.
    @Entry var sidekickReduceMotionOverride: Bool? = nil
    @Entry var sidekickReduceTransparencyOverride: Bool? = nil
    @Entry var sidekickHoveredMessageID: String? = nil
    @Entry var sidekickHoveredCardID: String? = nil
}

/// Sentient's existing identity: black, neutral glass, precise white ink. The spectrum is
/// a localized light source at an edge or mark, never a colored reading surface.
enum SidekickStyle {
    static let ink = Color(white: 0.93)
    static let secondary = Color(white: 0.53)
    static let accent = Color(white: 0.84)
    static let base = Color.black
    static func motion(_ reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.16) : .spring(response: 0.54, dampingFraction: 0.86)
    }
    static func entrance(_ reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .modifier(
            active: SoftReveal(opacity: 0, scale: 0.97, blur: 7, y: 14),
            identity: SoftReveal(opacity: 1, scale: 1, blur: 0, y: 0))
    }
    private struct SoftReveal: ViewModifier {
        let opacity: Double, scale: CGFloat, blur: CGFloat, y: CGFloat
        func body(content: Content) -> some View {
            content.opacity(opacity).scaleEffect(scale, anchor: .bottom).blur(radius: blur).offset(y: y)
        }
    }
}

struct SidekickGlass: ViewModifier {
    var radius: CGFloat = 18
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque
    @Environment(\.sidekickReduceTransparencyOverride) private var opacityOverride
    @Environment(\.colorSchemeContrast) private var contrast
    private var opaque: Bool { opacityOverride ?? systemOpaque }
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if !opaque, prominent, #available(macOS 26.0, *) {
                // Use the system material on the complete control so its lens, specular edge,
                // and interaction response remain native. No opaque tint hides the light.
                content.glassEffect(.regular.interactive(), in: shape)
                    .overlay {
                        if contrast == .increased { shape.strokeBorder(.white.opacity(0.5), lineWidth: 1) }
                    }
            } else {
                content.background {
                    if opaque { shape.fill(Color(white: 0.065)) }
                    else { shape.fill(.ultraThinMaterial).overlay(shape.fill(.black.opacity(0.70))) }
                }
                .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.5 : (prominent ? 0.18 : 0.09)), lineWidth: 0.75))
            }
        }.environment(\.colorScheme, .dark)
    }
}

extension View {
    func sidekickGlass(radius: CGFloat = 18, prominent: Bool = false) -> some View {
        modifier(SidekickGlass(radius: radius, prominent: prominent))
    }
}

struct SidekickGlassGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) { content }
        } else { content }
    }
}

/// A small, static expression of the same mark used on the website and in the notch.
struct SidekickMark: View {
    var size: CGFloat = 16
    var illuminated = false
    var body: some View {
        ZStack {
            if illuminated {
                Circle().fill(AngularGradient(colors: GlowHalo.stops, center: .center))
                    .frame(width: size * 1.25, height: size * 1.25)
                    .blur(radius: size * 0.45).opacity(0.48)
                    .padding(size).drawingGroup().allowsHitTesting(false)
            }
            OrbMark(size: size)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct SidekickAtmosphere: View {
    var focused: Bool
    var sendPulse: Int
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var motionTime = 0.0
    @State private var motionAnchor: Date?
    private var reduced: Bool { motionOverride ?? systemReduced }
    private var motionEnabled: Bool { active && !reduced && !lowPower }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // One clock drives only compositor transforms on cached light shapes.
                // No text/layout state changes per frame; hidden/reading/low-power stops it.
                TimelineView(.animation(minimumInterval: 1.0 / 18, paused: !motionEnabled)) { context in
                    let t = motionTime + (motionAnchor.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
                    lights(in: geo.size, time: t)
                }
                Image(nsImage: Self.grain).resizable(resizingMode: .tile).opacity(0.16)
                if !reduced && active && !lowPower {
                    Ellipse().stroke(.white.opacity(0.065), lineWidth: 1)
                        .frame(width: min(720, geo.size.width * 0.58), height: 32)
                        .blur(radius: 8)
                        .keyframeAnimator(initialValue: 1.0, trigger: sendPulse) { content, progress in
                            content.scaleEffect(0.7 + progress * 1.6)
                                .opacity(sin(progress * .pi) * 0.65)
                                .offset(y: geo.size.height * 0.46 - progress * 38)
                        } keyframes: { _ in
                            MoveKeyframe(0)
                            CubicKeyframe(1, duration: 1.1)
                        }
                }
            }.clipped()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: motionEnabled, initial: true) { _, enabled in
            let now = Date()
            if enabled { motionAnchor = now }
            else if let anchor = motionAnchor {
                motionTime += max(0, now.timeIntervalSince(anchor)); motionAnchor = nil
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }

    private func lights(in size: CGSize, time t: Double) -> some View {
        ZStack {
            // A clearly visible crown of Sentient light, with black space beneath it.
            // Solid-color, blurred shapes drift and turn; no full-window gradient fill.
            LightShape(color: GlowHalo.stops[6], width: min(440, size.width * 0.42), height: 280, blur: 66)
                .rotationEffect(.degrees(-20 + sin(t * 0.24) * 22))
                .scaleEffect(1 + sin(t * 0.31) * 0.12)
                .position(x: size.width * 0.10 + sin(t * 0.27) * min(125, size.width * 0.13), y: -36 + cos(t * 0.29) * 32)
                .opacity(0.35 + sin(t * 0.32 + 0.7) * 0.055)
            LightShape(color: GlowHalo.stops[2], width: min(490, size.width * 0.46), height: 275, blur: 64)
                .rotationEffect(.degrees(17 + sin(t * 0.21 + 1) * 20))
                .scaleEffect(1 + cos(t * 0.29) * 0.13)
                .position(x: size.width * 0.43 + sin(t * 0.23 + 1.6) * min(145, size.width * 0.14), y: -48 + cos(t * 0.26 + 1) * 35)
                .opacity(0.32 + sin(t * 0.28 + 2) * 0.065)
            LightShape(color: GlowHalo.stops[0], width: min(590, size.width * 0.55), height: 290, blur: 69)
                .rotationEffect(.degrees(-14 + sin(t * 0.22 + 2) * 18))
                .scaleEffect(1 + sin(t * 0.27 + 1) * 0.11)
                .position(x: size.width * 0.78 + sin(t * 0.25 + 3.2) * min(155, size.width * 0.14), y: -38 + sin(t * 0.24 + 1) * 38)
                .opacity(0.42 + sin(t * 0.30 + 3) * 0.06)
            LightShape(color: GlowHalo.stops[1], width: 245, height: 280, blur: 61)
                .rotationEffect(.degrees(24 + sin(t * 0.23) * 20))
                .position(x: size.width + 24 + cos(t * 0.26) * 48, y: 88 + sin(t * 0.28 + 2) * 42)
                .opacity(0.24 + cos(t * 0.25) * 0.04)
            // A smaller echo lets the composer's real glass catch a little warm light.
            LightShape(color: GlowHalo.stops[0], width: 285, height: 160, blur: 42)
                .rotationEffect(.degrees(-17 + sin(t * 0.061) * 8))
                .position(x: size.width * 0.77 + sin(t * 0.069) * 21, y: size.height + 72 + sin(t * 0.077) * 12)
                .opacity(focused ? 0.34 : 0.19)
        }.animation(.easeInOut(duration: 0.65), value: focused)
    }

    private struct LightShape: View {
        let color: Color
        let width: CGFloat, height: CGFloat, blur: CGFloat
        var body: some View {
            LightPetal().fill(color).frame(width: width, height: height)
                .blur(radius: blur).padding(blur * 2).drawingGroup()
        }
    }
    private struct LightPetal: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.width * 0.05, y: r.height * 0.57))
            p.addCurve(to: CGPoint(x: r.width * 0.57, y: r.height * 0.04),
                control1: CGPoint(x: r.width * 0.08, y: r.height * 0.18),
                control2: CGPoint(x: r.width * 0.24, y: -r.height * 0.07))
            p.addCurve(to: CGPoint(x: r.width * 0.95, y: r.height * 0.55),
                control1: CGPoint(x: r.width * 0.96, y: r.height * 0.14),
                control2: CGPoint(x: r.width, y: r.height * 0.32))
            p.addCurve(to: CGPoint(x: r.width * 0.42, y: r.height * 0.96),
                control1: CGPoint(x: r.width * 0.9, y: r.height * 0.87),
                control2: CGPoint(x: r.width * 0.64, y: r.height * 0.98))
            p.addCurve(to: CGPoint(x: r.width * 0.05, y: r.height * 0.57),
                control1: CGPoint(x: r.width * 0.12, y: r.height * 0.94),
                control2: CGPoint(x: 0, y: r.height * 0.78))
            p.closeSubpath(); return p
        }
    }
    // Cached neutral grain adds texture without a particle system or random redraws.
    private static let grain: NSImage = {
        let width = 128, height = 128
        var seed: UInt32 = 0x53454E54
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let value = UInt8(seed % 38)
            bytes[pixel * 4] = value; bytes[pixel * 4 + 1] = value; bytes[pixel * 4 + 2] = value
            bytes[pixel * 4 + 3] = 255
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }()
}

/// Tracks the real native window, so hidden/occluded Home never consumes unread messages.
struct SidekickWindowPresence: NSViewRepresentable {
    var requiresKeyWindow = false
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe(requiresKeyWindow: requiresKeyWindow, changed: changed) }
    func updateNSView(_ view: Probe, context: Context) {
        view.requiresKeyWindow = requiresKeyWindow; view.changed = changed; view.publish()
    }
    final class Probe: NSView {
        var requiresKeyWindow: Bool
        var changed: (Bool) -> Void
        private var tokens: [NSObjectProtocol] = []
        private var last: Bool?
        init(requiresKeyWindow: Bool, changed: @escaping (Bool) -> Void) {
            self.requiresKeyWindow = requiresKeyWindow; self.changed = changed; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification,
                NSApplication.didResignActiveNotification]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publish() }
                })
            }
            publish()
        }
        func publish() {
            let value = window.map { NSApp.isActive && $0.isVisible && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible) && (!requiresKeyWindow || $0.isKeyWindow) } ?? false
            guard value != last else { return }; last = value
            DispatchQueue.main.async { [weak self] in self?.changed(value) }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// A quiet sweep across a live status label. Only the highlight draws at frame cadence;
/// transcript layout and text stay still. Hidden, waiting and reduced-motion states are static.
struct SidekickWorkingText: View {
    let text: String
    var shimmering: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var animate: Bool { shimmering && !(motionOverride ?? systemReducedMotion) && !lowPower }

    var body: some View {
        Text(text)
            .overlay {
                if animate {
                    GeometryReader { geometry in
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                            let width = max(36, geometry.size.width * 0.45)
                            LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: width, height: geometry.size.height)
                                .offset(x: -width + (geometry.size.width + width) * phase * 1.55)
                        }
                    }
                    .mask(Text(text).foregroundStyle(.white))
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

/// Shared geometry and feedback for the conversation toolbar's search and clear actions.
struct SidekickToolbarIconButton: View {
    let symbol: String
    var busy = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol) }
            }
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 40, height: 40)
            .foregroundStyle(hovering ? .white : Theme.Ink.bright)
            .background(Capsule().fill(.white.opacity(hovering ? 0.07 : 0.035)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidekickPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.sidekickReduceMotionOverride) private var motionOverride
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((motionOverride ?? systemReduced) || !configuration.isPressed ? 1 : 0.975)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
