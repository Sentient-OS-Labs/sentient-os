//
//  ProcessingView.swift
//  Sentient OS macOS
//
//  The overnight-analysis screen — a dim, OLED-friendly takeover (ported in spirit from the iOS
//  ProcessingView). Loads the on-device model, runs the Files pipeline over ~/Downloads, and
//  shows a breathing sparkle, an "Analyzing ___" cycling-gradient title, a progress bar, live
//  verdict counts, and a "just processed" preview (real file thumbnail + verdict + summary).
//  Owns its Engine for the run and releases it on completion.
//

import SwiftUI

/// One thing the user picked to analyze — a file folder or a database source. Each runs as its
/// own pass through the pipeline. (iMessage / Notes slot in here as they land.)
enum RunSource: Hashable {
    case files(FileRoot)
    case whatsapp(chatJIDs: Set<String>)   // the opt-in chats to analyze

    var label: String {
        switch self {
        case .files(let root): return root.label
        case .whatsapp:        return "WhatsApp"
        }
    }
}

struct ProcessingView: View {
    let store: Store
    let modelPath: String
    let sources: [RunSource]   // one pass per source, in order
    let limit: Int?
    var onDone: () -> Void

    private enum UIState: Equatable { case loadingModel, processing, completed, failed(String) }
    @State private var state: UIState = .loadingModel
    @State private var progress = PipelineProgress()   // live bar for the CURRENT folder's pass (resets per folder)
    @State private var totals = PipelineProgress()     // accumulated across all folders (for the final summary)
    @State private var currentRootLabel = ""
    @State private var currentRootIndex = 0
    @State private var rootCount = 0
    @State private var stopped = false
    @State private var engine: Engine?
    @State private var started = false
    @State private var pipelineTask: Task<PipelineProgress, Error>?

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
        .onDisappear { let e = engine; Task { await e?.unload() } }
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

            AnalyzingTitle()

            if !currentRootLabel.isEmpty {
                Text(rootCount > 1
                     ? "\(currentRootLabel) · \(currentRootIndex + 1) of \(rootCount)"
                     : currentRootLabel)
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: currentRootLabel)
            }

            VStack(spacing: 10) {
                GlowProgressBar(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
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
                    // Survivors carry a summary; junk/sensitive often don't — show a graceful
                    // placeholder so the round never looks blank (the documents bug never hit this
                    // because files always had a thumbnail + a summary).
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

    /// Stop the run and return home. Progress is saved per file, so re-running resumes (dedup).
    /// `stopped` also halts the outer per-folder loop so it doesn't roll on to the next folder.
    private func stop() {
        stopped = true
        pipelineTask?.cancel()
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
        state = .loadingModel
        stopped = false
        totals = PipelineProgress()
        guard !sources.isEmpty else { state = .failed("No sources selected to analyze."); return }
        do {
            // Chat windows are big (and prompt scaffolding is sizeable); size the KV cache with
            // comfortable headroom so a window + prompt can never overflow (we have the RAM).
            let needsBigContext = sources.contains { if case .whatsapp = $0 { return true }; return false }
            let engine = Engine(modelPath: modelPath, maxNumTokens: needsBigContext ? 16384 : 4096)
            try await engine.load()
            self.engine = engine
            withAnimation { state = .processing }

            let pipeline = Pipeline(engine: engine, store: store)
            rootCount = sources.count

            // One pass per source (its own progress bar); verdict counts accumulate for the summary.
            for (idx, src) in sources.enumerated() {
                if stopped || Task.isCancelled { break }
                withAnimation { currentRootIndex = idx; currentRootLabel = src.label }
                progress = PipelineProgress()   // reset the live bar for this pass

                switch src {
                case .files(let root):
                    guard let url = root.url else { continue }
                    try await runPass(FilesSource(root: url, label: root.label), pipeline: pipeline)
                case .whatsapp(let jids):
                    try await runPass(WhatsAppSource(chatJIDs: jids), pipeline: pipeline)
                }
            }

            await engine.unload()
            self.engine = nil
            progress = totals                    // the completed view summarizes ALL sources
            withAnimation { state = .completed }
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Run one source as a pass, streaming its progress into the live bar and folding its final
    /// counts into the grand totals. Generic so the Pipeline stays a single concrete-typed call.
    private func runPass<S: DataSource & Sendable>(_ source: S, pipeline: Pipeline) async throws {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PipelineProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { continuation.finish() }
            return try await pipeline.run(source: source, currentDate: Date(),
                                          limit: limit) { continuation.yield($0) }
        }
        pipelineTask = task
        for await p in stream { progress = p }   // scoped .animation(value:) modifiers drive the morphs
        accumulate(try await task.value)
    }

    /// Fold one folder's final progress into the running grand totals (shown on completion).
    private func accumulate(_ p: PipelineProgress) {
        totals.total += p.total
        totals.done += p.done
        totals.survivors += p.survivors
        totals.junk += p.junk
        totals.sensitive += p.sensitive
        totals.reminders += p.reminders
        totals.failed += p.failed
    }
}

// MARK: - Analyzing title

/// "Analyzing ___" with the right-hand word cycling every 2s. Isolated in its OWN view (with its
/// own state + timer) so the cycle runs exactly once at a steady pace, immune to the parent's
/// per-file re-renders.
private struct AnalyzingTitle: View {
    private let words = ["Files", "Notes", "Messages", "WhatsApp", "Everything."]
    @State private var index = 0

    var body: some View {
        HStack(spacing: 7) {
            Text("Analyzing").font(.title2.weight(.semibold)).foregroundStyle(.white)
            // Invisible widest-word anchor reserves constant width so "Analyzing" never shifts.
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

// MARK: - Glowing progress bar

/// A multicolor signature-gradient fill with a flowing sheen sweeping rightward + a soft glow.
private struct GlowProgressBar: View {
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

    /// Stops tiled twice with explicit locations → the gradient is periodic over `band` points,
    /// so scrolling it by `band` is seamless.
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

    /// The fill-width capsule of the scrolling color gradient — rendered crisp on top and
    /// blurred behind (= the glow). Same gradient/offset, so the glow flows with the colors.
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

    /// A tip-concentrated glow: the colored capsule masked to a fixed-width region at the leading
    /// tip (fading out toward the start) BEFORE blurring, so it blooms freely (keeps its vertical
    /// halo) but only at the leading edge — a long bar never glows end-to-end.
    @ViewBuilder
    private func tipGlow(p: CGFloat, fill: CGFloat, blur: CGFloat) -> some View {
        // PROGRESSIVE front-weighting: the trailing edge dims more as the bar grows. value→0 →
        // ~uniform (full glow, like before); larger value → the glow ramps to the front only.
        let t = min(1.0, value * 3.0)   // how strongly the back is dimmed (tune the 3.0)
        coloredCapsule(p: p, fill: fill)
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1 - t), location: 0.0),   // trailing (start)
                    .init(color: .white, location: 1.0),                  // leading tip — always full
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
                        // Glow gently weighted toward the leading tip — subtle on long bars,
                        // full glow when short (same as before).
                        tipGlow(p: p, fill: fill, blur: 38)
                        tipGlow(p: p, fill: fill, blur: 22)
                        tipGlow(p: p, fill: fill, blur: 11)
                        tipGlow(p: p, fill: fill, blur: 5)
                        coloredCapsule(p: p, fill: fill)
                    }
                }
            }
            .overlay {
                // Drive the scroll: phase ACCUMULATES (speed × dt) so changing speed never jumps
                // the colors. Speed ∝ fill width → tiny pill = slow, gentle color fade.
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
