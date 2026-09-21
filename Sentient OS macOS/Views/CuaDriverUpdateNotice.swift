// CuaDriverUpdateNotice.swift
// The home's quiet computer-use update: real download progress, verification, retry, and done.
// Reads the shared installer so a Sidekick command and a launch-time update show the same state.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI

struct CuaDriverUpdateNotice: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: CodexSetup.CuaUpdateNotice
    let progress: CuaDriverSetup.Progress?
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .ready:
            CautionCapsule(message: "Computer use is up to date.", accent: Theme.Ink.green,
                           onDismiss: onDismiss)
        case .failed:
            CautionCapsule(message: "Computer use couldn't update. Please try again.",
                           actionTitle: "Retry", onAction: onRetry,
                           onDismiss: onDismiss)
        case .updating:
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.Ink.label)
                        .accessibilityHidden(true)
                    Text("Updating computer use")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Ink.statusInk)
                    Spacer(minLength: 8)
                    if case .downloading(let fraction) = progress, let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.Ink.label)
                    }
                }
                if case .downloading(let fraction) = progress, let fraction {
                    GlowProgressBar(value: fraction)
                        .accessibilityLabel("Computer-use download progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        GeometryReader { geometry in
                            let phase = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 2) + 1) / 2
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(Color.white.opacity(0.4))
                                    .frame(width: geometry.size.width * 0.28)
                                    .offset(x: geometry.size.width * 0.72 * phase)
                            }
                        }
                    }
                        .frame(height: 4)
                        .accessibilityLabel("Updating computer use")
                }
                Text(progress?.message ?? "Preparing the update…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Ink.label)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(width: 330)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        }
    }
}

#Preview("Computer-use update") {
    VStack(alignment: .trailing, spacing: 22) {
        CuaDriverUpdateNotice(state: .updating, progress: .downloading(0.58))
        CuaDriverUpdateNotice(state: .updating, progress: .checkingSignature)
        CuaDriverUpdateNotice(state: .failed, progress: nil)
        CuaDriverUpdateNotice(state: .ready, progress: .ready)
    }
    .padding(40).frame(width: 540).background(.black).preferredColorScheme(.dark)
}
