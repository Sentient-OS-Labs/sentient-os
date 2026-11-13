// Minimal, selectable summary reader. Streaming never changes window size or forces scrolling;
// selection freezes the rendered text until released. Copy uses the complete current summary.
// Doc: Documentation - Summarize.md
import SwiftUI
import AppKit

struct SummaryView: View {
    let summary: Summarize
    @State private var copied = false

    var body: some View {
        if summary.needsAccessibilityPermission {
            QuickActionPermissionView(feature: .summaryAccessibility, onDone: summary.dismiss)
        } else if summary.needsScreenPermission {
            QuickActionPermissionView(feature: .summarize, onDone: summary.dismiss)
        } else {
            reader
        }
    }

    private var reader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Summary").font(.system(size: 17, weight: .medium))
                    .fixedSize()
                if summary.phase != .failed || summary.capturedAt != nil {
                    ViewThatFits(in: .horizontal) {
                        sourceBadge(compact: false)
                        sourceBadge(compact: true)
                    }
                    .accessibilityIdentifier("summary.source")
                }
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .disabled(summary.text.isEmpty).accessibilityIdentifier("summary.copy")
                Button(action: summary.dismiss) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .accessibilityLabel("Close summary").help("Close summary (Esc)")
                .accessibilityIdentifier("summary.close")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.leading, 28).padding(.trailing, 18).frame(height: 64)
            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)

            if !summary.text.isEmpty {
                SummaryReader(text: summary.text, generation: summary.requestID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityIdentifier("summary.text")
            }
            if summary.isBusy || summary.error != nil {
                VStack(alignment: .leading, spacing: 16) {
                    if summary.isBusy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(summary.phase == .capturing ? "Reading your screen…" : summary.text.isEmpty
                                 ? (summary.expectsVideoTranscript ? "Summarizing video…" : "Summarizing your screen…") : "Finishing…")
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.66))
                        }
                        .accessibilityIdentifier("summary.progress")
                    }
                    if let error = summary.error {
                        VStack(alignment: .leading, spacing: 14) {
                            if !summary.text.isEmpty {
                                Text("Summary interrupted").font(.system(size: 13, weight: .medium))
                            }
                            Text(error).font(.system(size: 14)).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(.white.opacity(0.78)).textSelection(.enabled)
                            HStack(spacing: 16) {
                                Button("Retry", action: summary.retry)
                                    .accessibilityIdentifier("summary.retry")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                        .accessibilityIdentifier("summary.error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, summary.text.isEmpty ? 24 : 12)
            }
            if summary.text.isEmpty { Spacer(minLength: 0) }

        }
        .id(summary.requestID)
        .background(SummaryBackdrop())
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
        .ignoresSafeArea()
        .onChange(of: summary.requestID) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)); copied = false } catch { }
        }
    }

    private func sourceBadge(compact: Bool) -> some View {
        let fetched = summary.sourceInfo?.kind == .youtube
        let video = fetched || summary.expectsVideoTranscript
        return Label(compact ? (video ? "Transcript" : "Source") : summary.sourceLabel,
                     systemImage: fetched ? "checkmark.circle" : video ? "play.rectangle" : "doc.text")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
            .fixedSize()
            .help(sourceDetail)
            .accessibilityLabel(sourceDetail)
    }

    private var sourceDetail: String {
        var detail = summary.sourceLabel
        if summary.sourceInfo?.truncated == true { detail += " · summarized from excerpts" }
        if let date = summary.capturedAt { detail += " · " + date.formatted(date: .omitted, time: .shortened) }
        return detail
    }
}


/// Quiet, dark frost: the desktop supplies only a diffuse hint of color. The
/// opaque text sits above the material, never inside a blur or vibrancy group.
struct SummaryBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color.black
            } else {
                SummaryBackdropMaterial()
                // Even over a white window, retain a dark field behind body text.
                Color.black.opacity(contrast == .increased ? 0.90 : 0.82)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SummaryBackdropMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // Clicking the source app must not change the reader's frost or contrast.
        view.state = .active
    }
}
