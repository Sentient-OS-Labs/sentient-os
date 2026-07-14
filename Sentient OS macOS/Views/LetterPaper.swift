//
//  LetterPaper.swift
//  Sentient OS macOS  ·  Views/
//
//  The letter-paper page: a rounded card whose top-right corner is dog-eared — the cut page
//  outline (`LetterPaper`, an InsettableShape so it can strokeBorder like a RoundedRectangle)
//  and the folded-over flap that lies on the page (`LetterPaperFold`, gradient-lit with a soft
//  under-shadow). Used by the expanded research note (LetterView) to make a briefing read as a
//  letter artifact; generic over size — the fold is a fixed corner, the page any frame.
//

import SwiftUI

/// The page outline: a continuous rounded rect except the top-right corner, which is cut on the
/// diagonal (the paper under the fold). Insettable so an accent `strokeBorder` hugs it exactly.
struct LetterPaper: InsettableShape {
    var cornerRadius: CGFloat = 18
    var fold: CGFloat = 46
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> LetterPaper {
        var s = self; s.insetAmount += amount; return s
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cr = min(cornerRadius, min(r.width, r.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cr, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))          // the diagonal cut (the crease)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cr))
        p.addArc(center: CGPoint(x: r.maxX - cr, y: r.maxY - cr), radius: cr,
                 startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + cr, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + cr, y: r.maxY - cr), radius: cr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cr))
        p.addArc(center: CGPoint(x: r.minX + cr, y: r.minY + cr), radius: cr,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The folded-over corner lying on the page: a triangle hinged on the crease, tip pointing into
/// the page, lit along the fold and casting a soft shadow onto the paper beneath. Place it with
/// `.overlay(alignment: .topTrailing)` sized `fold × fold`.
struct LetterPaperFold: View {
    var fold: CGFloat = 46

    var body: some View {
        FlapShape()
            .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)],
                                 startPoint: .topTrailing, endPoint: .bottomLeading))
            .overlay(FlapShape().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 6, x: -3, y: 3)
            .frame(width: fold, height: fold)
    }

    /// In its own `fold × fold` frame: crease from top-left to bottom-right, tip at bottom-left.
    private struct FlapShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))       // crease start (top of the cut)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))    // crease end (right of the cut)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))    // the flap's tip
            p.closeSubpath()
            return p
        }
    }
}

#Preview("Letter paper") {
    ZStack {
        Color.black.ignoresSafeArea()
        Color.clear
            .frame(width: 420, height: 300)
            .background(Theme.Ink.cardBG, in: LetterPaper())
            .overlay(alignment: .topTrailing) { LetterPaperFold() }
            .overlay(LetterPaper().strokeBorder(
                LinearGradient(colors: [Theme.Ink.green.opacity(0.45), .white.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .padding(40)
    }
}
