// Invitation stationery: the perforated paper ticket, its stamp, and a saved lifetime pass.
// Shared by onboarding's corner ticket and the gift-opening presentation.
// Doc: ../Views/Onboarding/Documentation - Onboarding.md

import SwiftUI

enum InvitePaper {
    static let light = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let shade = Color(red: 0.84, green: 0.81, blue: 0.72)
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.16)
    static let spectrum: [Color] = [.cyan, .blue, .purple, .pink, .orange, .yellow, .mint, .cyan]
}

struct InviteTicketFace: View {
    var claimed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    if claimed {
                        Text("YOUR LIFETIME PASS")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.8).opacity(0.65)
                    }
                    Text(claimed ? "Yours. For life." : "Have a gift code?")
                        .font(.system(size: 26, weight: .medium))
                }
                Spacer(minLength: 10)
                InviteStamp(claimed: claimed).frame(width: 40, height: 40)
            }
            .padding(.horizontal, 22).frame(height: 86)

            InvitePerforation()

            HStack(spacing: 8) {
                Text(claimed ? "Sentient OS · Lifetime access" : "Enter your code")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: claimed ? "checkmark" : "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .foregroundStyle(InvitePaper.ink)
        .modifier(InviteTicketMaterial())
    }
}

struct InviteStamp: View {
    var claimed = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(InvitePaper.ink.opacity(0.35), lineWidth: 1)
            Circle().strokeBorder(InvitePaper.ink.opacity(0.12), lineWidth: 1).padding(4)
            if claimed {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .medium))
            } else {
                Image(systemName: "sparkle").font(.system(size: 20, weight: .regular))
            }
        }
        .foregroundStyle(InvitePaper.ink)
        .rotationEffect(.degrees(-12))
        .accessibilityHidden(true)
    }
}

struct InvitePerforation: View {
    var body: some View {
        Rectangle().fill(InvitePaper.ink.opacity(0.25))
            .frame(height: 1)
            .mask {
                Canvas { context, size in
                    for x in stride(from: 0.0, to: size.width, by: 7) {
                        context.fill(Path(CGRect(x: x, y: 0, width: 3, height: 1)), with: .color(.white))
                    }
                }
            }
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }
}

struct InviteTicketMaterial: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                InviteTicketShape()
                    .fill(LinearGradient(colors: [InvitePaper.light, InvitePaper.shade],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Canvas { context, size in
                            for index in 0..<600 {
                                let x = CGFloat((index * 73) % 997) / 997 * size.width
                                let y = CGFloat((index * 131) % 991) / 991 * size.height
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                                             with: .color(InvitePaper.ink.opacity(0.045)))
                            }
                        }
                        .clipShape(InviteTicketShape())
                        .allowsHitTesting(false)
                    }
            }
            .clipShape(InviteTicketShape())
            .overlay { InviteTicketShape().strokeBorder(.white.opacity(0.28), lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
    }
}

/// Punches sit on the fixed header perforation, so expanding the input keeps the paper continuous.
struct InviteTicketShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let corner = max(0, 15 - insetAmount)
        let punch = max(0, 7 + insetAmount)
        let seam = min(r.maxY - corner - punch, r.minY + 87 - insetAmount)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + corner, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + corner), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: seam - punch))
        p.addArc(center: CGPoint(x: r.maxX, y: seam), radius: punch,
                 startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - corner))
        p.addQuadCurve(to: CGPoint(x: r.maxX - corner, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + corner, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - corner), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: seam + punch))
        p.addArc(center: CGPoint(x: r.minX, y: seam), radius: punch,
                 startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + corner))
        p.addQuadCurve(to: CGPoint(x: r.minX + corner, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

#if DEBUG
#Preview("Invitation ticket") {
    HStack(spacing: 30) {
        InviteTicketFace()
        InviteTicketFace(claimed: true)
    }
    .frame(width: 700).padding(50).background(.black)
}
#endif
