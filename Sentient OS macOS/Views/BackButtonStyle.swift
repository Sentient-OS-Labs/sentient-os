// Shared white-pill appearance for Home and Back navigation buttons.
// makeBody keeps the label, hit area, and pressed/disabled feedback consistent.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI

struct BackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(.white, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
    }
}

#Preview("Back navigation") {
    HStack(spacing: 16) {
        Button {} label: { Label("Home", systemImage: "arrow.left") }
        Button {} label: { Label("Back", systemImage: "chevron.left") }
        Button {} label: { Label("Back", systemImage: "chevron.left") }
            .disabled(true)
    }
    .buttonStyle(BackButtonStyle())
    .padding(24)
    .background(Color(white: 0.065))
    .preferredColorScheme(.dark)
}
