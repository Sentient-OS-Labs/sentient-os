// Underlit glass for the notch and external island. Alternate treatments and time
// overrides remain available to the isolated rendering lab.
import SwiftUI
import QuartzCore
import Observation


// One display-linked clock per live overlay, consumed only by its color leaves.
// Geometry/masks remain outside these leaves so panel springs do not get restarted.
@MainActor @Observable final class NotchLightingClock {
    var date = Date()

    var currentDate: Date {
        // Observe the shared tick, but sample wall time when a leaf is evaluated.
        // A newly resumed leaf must not render the clock's pre-pause timestamp
        // once before the first display-link callback arrives.
        _ = date
        return Date()
    }
}

extension EnvironmentValues {
    @Entry var notchLightingClock: NotchLightingClock? = nil
}

struct NotchLightingClockHost: ViewModifier {
    let paused: Bool
    @State private var clock = NotchLightingClock()

    func body(content: Content) -> some View {
        content
            .environment(\.notchLightingClock, clock)
            .background(NotchLightingClockDriver(clock: clock, paused: paused).allowsHitTesting(false))
    }
}

/// Paused leaves do not observe clock time, even if a sibling still needs ticks.
struct NotchLightingFrames<Content: View>: View {
    let paused: Bool
    @ViewBuilder var content: (Date) -> Content
    @Environment(\.notchLightingClock) private var clock
    @State private var pausedDate = Date()

    var body: some View {
        Group {
            if let clock {
                content(paused ? pausedDate : clock.currentDate)
            } else {
                // Standalone previews keep working without a live overlay host.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { context in
                    content(context.date)
                }
            }
        }
        .onChange(of: paused) { _, value in
            if value { pausedDate = Date() }
        }
    }
}

private struct NotchLightingClockDriver: NSViewRepresentable {
    let clock: NotchLightingClock
    let paused: Bool

    func makeNSView(context: Context) -> DriverView { DriverView(clock: clock) }
    func updateNSView(_ view: DriverView, context: Context) { view.setPaused(paused) }
    static func dismantleNSView(_ view: DriverView, coordinator: ()) { view.stop() }

    final class TickTarget: NSObject {
        weak var clock: NotchLightingClock?
        init(clock: NotchLightingClock) { self.clock = clock }
        @objc func tick(_ link: CADisplayLink) { clock?.date = Date() }
    }

    final class DriverView: NSView {
        private let target: TickTarget
        private var link: CADisplayLink?
        private var paused = true

        init(clock: NotchLightingClock) {
            target = TickTarget(clock: clock)
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { setPaused(paused) }
        }
        func setPaused(_ value: Bool) {
            paused = value
            guard !paused, window != nil else { stop(); return }
            guard link == nil else { return }
            // NSView's display link follows this window across screens automatically,
            // and suppresses callbacks when the view is hidden/off-display.
            let displayLink = displayLink(target: target, selector: #selector(TickTarget.tick(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }
        func stop() { link?.invalidate(); link = nil }
        deinit { link?.invalidate() }
    }
}

enum IslandColorTreatment: String, CaseIterable {
    case immersed, softHalo, pearl, underlight
}

extension EnvironmentValues {
    @Entry var islandColorTreatment: IslandColorTreatment? = nil
    @Entry var islandColorTime: Double? = nil
}

struct IslandColorSurface: View {
    let treatment: IslandColorTreatment
    let shape: NotchShape
    let paused: Bool
    var lightingStrength: Double = 1
    var blackBody = false
    var showsHalo = true
    @Environment(\.islandColorTime) private var previewTime
    @State private var accumulatedTime: TimeInterval = 0
    @State private var animationAnchor = Date()

    var body: some View {
        ZStack {
            if showsHalo && (treatment == .softHalo || treatment == .underlight) {
                flowingColorField(intensity: 1)
                    .mask(shape.stroke(lineWidth: treatment == .underlight ? 18 : 12).padding(28))
                    .blur(radius: treatment == .underlight ? 17 : 13)
                    .padding(-28)
                    .opacity((treatment == .underlight ? 0.88 : 0.58) * lightingStrength)
                    .mask {
                        if treatment == .underlight { lowerLightMask.padding(-40) }
                        else { Color.white.padding(-40) }
                    }
            }
            shape.fill(blackBody ? Color.black : Color(red: 0.026, green: 0.027, blue: 0.039).opacity(treatment == .pearl ? 0.94 : 0.88))
            if !blackBody {
                flowingColorField(intensity: interiorIntensity)
                    .mask {
                        if treatment == .underlight { lowerLightMask }
                        else { Color.white }
                    }
                    .clipShape(shape)
                    .opacity(lightingStrength)
                if treatment == .pearl {
                    LinearGradient(colors: [.white.opacity(0.09), Color(red: 0.53, green: 0.63, blue: 0.79).opacity(0.025), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(shape)
                    NotchLightingFrames(paused: paused || previewTime != nil) { date in
                        pearlReflection(time: animationTime(at: date))
                    }
                    .mask(shape.stroke(lineWidth: 0.9))
                } else {
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.035), .white.opacity(0.09)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: paused) { _, isPaused in
            let now = Date()
            if isPaused { accumulatedTime += now.timeIntervalSince(animationAnchor) }
            animationAnchor = now
        }
    }

    // Only the color field ticks. Silhouette masks stay outside TimelineView so their
    // animatable radii follow the shell's spring during expansion and retraction.
    private func flowingColorField(intensity: Double) -> some View {
        NotchLightingFrames(paused: paused || previewTime != nil) { date in
            colorField(time: animationTime(at: date), intensity: intensity)
        }
    }

    private func animationTime(at date: Date) -> TimeInterval {
        previewTime ?? (accumulatedTime + (paused ? 0 : date.timeIntervalSince(animationAnchor)))
    }

    private var interiorIntensity: Double {
        switch treatment {
        case .immersed: 0.50
        case .softHalo: 0.13
        case .pearl: 0.045
        case .underlight: 0.36
        }
    }

    private var lowerLightMask: LinearGradient {
        LinearGradient(stops: [.init(color: .clear, location: 0.25),
                               .init(color: .white.opacity(0.2), location: 0.52),
                               .init(color: .white, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func pearlReflection(time: Double) -> LinearGradient {
        let drift = 0.12 * sin(time * 2 * .pi / 12)
        return LinearGradient(stops: [.init(color: .white.opacity(0.09), location: 0),
                                      .init(color: Color(red: 0.77, green: 0.85, blue: 0.98).opacity(0.55), location: 0.24 + drift),
                                      .init(color: .white.opacity(0.07), location: 0.55),
                                      .init(color: Color(red: 0.90, green: 0.77, blue: 0.68).opacity(0.24), location: 0.82 + drift / 2),
                                      .init(color: .white.opacity(0.06), location: 1)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func colorField(time: Double, intensity: Double) -> some View {
        let t = time * 2 * .pi / 12
        return GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                bloom(Color(red: 0.27, green: 0.44, blue: 0.96), opacity: intensity,
                      x: 0.16 + 0.13 * sin(t), y: 0.80 + 0.12 * cos(t), width: width, height: height)
                bloom(Color(red: 0.66, green: 0.23, blue: 0.61), opacity: intensity * 0.83,
                      x: 0.70 + 0.16 * cos(t), y: 0.62 + 0.22 * sin(t), width: width, height: height)
                bloom(Color(red: 0.92, green: 0.56, blue: 0.19), opacity: intensity * 0.82,
                      x: 0.46 + 0.25 * sin(t + 1.5), y: 0.04 + 0.16 * cos(t), width: width, height: height)
            }
        }
    }

    private func bloom(_ color: Color, opacity: Double, x: Double, y: Double,
                       width: CGFloat, height: CGFloat) -> some View {
        Ellipse().fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: width * 0.38))
            .frame(width: width * 1.10, height: max(height * 2.8, width * 0.8))
            .position(x: width * x, y: height * y)
    }
}

/// A single black overlay over continuous dark glass. Unlike crossfading two
/// separately masked materials, this cannot create a bright translucent seam.
struct NotchBlackCrown: View {
    let protectedHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let start = min(protectedHeight, height)
            let fade = min(48, height - start)
            if fade <= 0 {
                Color.black
            } else {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: start / height),
                    .init(color: .black.opacity(0.87), location: (start + fade * 0.25) / height),
                    .init(color: .black.opacity(0.28), location: (start + fade * 0.75) / height),
                    .init(color: .clear, location: (start + fade) / height),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small, self-lit color wash for startup. It never samples or blurs the desktop.
/// Its mask stays attached to the shell's interpolated bounds during expansion.
struct NotchThinkingUnderlight: View {
    let visible: Bool
    let protectedHeight: CGFloat
    let reduceMotion: Bool
    var maximumDepth: CGFloat = 24
    @Environment(\.islandColorTime) private var previewTime
    @State private var started = Date()

    var body: some View {
        GeometryReader { geometry in
            let depth = min(maximumDepth, max(4, geometry.size.height - protectedHeight))
            NotchLightingFrames(paused: !visible || reduceMotion || previewTime != nil) { date in
                let time = previewTime ?? (reduceMotion ? 0 : date.timeIntervalSince(started))
                Canvas { context, size in
                    // Each broad ribbon travels left → right, fading completely
                    // before it wraps offscreen. Staggered colors keep the flow continuous.
                    let colors = [Color(red: 0.25, green: 0.53, blue: 1),
                                  Color(red: 0.84, green: 0.34, blue: 0.83),
                                  Color(red: 1, green: 0.64, blue: 0.30)]
                    for (index, color) in colors.enumerated() {
                        let progress = (max(0, time) / 3.6 + Double(index) / 3)
                            .truncatingRemainder(dividingBy: 1)
                        let x = size.width * (-0.40 + 1.80 * progress)
                        let intensity = pow(sin(progress * .pi), 0.75) * 0.95
                        let center = CGPoint(x: x, y: size.height * 1.05)
                        context.drawLayer { glow in
                            glow.addFilter(.blur(radius: 5))
                            let area = CGRect(x: x - size.width * 0.34, y: -size.height,
                                              width: size.width * 0.68, height: size.height * 4)
                            glow.fill(Path(ellipseIn: area), with: .radialGradient(
                                Gradient(colors: [color.opacity(intensity), color.opacity(intensity * 0.50), .clear]),
                                center: center, startRadius: 0, endRadius: size.width * 0.34))
                        }
                        context.drawLayer { ribbon in
                            ribbon.addFilter(.blur(radius: 1.8))
                            let area = CGRect(x: x - size.width * 0.23, y: size.height - 3,
                                              width: size.width * 0.46, height: 5)
                            ribbon.fill(Path(roundedRect: area, cornerRadius: 2.5), with: .linearGradient(
                                Gradient(colors: [.clear, color.opacity(intensity * 0.85), .clear]),
                                startPoint: CGPoint(x: area.minX, y: area.midY),
                                endPoint: CGPoint(x: area.maxX, y: area.midY)))
                        }
                    }
                }
            }
            .frame(height: depth)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .white.opacity(0.2), location: 0.35),
                                         .init(color: .white, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : (visible ? 0.7 : 0.35)), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A single completion sweep, not another continuously running animation clock.
struct NotchCompletionUnderlight: View {
    let reduceMotion: Bool
    @State private var progress = 0.0
    var body: some View {
        CompletionSweep(progress: reduceMotion ? 1 : progress)
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85)) { progress = 1 }
            }
    }
    private struct CompletionSweep: View, Animatable {
        var progress: Double
        var animatableData: Double { get { progress } set { progress = newValue } }
        var body: some View {
            GeometryReader { geometry in
                let width = geometry.size.width
                let intensity = max(0, sin(progress * .pi))
                Ellipse()
                    .fill(Color(red: 0.73, green: 0.88, blue: 0.82).opacity(0.48 * intensity))
                    .frame(width: width * 0.65, height: 12)
                    .blur(radius: 10)
                    .position(x: width * (-0.1 + 1.2 * progress), y: geometry.size.height - 2)
            }
        }
    }
}

struct NotchCompletionCheck: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var arrived = false
    private let tint = Color(red: 0.73, green: 0.88, blue: 0.82)
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size > 20 ? 11 : 9, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.08), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.20), lineWidth: 0.7))
            .scaleEffect(reduceMotion || arrived ? 1 : 0.75)
            .opacity(reduceMotion || arrived ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { arrived = true }
            }
            .accessibilityLabel("Completed")
            .allowsHitTesting(false)
    }
}
