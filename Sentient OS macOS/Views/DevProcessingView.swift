//
//  DevProcessingView.swift
//  Sentient OS macOS
//
//  DEV-ONLY copy of the on-device processing takeover, dedicated to the iterative system's
//  "start on device" buttons in DevToolsView. It is a deliberate FORK of ProcessingView so the
//  dev processing UI can be iterated on freely without touching the production home "Analyze Now"
//  screen (ProcessingView). Only the iterative path lives here: it streams IterativeRun's progress
//  (over the lit connectors) into the same breathing-sparkle / glow-bar / "just processed" layout.
//
//  Reuses the shared FileThumbnail + verdict pills (Theme.swift) + PipelineProgress; carries its
//  OWN copies of the title + glow-bar helpers (DevAnalyzingTitle / DevGlowProgressBar) because the
//  ProcessingView originals are file-private.
//

import SwiftUI

struct DevProcessingView: View {
    let modelPath: String
    let connectors: [any Connector]
    let mode: IterativeRun.Mode
    var onDone: () -> Void

    init(modelPath: String, connectors: [any Connector], mode: IterativeRun.Mode, onDone: @escaping () -> Void) {
        self.modelPath = modelPath; self.connectors = connectors; self.mode = mode; self.onDone = onDone
    }

    private enum UIState: Equatable { case loadingModel, processing, completed, failed(String) }
    @State private var state: UIState = .loadingModel
    @State private var progress = PipelineProgress()
    @State private var stopped = false
    @State private var started = false
    @State private var iterativeTask: Task<PipelineProgress, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch state {
                    case .loadingModel:   loadingView
                    case .processing:     processingContent
                    case .completed:      completedView
                    case .failed(let e):  failedView(e)
                    }
                }
                Spacer(minLength: 0)
                if state == .loadingModel || state == .processing {
                    footer.padding(.bottom, 30)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await startIfNeeded() }
        .onDisappear { iterativeTask?.cancel() }
    }

    // MARK: States

    private var loadingView: some View {
        VStack(spacing: 22) {
            Image(systemName: "cpu").font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.6)).symbolEffect(.pulse)
            Text("Loading on-device model").font(.title3.weight(.semibold)).foregroundStyle(.white)
            ProgressView().tint(.white.opacity(0.4))
        }
    }

    private var processingContent: some View {
        VStack(spacing: 26) {
            Image(systemName: "sparkles").font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.65)).symbolEffect(.breathe, options: .speed(0.7))

            DevAnalyzingTitle()

            VStack(spacing: 10) {
                DevGlowProgressBar(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                HStack {
                    Text("\(progress.done) of \(progress.total)").fontWeight(.bold).monospacedDigit()
                    Spacer()
                    Text("\(percent)%").monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 320)

            countsLine

            if progress.lastPath != nil {   // something was processed (files have a path; chat windows do too)
                justProcessed
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 30)
    }

    private var countsLine: some View {
        HStack(spacing: 16) {
            countTag(progress.survivors, "kept", Theme.verdictColor(.survivor))
            countTag(progress.junk, "junk", Theme.verdictColor(.junk))
            countTag(progress.reminders, "reminders", Color(red: 1.0, green: 0.78, blue: 0.28))
            if let last = progress.lastSeconds {
                Text("· \(String(format: "%.1f", last))s/file")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func countTag(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var justProcessed: some View {
        VStack(spacing: 12) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 60)
            Text("JUST PROCESSED").font(.caption2).tracking(1.5).foregroundStyle(.white.opacity(0.3))
            HStack(alignment: .top, spacing: 16) {
                FileThumbnail(path: progress.lastFilePath, size: 66)
                    .id(progress.done)
                    .transition(.blurReplace)
                VStack(alignment: .leading, spacing: 6) {
                    let verdict = progress.lastVerdict
                    // Pills: sensitive (red) / junk (dim) / reminder (gradient). Kept = none.
                    if verdict == .sensitive || verdict == .junk || progress.lastReminder {
                        HStack(spacing: 6) {
                            if verdict == .sensitive { SensitivePill() }
                            else if verdict == .junk { JunkPill() }
                            if progress.lastReminder && verdict != .sensitive { ReminderPill() }
                        }
                    }
                    if let title = progress.lastTitle {
                        Text(title).font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(verdict == .junk ? 0.5 : 1.0))
                            .frame(maxWidth: 340, alignment: .leading)
                    }
                    let fallback = verdict == .sensitive ? "Held back — sensitive."
                                 : verdict == .junk ? "Nothing worth keeping here." : ""
                    let body = progress.lastSummary ?? fallback
                    if !body.isEmpty {
                        Text(body)
                            .font(.subheadline)
                            .italic(progress.lastSummary == nil)
                            .foregroundStyle(.white.opacity(verdict == .survivor ? 0.85 : 0.32))
                            .lineLimit(3).frame(maxWidth: 340, alignment: .leading)
                            .blur(radius: verdict == .sensitive ? 6 : 0)   // redact sensitive content
                    }
                    if let path = progress.lastPath {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 340, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
                .id(progress.done)
                .transition(.blurReplace)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 460)
        }
        .animation(.easeInOut(duration: 0.4), value: progress.done)
    }

    private var completedView: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58))
                .foregroundStyle(Theme.verdictColor(.survivor))
            VStack(spacing: 6) {
                Text("Analysis complete").font(.serif(28)).italic().foregroundStyle(.white)
                Text("\(progress.survivors) kept · \(progress.junk) junk · \(progress.reminders) reminders · \(progress.failed) failed")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.55))
            }
            Button(action: onDone) {
                Text("Done").font(.headline).foregroundStyle(.black)
                    .frame(width: 200, height: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain).padding(.top, 6)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46))
                .foregroundStyle(.orange.opacity(0.85))
            Text("Processing failed").font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(message).font(.caption).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("Back", action: onDone).buttonStyle(.bordered).tint(.white)
                Button("Retry") { Task { started = false; await startIfNeeded() } }
                    .buttonStyle(.borderedProminent).tint(.white)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Button(action: stop) {
                    Text("Stop Analysis")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                Text("Analysis can always resume later.")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill")
                Text("Private by design. Your files never leave this Mac.")
            }
            .font(.callout).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Stop the run and return home. The cycle's pointers advance per durable save, so re-running resumes.
    private func stop() {
        stopped = true
        iterativeTask?.cancel()
        onDone()
    }

    private var percent: Int {
        progress.total > 0 ? Int(Double(progress.done) / Double(progress.total) * 100) : 0
    }

    // MARK: Run

    private func startIfNeeded() async {
        guard !started else { return }
        started = true
        await run()
    }

    private func run() async {
        stopped = false
        state = .loadingModel

        // Stream IterativeRun's progress into the takeover (IterativeRun owns the engine).
        let (stream, continuation) = AsyncStream.makeStream(
            of: PipelineProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { continuation.finish() }
            let runner = IterativeRun(modelPath: modelPath)
            return mode == .initial
                ? await runner.runInitial(connectors) { continuation.yield($0) }
                : await runner.runIterative(connectors) { continuation.yield($0) }
        }
        iterativeTask = task
        for await p in stream {
            if state == .loadingModel { withAnimation { state = .processing } }
            progress = p
        }
        progress = await task.value
        withAnimation { state = .completed }
    }
}

// MARK: - Analyzing title (dev copy of ProcessingView's private AnalyzingTitle)

/// "Analyzing ___" with the right-hand word cycling. Dev-local copy so DevProcessingView can be
/// edited without touching ProcessingView's file-private original.
private struct DevAnalyzingTitle: View {
    private let words = ["Files", "Notes", "Messages", "WhatsApp", "Everything."]
    @State private var index = 0

    var body: some View {
        HStack(spacing: 7) {
            Text("Analyzing").font(.title2.weight(.semibold)).foregroundStyle(.white)
            Text("Everything.")
                .font(.title2.weight(.semibold))
                .opacity(0)
                .accessibilityHidden(true)
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Text(words[index])
                            .font(.title2.weight(words[index] == "Everything." ? .bold : .semibold))
                            .foregroundStyle(gradient(words[index]))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .id(index)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4.0))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.4)) { index = (index + 1) % words.count }
            }
        }
    }

    private func gradient(_ word: String) -> LinearGradient {
        let colors: [Color]
        switch word {
        case "Files":       colors = [Color(red: 0.55, green: 0.95, blue: 0.30), Color(red: 0.15, green: 0.80, blue: 0.50), Color(red: 0.10, green: 0.55, blue: 0.65)]
        case "Notes":       colors = [Color(red: 1.00, green: 0.85, blue: 0.25), Color(red: 1.00, green: 0.55, blue: 0.20), Color(red: 1.00, green: 0.30, blue: 0.45)]
        case "Messages":    colors = [Color(red: 0.30, green: 0.85, blue: 0.55), Color(red: 0.20, green: 0.60, blue: 0.98)]
        case "WhatsApp":    colors = [Color(red: 0.42, green: 0.92, blue: 0.45), Color(red: 0.10, green: 0.70, blue: 0.45)]
        case "Everything.": colors = [Color(red: 0.66, green: 0.42, blue: 0.85), Color(red: 0.91, green: 0.45, blue: 0.75), Color(red: 0.96, green: 0.55, blue: 0.50), Color(red: 0.95, green: 0.70, blue: 0.35)]
        default:            colors = [.white, .white]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Glowing progress bar (dev copy of ProcessingView's private GlowProgressBar)

/// A multicolor signature-gradient fill with a flowing sheen + soft glow. Dev-local copy.
private struct DevGlowProgressBar: View {
    var value: Double   // 0...1

    @State private var phase: Double = 0
    @State private var lastTick: Date?

    private let band: CGFloat = 280   // points spanned by one full color sequence

    private static let stops: [Color] = [
        Color(red: 1.00, green: 0.78, blue: 0.28),  // amber
        Color(red: 1.00, green: 0.45, blue: 0.45),  // coral
        Color(red: 0.91, green: 0.30, blue: 0.62),  // pink
        Color(red: 0.62, green: 0.40, blue: 0.95),  // violet
        Color(red: 0.36, green: 0.55, blue: 0.98),  // blue
        Color(red: 0.30, green: 0.85, blue: 0.65),  // mint
    ]

    private static let gradientStops: [Gradient.Stop] = {
        var result: [Gradient.Stop] = []
        let n = stops.count
        for rep in 0..<2 {
            for (i, color) in stops.enumerated() {
                result.append(.init(color: color, location: (Double(rep) + Double(i) / Double(n)) / 2.0))
            }
        }
        result.append(.init(color: stops[0], location: 1.0))
        return result
    }()

    @ViewBuilder
    private func coloredCapsule(p: CGFloat, fill: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(stops: Self.gradientStops, startPoint: .leading, endPoint: .trailing))
                .frame(width: band * 2, height: 9)
                .offset(x: -band + p)
        }
        .frame(width: fill, height: 9, alignment: .leading)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func tipGlow(p: CGFloat, fill: CGFloat, blur: CGFloat) -> some View {
        let t = min(1.0, value * 3.0)
        coloredCapsule(p: p, fill: fill)
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1 - t), location: 0.0),
                    .init(color: .white, location: 1.0),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .blur(radius: blur)
            .blendMode(.plusLighter)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = value > 0 ? max(min(value, 1) * w, 14) : 0
            let p = CGFloat(phase.truncatingRemainder(dividingBy: Double(band)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if fill > 0 {
                    ZStack(alignment: .leading) {
                        tipGlow(p: p, fill: fill, blur: 38)
                        tipGlow(p: p, fill: fill, blur: 22)
                        tipGlow(p: p, fill: fill, blur: 11)
                        tipGlow(p: p, fill: fill, blur: 5)
                        coloredCapsule(p: p, fill: fill)
                    }
                }
            }
            .overlay {
                TimelineView(.animation) { ctx in
                    Color.clear.onChange(of: ctx.date) { _, newDate in
                        let dt = lastTick.map { newDate.timeIntervalSince($0) } ?? 0
                        lastTick = newDate
                        let speed = 16 + min(value, 1) * 44   // points / second
                        phase += speed * min(dt, 0.05)        // clamp dt so a pause can't jump it
                    }
                }
            }
        }
        .frame(height: 9)
        .animation(.easeInOut(duration: 0.35), value: value)
    }
}
