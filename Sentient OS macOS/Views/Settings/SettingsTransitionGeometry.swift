import Foundation
import CoreGraphics

/// A small capsule at the actual Home button grows into the page's full bounds.
/// The source is resolved from a SwiftUI anchor each layout, so it also tracks window resizing.
nonisolated struct SettingsTransitionGeometry {
    let frame: CGRect
    let cornerRadius: CGFloat
    let anchor: CGPoint
    let contentOpacity: Double
    let contentScale: CGFloat
    let contentBlur: CGFloat

    static func source(_ source: CGRect?, in canvas: CGSize) -> CGRect? {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              let source, !source.isInfinite, !source.isNull,
              source.origin.x.isFinite, source.origin.y.isFinite,
              source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { return nil }
        let clipped = source.intersection(CGRect(origin: .zero, size: canvas))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    init?(source: CGRect?, canvas: CGSize, progress: CGFloat) {
        guard let source = Self.source(source, in: canvas), progress.isFinite else { return nil }
        // Springs can overshoot. The mask must never leave the page or invert its bounds.
        let p = min(1, max(0, progress))
        func mix(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * p }
        frame = CGRect(x: mix(source.minX, 0), y: mix(source.minY, 0),
                       width: mix(source.width, canvas.width), height: mix(source.height, canvas.height))
        let radius = mix(min(source.width, source.height) / 2, 0) + sin(.pi * p) * 18
        cornerRadius = p == 1 ? 0 : min(radius, min(frame.width, frame.height) / 2)
        anchor = CGPoint(x: source.midX / canvas.width, y: source.midY / canvas.height)
        contentOpacity = Double(min(1, max(0, (p - 0.08) / 0.68)))
        contentScale = mix(0.94, 1)
        contentBlur = mix(7, 0)
    }
}
