//
//  ModelDownloadWhisper.swift
//  Sentient OS macOS
//
//  The quiet bottom-left download card: while the on-device model lands in the background
//  (ModelDownload), a small glass card with the signature GlowProgressBar + honest numbers rides
//  RootView's bottom-leading overlay, over whatever screen is up. It yields while onboarding's
//  full-screen downloading view shows the same bar big (ModelDownload.fullScreenVisible), fades
//  away on .ready, and swaps to one quiet amber line on .failed (the full-screen view owns the
//  Try Again flow).
//

import SwiftUI

struct ModelDownloadWhisper: View {
    let download: ModelDownload
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Nothing renders when there's nothing worth whispering about (idle/ready), or while the
    /// full-screen downloading view has the bar — the signature bar never shows twice on one screen.
    private var visible: Bool {
        if download.fullScreenVisible { return false }
        switch download.phase {
        case .downloading, .verifying, .failed: return true
        case .idle, .ready: return false
        }
    }

    private var fraction: Double {
        download.bytesTotal > 0 ? Double(download.bytesDone) / Double(download.bytesTotal) : 0
    }

    /// "1.24 of 3.66 GB" — decimal GB, same voice as the full-screen downloading view.
    private var gbLine: String {
        String(format: "%.2f of %.2f GB",
               Double(download.bytesDone) / 1_000_000_000,
               Double(download.bytesTotal) / 1_000_000_000)
    }

    var body: some View {
        if visible {
            Group {
                if case .failed = download.phase { paused } else { downloading }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                if reduceTransparency {
                    shape.fill(Color(white: 0.07))
                } else {
                    // System-composited backdrop, bounded to this small card. Keep
                    // bright film details subdued without blurring the webview itself.
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(.black.opacity(0.2)))
                        .environment(\.colorScheme, .dark)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1))
            .transition(.opacity)
        }
    }

    private var borderColor: Color {
        if case .failed = download.phase { return Theme.Ink.amber.opacity(0.28) }
        return Theme.stroke
    }

    private var downloading: some View {
        VStack(alignment: .leading, spacing: 9) {
            MonoCaps("Downloading in the background", size: 9, tracking: 1.2, color: Theme.Ink.label)
            GlowProgressBar(value: fraction)
            HStack {
                Text(gbLine)
                Spacer()
                Text(download.phase == .verifying ? "verifying…" : "\(Int(fraction * 100))%")
            }
            .font(.system(size: 10.5)).monospacedDigit()
            .foregroundStyle(Theme.secondary)
        }
        .frame(width: 212)
    }

    private var paused: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoCaps("Model download paused", size: 9, tracking: 2.0, color: Theme.Ink.amber)
            Text("It will resume when you continue.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
        }
        .frame(width: 212, alignment: .leading)
    }
}

// previewInstance is DEBUG-only, and #Preview bodies compile in Release too — so these must be guarded.
#if DEBUG
#Preview("Download whisper — states") {
    ZStack(alignment: .bottomLeading) {
        Color.black.ignoresSafeArea()
        VStack(alignment: .leading, spacing: 18) {
            ModelDownloadWhisper(download: .previewInstance(phase: .downloading, bytesDone: 310_000_000))
            ModelDownloadWhisper(download: .previewInstance(phase: .downloading, bytesDone: 2_610_000_000))
            ModelDownloadWhisper(download: .previewInstance(phase: .verifying, bytesDone: 3_659_530_240))
            ModelDownloadWhisper(download: .previewInstance(
                phase: .failed("Sentient could not reach the download server.")))
        }
        .padding(22)
    }
    .frame(width: 420, height: 480)
    .preferredColorScheme(.dark)
}
#endif
