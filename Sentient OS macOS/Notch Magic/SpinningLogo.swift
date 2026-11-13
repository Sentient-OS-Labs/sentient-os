//
//  SpinningLogo.swift
//  Sentient OS macOS
//
//  Native rendering of the current website header's LogoMark.jsx. The source SVG's
//  geometry, linear-gradient stops and Gaussian blur proportions are shared by the
//  static and animated app marks. Only the diffuse halo rotates; the outline and dot stay fixed.
//

import SwiftUI

struct SpinningLogo: View {
    var size: CGFloat = 20
    var fast: Bool = false            // running → quicker spin
    var paused = false               // retained hidden surfaces do not keep a display clock alive
    var coreScale: CGFloat = 1

    // Anchor (angle + wall-time) so a period change re-bases the spin instead of jumping it.
    @State private var anchorAngle: Double = 0
    @State private var anchorTime: Double = Date().timeIntervalSinceReferenceDate

    private static func period(fast: Bool) -> Double { fast ? 2 : 13 }   // seconds / revolution (2s = the fast "processing" spin)

    var body: some View {
        ZStack {
            // Only the transformed halo ticks. Ring, core and their hover animation
            // are outside the clock and share the parent's panel transition.
            TimelineView(.animation(minimumInterval: fast ? 1.0 / 60.0 : 1.0 / 30.0, paused: paused)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let angle = anchorAngle + (paused ? 0 : (t - anchorTime) / Self.period(fast: fast) * 360)
                WebsiteLogoHalo(size: size).equatable()
                    .rotationEffect(.degrees(angle))
            }
            WebsiteLogoForeground(size: size, coreScale: coreScale)
        }
        .frame(width: size, height: size)
        .onChange(of: fast) { oldFast, _ in
            let t = Date().timeIntervalSinceReferenceDate
            if !paused { anchorAngle += (t - anchorTime) / Self.period(fast: oldFast) * 360 }
            anchorTime = t
        }
        .onChange(of: paused) { wasPaused, _ in
            let t = Date().timeIntervalSinceReferenceDate
            if !wasPaused { anchorAngle += (t - anchorTime) / Self.period(fast: fast) * 360 }
            anchorTime = t
        }
        .allowsHitTesting(false)
    }
}

/// Port of src/components/reusable/LogoMark.jsx in the website repository.
/// `size` is the visible outer-ring diameter, matching the header's reserved logo slot;
/// the SVG viewBox includes another ~48% of that diameter as glow room on each side.
struct WebsiteLogoMark: View {
    var size: CGFloat = 20
    var haloAngle: Double = 0
    var coreScale: CGFloat = 1

    var body: some View {
        ZStack {
            WebsiteLogoHalo(size: size).equatable()
                .rotationEffect(.degrees(haloAngle))
            WebsiteLogoForeground(size: size, coreScale: coreScale)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// Rasterize the invariant gradient + Gaussian once at the current backing scale.
/// Rotation is applied outside this layer; neither rotation nor core hover changes it.
private struct WebsiteLogoHalo: View, Equatable {
    let size: CGFloat
    private static let stops: [Gradient.Stop] = [
        .init(color: Color(red: 253 / 255.0, green: 226 / 255.0, blue: 163 / 255.0), location: 0),
        .init(color: Color(red: 1, green: 142 / 255.0, blue: 60 / 255.0), location: 0.14),
        .init(color: Color(red: 1, green: 70 / 255.0, blue: 70 / 255.0), location: 0.28),
        .init(color: Color(red: 232 / 255.0, green: 56 / 255.0, blue: 143 / 255.0), location: 0.42),
        .init(color: Color(red: 155 / 255.0, green: 72 / 255.0, blue: 212 / 255.0), location: 0.572115),
        .init(color: Color(red: 108 / 255.0, green: 92 / 255.0, blue: 229 / 255.0), location: 0.71),
        .init(color: Color(red: 74 / 255.0, green: 144 / 255.0, blue: 226 / 255.0), location: 0.85),
        .init(color: Color(red: 253 / 255.0, green: 226 / 255.0, blue: 163 / 255.0), location: 0.995192),
    ]

    var body: some View {
        let diameter = 42.0098
        let radius = 10.0824 * size / diameter
        Circle()
            .fill(LinearGradient(stops: Self.stops,
                startPoint: UnitPoint(x: 0, y: (35.5433 - 20.1647) / diameter),
                endPoint: UnitPoint(x: (62.4934 - 20.1647) / diameter, y: (36.7669 - 20.1647) / diameter)))
            .frame(width: size, height: size)
            .blur(radius: radius)
            // Preserve the Gaussian's transparent extent before flattening it.
            .padding(radius * 4)
            .drawingGroup()
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

private struct WebsiteLogoForeground: View {
    let size: CGFloat
    let coreScale: CGFloat

    var body: some View {
        let scale = size / 42.0098
        ZStack {
            Circle().fill(.white.opacity(0.007))
                .frame(width: 54.6127 * scale, height: 54.6127 * scale)
                .blur(radius: 4.20098 * scale)
            Circle().strokeBorder(.white, lineWidth: 2.10049 * scale)
                .frame(width: size, height: size)
            Circle().fill(.white)
                .frame(width: 16.804 * scale, height: 16.804 * scale)
                .scaleEffect(coreScale)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

#Preview("logo") {
    ZStack {
        Color.black
        HStack(spacing: 30) {
            SpinningLogo(size: 22, fast: false)
            SpinningLogo(size: 22, fast: true)
        }
    }
    .frame(width: 200, height: 120)
}
