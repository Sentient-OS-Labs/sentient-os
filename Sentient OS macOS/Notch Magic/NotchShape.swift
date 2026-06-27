//
//  NotchShape.swift
//  Sentient OS macOS
//
//  The notch silhouette: a top-anchored rounded shape whose outer (top) corners curve UP into the
//  screen bezel and whose inner (bottom) corners round off. Both radii are animatable, so the shape
//  morphs fluidly as the notch expands and contracts — the Dynamic-Island feel. Adapted from the
//  DynamicNotch reference (Documentation/Notch Magic/Notch UI Inspiration).
//
//  `NotchSkirtShape` is its open twin — the VISIBLE perimeter: up into the concave TOP CORNERS, down the
//  sides, around the rounded bottom — but NOT the flat top edge between the corners. The flowing edge glow
//  strokes the skirt, so it warps into the top corners yet never lights the flat bezel line (which made
//  state morphs look broken).
//

import SwiftUI

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCornerRadius, rect.height, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // top-left: curve down out of the bezel
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // bottom-left inner corner
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // bottom-right inner corner
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // top-right: curve up into the bezel
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The notch's "skirt": an OPEN path tracing the visible edge — from the top-left bezel point, DOWN the
/// concave corner, down the left side, around the rounded bottom, up the right side, and UP the concave
/// corner to the top-right bezel point. It includes the concave TOP CORNERS (so the glow warps into them)
/// but NOT the flat top edge between them — that bezel line stays dark, keeping state morphs clean.
struct NotchSkirtShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCornerRadius, rect.height, rect.width / 2))
        let bottom = max(0, min(bottomCornerRadius, rect.width / 2 - top, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))                       // top-left, at the bezel
        p.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),   // concave top-left → into the side
                       control: CGPoint(x: rect.minX + top, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))     // down the left side
        p.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + top, y: rect.maxY))    // convex bottom-left
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))     // across the bottom
        p.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - top, y: rect.maxY))    // convex bottom-right
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))        // up the right side
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),               // concave top-right → up to the bezel
                       control: CGPoint(x: rect.maxX - top, y: rect.minY))
        return p
    }
}
