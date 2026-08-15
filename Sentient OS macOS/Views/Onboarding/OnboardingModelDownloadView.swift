//
//  OnboardingModelDownloadView.swift
//  Sentient OS macOS
//
//  The downloading-model screen — shown between Start Analysis and the real ProcessingView when
//  the on-device model hasn't finished landing (ModelDownload). Usually a short beat: the
//  download started minutes earlier (2s after the post-FDA relaunch), so this screen mostly
//  covers the tail. The signature glow bar + honest numbers (percent, GB of GB); a quiet amber
//  note + Try Again on failure. OnboardingView owns the advance: the moment the model verifies,
//  its body re-resolves the path and the analysis takes over.
//

import SwiftUI

struct OnboardingModelDownloadView: View {
    let download: ModelDownload

    private var fraction: Double {
        download.bytesTotal > 0 ? Double(download.bytesDone) / Double(download.bytesTotal) : 0
    }

    /// "2.61 GB of 3.66 GB" — decimal GB, matching how the model size is talked about everywhere.
    private var gbLine: String {
        String(format: "%.2f GB of %.2f GB",
               Double(download.bytesDone) / 1_000_000_000,
               Double(download.bytesTotal) / 1_000_000_000)
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            Image(systemName: "sparkles").font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.65)).symbolEffect(.breathe, options: .speed(0.7))

            VStack(spacing: 14) {
                Text("Downloading your AI")
                    .display(30)
                    .foregroundStyle(.white)
                Text("Sentient's on-device model is what reads your life privately, right on this Mac.\nOne-time download; your analysis starts the moment it lands.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            if case .failed(let reason) = download.phase {
                VStack(spacing: 18) {
                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Ink.amber)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    OnboardingNextButton(title: "Try Again") { download.kickIfNeeded() }
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    GlowProgressBar(value: fraction)
                    HStack {
                        Text(gbLine).fontWeight(.bold).monospacedDigit()
                        Spacer()
                        Text(download.phase == .verifying ? "verifying…" : "\(Int(fraction * 100))%")
                            .monospacedDigit()
                    }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 380)
                .transition(.opacity)
            }

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
        .animation(.easeInOut(duration: 0.3), value: download.phase)
        // The safety net: normally the post-FDA launch kick started this minutes ago, but if that
        // was missed (FDA granted without the relaunch), Start Analysis still gets a download.
        // fullScreenVisible hands the bar off from the corner whisper (ModelDownloadWhisper) —
        // one signature bar on screen, never two.
        .onAppear {
            download.kickIfNeeded()
            download.fullScreenVisible = true
        }
        .onDisappear { download.fullScreenVisible = false }
    }
}

// previewInstance is DEBUG-only, and #Preview bodies compile in Release too — so these must be guarded.
#if DEBUG
#Preview("Downloading — mid-flight") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingModelDownloadView(download: .previewInstance(phase: .downloading, bytesDone: 2_610_000_000))
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}

#Preview("Downloading — failed") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingModelDownloadView(download: .previewInstance(
            phase: .failed("Sentient could not reach the download server. Check your internet connection, then hit Try Again.")))
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
#endif
