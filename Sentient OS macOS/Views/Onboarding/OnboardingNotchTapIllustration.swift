// Enlarged hardware lesson: a quiet camera, illuminated sensor and a finger that taps/lifts.
// The geometry uses the real notch's sensor offset and shared finger outline. This is inert
// illustration, never a second activation target. Doc: Documentation - Onboarding.md.
import AppKit
import SwiftUI

struct OnboardingNotchTapIllustration: View {
    /// A fixed presentation time lets native render fixtures inspect every gesture pose.
    var presentationTime: TimeInterval? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let cycleDuration: TimeInterval = 4.6
    static let colorCycleDuration = cycleDuration * 4
    @State private var appActive = NSApp.isActive
    @State private var began = Date()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var motionEnabled: Bool { !reduceMotion && !lowPower && appActive }

    private let width: CGFloat = 600
    private let height: CGFloat = 280
    private let notchWidth: CGFloat = 440
    private var sensorX: CGFloat {
        width / 2 + NotchMetrics(hardwareNotch: CGSize(width: notchWidth, height: 96)).lightSensorOffset
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: presentationTime != nil || !motionEnabled)) { context in
                let time = presentationTime ?? (motionEnabled ? context.date.timeIntervalSince(began) : 1.48)
                drawing(time: max(0, time))
                    .frame(width: width, height: height)
                    .scaleEffect(min(geometry.size.width / width, geometry.size.height / height))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .aspectRatio(width / height, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your Mac’s notch. Tap the illuminated sensor just left of the camera, then lift your finger.")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            began = Date(); appActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func drawing(time: TimeInterval) -> some View {
        let pose = NotchTapIllustrationPose(time: time)
        return ZStack(alignment: .topLeading) {
            // The screen's upper rim makes the black silhouette read as hardware.
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.035), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: width - 24, height: 106)
                .position(x: width / 2, y: 91)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white.opacity(0.22), .white.opacity(0.32), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: width - 40, height: 0.7)
                .position(x: width / 2, y: 38)
            NotchShape(topCornerRadius: 13, bottomCornerRadius: 27)
                .fill(LinearGradient(colors: [Color(white: 0.018), .black], startPoint: .top, endPoint: .bottom))
                .overlay {
                    NotchSkirtShape(topCornerRadius: 13, bottomCornerRadius: 27)
                        .stroke(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.24), .white.opacity(0.06)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                }
                .frame(width: notchWidth, height: 96)
                .position(x: width / 2, y: 86)

            SensorLight(time: time, contact: pose.contact)
                .position(x: sensorX, y: 83)
            camera.position(x: width / 2, y: 83)

            // Fine leaders distinguish the two objects even before the first gesture.
            Path { path in
                path.move(to: CGPoint(x: sensorX - 22, y: 106))
                path.addLine(to: CGPoint(x: sensorX - 56, y: 174))
                path.addLine(to: CGPoint(x: sensorX - 90, y: 174))
            }
            .stroke(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.42)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            annotation("TAP HERE", bright: true)
                .position(x: sensorX - 116, y: 196)
            Path { path in
                path.move(to: CGPoint(x: width / 2 + 14, y: 96))
                path.addLine(to: CGPoint(x: width / 2 + 58, y: 174))
                path.addLine(to: CGPoint(x: width / 2 + 91, y: 174))
            }
            .stroke(.white.opacity(0.16), lineWidth: 0.75)
            annotation("CAMERA", bright: false)
                .position(x: width / 2 + 112, y: 196)

            TapLocationFinger()
                .fill(.black.opacity(0.92))
                .overlay {
                    TapLocationFinger()
                        .stroke(LinearGradient(colors: [.white, Color(red: 0.82, green: 0.91, blue: 1),
                                                        Color(red: 1, green: 0.85, blue: 0.72)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
                        .shadow(color: .white.opacity(0.12 + pose.contact * 0.18), radius: 5)
                }
                .frame(width: 38, height: 54)
                .scaleEffect(1 - pose.contact * 0.035, anchor: .top)
                .rotationEffect(.degrees(pose.tilt), anchor: .top)
                .position(x: sensorX, y: 108 + pose.lift)
                .opacity(pose.handOpacity)
        }
    }

    private func annotation(_ text: String, bright: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(2)
            .foregroundStyle(.white.opacity(bright ? 0.78 : 0.50))
            .fixedSize()
    }

    private var camera: some View {
        ZStack {
            Circle().fill(Color(white: 0.012))
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
            Circle().fill(RadialGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.17), .black],
                                         center: .topLeading, startRadius: 0, endRadius: 15))
                .padding(3)
                .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 0.6).padding(3))
            Circle().fill(.black).frame(width: 6, height: 6)
            Ellipse().fill(.white.opacity(0.34)).frame(width: 5, height: 2.5)
                .rotationEffect(.degrees(-35)).offset(x: -4, y: -5)
            Circle().fill(Color(red: 0.43, green: 0.64, blue: 0.80).opacity(0.25))
                .frame(width: 2, height: 2).offset(x: 4, y: 4)
        }
        .frame(width: 24, height: 24)
    }
}

private struct SensorLight: View {
    let time: TimeInterval
    let contact: Double
    private let violet = Color(red: 0.53, green: 0.20, blue: 1)
    private let rose = Color(red: 1, green: 0.18, blue: 0.46)
    private let gold = Color(red: 1, green: 0.62, blue: 0.14)
    private var colorPhase: Double { time * 2 * .pi / OnboardingNotchTapIllustration.colorCycleDuration }
    var body: some View {
        ZStack {
            // Fixed soft falloffs: no changing blur radius or full-window rendering.
            ZStack {
                aura(violet, size: 46).offset(x: -8 + 2 * sin(colorPhase), y: -5 + 2 * cos(colorPhase))
                aura(rose, size: 46).offset(x: 8 + 2 * cos(colorPhase + .pi / 3), y: 1 + 2 * sin(colorPhase))
                aura(gold, size: 42).offset(x: -2 + 3 * sin(colorPhase + 2 * .pi / 3), y: 10 + 2 * cos(colorPhase))
            }
            .scaleEffect(0.94 + 0.045 * sin(time * 2 * .pi / OnboardingNotchTapIllustration.cycleDuration) + contact * 0.13)
            .opacity(0.95 + contact * 0.05)

            Circle().fill(.black.opacity(0.85)).frame(width: 14, height: 14)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.95), Color(red: 0.83, green: 0.91, blue: 1).opacity(0.65), .clear],
                                         center: .center, startRadius: 0, endRadius: 6))
                .frame(width: 12, height: 12)
                .opacity(0.6 + contact * 0.4)

        }
        .frame(width: 160, height: 160)
    }

    private func aura(_ color: Color, size: CGFloat) -> some View {
        Circle().fill(RadialGradient(stops: [.init(color: color.opacity(0.90), location: 0),
                                           .init(color: color.opacity(0.44), location: 0.42),
                                           .init(color: .clear, location: 1)],
                                    center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

/// A slow approach, brief contact, then an unmistakable lift. Pure time-derived poses
/// make pause, Reduce Motion and preview rendering independent of gesture recognition.
private struct NotchTapIllustrationPose {
    let lift: CGFloat
    let tilt: Double
    let handOpacity: Double
    let contact: Double

    init(time: TimeInterval) {
        let t = time.truncatingRemainder(dividingBy: OnboardingNotchTapIllustration.cycleDuration)
        func ease(_ a: Double, _ b: Double) -> Double {
            let x = min(1, max(0, (t - a) / (b - a)))
            return x * x * x * (x * (x * 6 - 15) + 10)
        }
        let approach = ease(0.40, 1.35), release = ease(1.65, 2.55)
        lift = 57 * (1 - approach) + 48 * release
        tilt = -9 * (1 - approach) + 5 * release
        handOpacity = ease(0.10, 0.55) * (1 - ease(2.65, 3.30))
        contact = ease(1.33, 1.46) * (1 - ease(1.65, 1.92))
    }
}

#Preview("Notch tap · contact") {
    OnboardingNotchTapIllustration(presentationTime: 1.5)
        .frame(width: 600).padding(30).background(.black).preferredColorScheme(.dark)
}
