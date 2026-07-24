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
        let template = String(localized: "%.2f of %.2f GB", locale: AppLanguage.resolvedLocale)
        return String(format: template,
                     Double(download.bytesDone) / 1_000_000_000,
                     Double(download.bytesTotal) / 1_000_000_000)
    }

    var body: some View {
        if visible {
            Group {
                if case .failed = download.phase { paused } else { downloading }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            MonoCaps("Downloading on-device model", size: 9, tracking: 2.0, color: Theme.Ink.label)
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
