// A quiet moving rim for permission setup, separate from Home's broad overhead light.
// The opaque center keeps underlying window colors from mixing with permission text.
import SwiftUI
import AppKit

struct PermissionWindowAtmosphere: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var elapsed: TimeInterval = 0
    @State private var anchor: Date?

    private var moving: Bool { visible && appearsActive && !reduceMotion && !lowPower }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { timeline in
            let time = elapsed + (anchor.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0)
            Canvas { context, size in
                guard size.width > 2, size.height > 2 else { return }
                let bounds = CGRect(origin: .zero, size: size)
                let rim = Path(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 13)
                context.fill(Path(bounds), with: .color(Color(white: 0.008)))
                let radius = min(180, max(120, min(size.width, size.height) * 0.52))

                // A few pools of light, not a full-spectrum border or another Home backdrop.
                let colors = [GlowHalo.stops[5], GlowHalo.stops[6], GlowHalo.stops[0]]
                let offsets = [0.08, 0.54, 0.81]
                let strengths = [0.32, 0.25, 0.13]
                for index in colors.indices {
                    let phase = (time / 54 + offsets[index]).truncatingRemainder(dividingBy: 1)
                    let point = rim.trimmedPath(from: 0, to: max(0.0001, phase)).currentPoint ?? .zero
                    let color = colors[index]
                    context.fill(Path(bounds), with: .radialGradient(
                        Gradient(stops: [
                            .init(color: color.opacity(strengths[index]), location: 0),
                            .init(color: color.opacity(strengths[index] * 0.38), location: 0.38),
                            .init(color: color.opacity(0), location: 1)
                        ]), center: point, startRadius: 0, endRadius: radius))
                    context.stroke(rim, with: .radialGradient(
                        Gradient(colors: [color.opacity(index == 2 ? 0.45 : 0.8), color.opacity(0)]),
                        center: point, startRadius: 0, endRadius: radius * 0.9), lineWidth: 1.2)
                }
                context.stroke(rim, with: .color(.white.opacity(contrast == .increased ? 0.34 : 0.07)), lineWidth: 0.75)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .background {
            SidekickWindowPresence { visible = $0 }
                .frame(width: 0, height: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: moving, initial: true) { _, enabled in
            let now = Date()
            if enabled { anchor = now }
            else if let started = anchor {
                elapsed += max(0, now.timeIntervalSince(started))
                anchor = nil
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
