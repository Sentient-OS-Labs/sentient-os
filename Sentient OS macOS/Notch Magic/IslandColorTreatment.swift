// Underlit glass for the notch and external island. Alternate treatments and time
// overrides remain available to the isolated rendering lab.
import SwiftUI

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
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || previewTime != nil)) { context in
                        pearlReflection(time: animationTime(at: context.date))
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
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || previewTime != nil)) { context in
            colorField(time: animationTime(at: context.date), intensity: intensity)
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
    @Environment(\.islandColorTime) private var previewTime
    @State private var started = Date()

    var body: some View {
        GeometryReader { geometry in
            let depth = min(24, max(4, geometry.size.height - protectedHeight))
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || reduceMotion || previewTime != nil)) { timeline in
                let time = previewTime ?? (reduceMotion ? 0 : timeline.date.timeIntervalSince(started))
                Canvas { context, size in
                    context.addFilter(.blur(radius: 7))
                    let phase = time * 2 * .pi / 8
                    let lights: [(Color, Double, Double)] = [
                        (Color(red: 0.30, green: 0.48, blue: 1), 0.18 + 0.22 * sin(phase), 0.66 + 0.22 * cos(phase * 0.8)),
                        (Color(red: 0.83, green: 0.38, blue: 0.80), 0.52 + 0.25 * cos(phase * 0.73 + 1), 0.65 + 0.20 * sin(phase * 0.9)),
                        (Color(red: 1, green: 0.66, blue: 0.35), 0.82 + 0.22 * sin(phase * 0.86 + 2), 0.58 + 0.24 * cos(phase * 0.7 + 2)),
                    ]
                    for (color, x, intensity) in lights {
                        let center = CGPoint(x: size.width * x, y: size.height * 1.02)
                        let area = CGRect(x: center.x - size.width * 0.48, y: -size.height,
                                          width: size.width * 0.96, height: size.height * 4)
                        context.fill(Path(ellipseIn: area), with: .radialGradient(
                            Gradient(colors: [color.opacity(intensity), color.opacity(intensity * 0.45), .clear]),
                            center: center, startRadius: 0, endRadius: size.width * 0.48))
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
