//
//  DevProcessingView.swift
//  Sentient OS macOS
//
//  DEV-ONLY copy of the on-device processing takeover, dedicated to the iterative system's
//  "start on device" buttons in DevToolsView. It is a deliberate FORK of ProcessingView so the
//  dev processing UI can be iterated on freely without touching the production home "Analyze Now"
//  screen (ProcessingView).
//
//  The dev "lab" layout: the REAL status header on top (same glow bar + counts as production),
//  then two live panes below — LEFT = the EXACT prompt fed to the model for the current item;
//  RIGHT = the model's raw response STREAMING in token by token, with the production just-processed
//  card (parsed title/summary/verdict) shown beneath it for the last finished item (both modes).
//  Streaming is DEV-ONLY: it is driven by an IterativeRun.DevObserver that ONLY this view passes
//  (the product path never streams — see IterativeRun / Engine.generateStream).
//
//  Reuses the shared FileThumbnail + verdict pills (Theme.swift); carries its OWN copies of the
//  title + glow-bar helpers (DevAnalyzingTitle / DevGlowProgressBar) because the ProcessingView
//  originals are file-private.
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

    /// One ordered event off the run — progress for the header, start/token for the panes, itemDone to
    /// swap the placeholder for the real card. A single stream keeps them in program order.
    private enum RunEvent {
        case progress(PipelineProgress)
        case start(prompt: String, displayPath: String?, filePath: String?)
        case token(String)
        case itemDone
    }

    @State private var state: UIState = .loadingModel
    @State private var progress = PipelineProgress()
    @State private var currentPrompt = ""    // LEFT pane — exact prompt for the current item
    @State private var currentDisplayPath: String?    // footer — current item being processed
    @State private var currentFilePath: String?       // placeholder card thumbnail (current item)
    @State private var liveResponse = ""     // RIGHT pane — raw response, streamed token by token
    @State private var responseComplete = false   // false while streaming (placeholder), true → summary card
    @State private var pauseBetweenItems = true   // dev checkbox — sleep 8s after each item (on by default)
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
        VStack(spacing: 16) {
            statusHeader
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            promptResponsePanes
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 18)
    }

    /// The REAL on-device status — same glow bar + verdict counts as production ("real status!").
    private var statusHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.65)).symbolEffect(.breathe, options: .speed(0.7))
                DevAnalyzingTitle()
            }
            VStack(spacing: 8) {
                DevGlowProgressBar(value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
                HStack {
                    Text("\(progress.done) of \(progress.total)").fontWeight(.bold).monospacedDigit()
                    Spacer()
                    Text("\(percent)%").monospacedDigit()
                }
                .font(.subheadline).foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 360)
            countsLine
        }
        .padding(.vertical, 14).padding(.horizontal, 22)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }

    /// LEFT: the exact prompt for the current item. RIGHT: the model's raw streaming response, plus
    /// the production "JUST PROCESSED" card (parsed title/summary/verdict) for the last item done.
    private var promptResponsePanes: some View {
        HStack(spacing: 0) {
            devPane(title: "PROMPT", text: currentPrompt, autoScroll: false)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
            responseColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    /// The PROMPT column — header + the scrollable monospace prompt.
    private func devPane(title: String, text: String, autoScroll: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            paneHeader(title, chars: text.count)
            monoScroll(text: text, autoScroll: autoScroll)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The RESPONSE column — raw streaming response on top, the parsed "just processed" card below.
    private var responseColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            paneHeader("RESPONSE TO PROMPT", chars: liveResponse.count)
            monoScroll(text: liveResponse, autoScroll: true)
            if !currentPrompt.isEmpty {   // a run is underway — card section present in BOTH modes
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                // While the response streams → placeholder for the CURRENT item (never the previous
                // item's summary). On completion → the real summary, in sync with the finished JSON.
                if responseComplete { justProcessed } else { analyzingPlaceholder }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func paneHeader(_ title: String, chars: Int) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.semibold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text("\(chars) chars").font(.caption2).monospacedDigit()
                .foregroundStyle(.white.opacity(0.25))
        }
    }

    /// A scrollable monospace text body. `autoScroll` pins it to the bottom as text streams in.
    private func monoScroll(text: String, autoScroll: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(text.isEmpty ? 0.25 : 0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("bottom")
            }
            .onChange(of: text) {
                guard autoScroll else { return }
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown while the CURRENT item's response is still streaming — the current file's thumbnail with
    /// an "Analyzing…" note, so the previous item's summary is never displayed mid-stream.
    private var analyzingPlaceholder: some View {
        HStack(alignment: .top, spacing: 14) {
            FileThumbnail(path: currentFilePath, size: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text("Analyzing…").font(.subheadline.weight(.bold)).foregroundStyle(.white.opacity(0.5))
                Text("Waiting for the model to finish this item.")
                    .font(.subheadline).italic().foregroundStyle(.white.opacity(0.3))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The production just-processed card — thumbnail + verdict pill + bold title + summary + path,
    /// for the most-recently-completed item (same data + look as the real ProcessingView). Always
    /// visible in both pause + no-pause modes; updates at each item completion (with the full JSON).
    private var justProcessed: some View {
        HStack(alignment: .top, spacing: 14) {
            FileThumbnail(path: progress.lastFilePath, size: 60)
                .id(progress.done).transition(.blurReplace)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Survivors carry a summary; junk/sensitive often don't — show a graceful placeholder.
                let fallback = verdict == .sensitive ? "Held back — sensitive."
                             : verdict == .junk ? "Nothing worth keeping here." : ""
                let body = progress.lastSummary ?? fallback
                if !body.isEmpty {
                    Text(body).font(.subheadline)
                        .italic(progress.lastSummary == nil)
                        .foregroundStyle(.white.opacity(verdict == .survivor ? 0.85 : 0.32))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .blur(radius: verdict == .sensitive ? 6 : 0)   // redact sensitive content
                }
                if let path = progress.lastPath {
                    Text(path).font(.caption).foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                }
            }
            .id(progress.done).transition(.blurReplace)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.4), value: progress.done)
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
            Toggle(isOn: $pauseBetweenItems) {
                Text("Pause 8s after each response (dev)").font(.caption)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(.white.opacity(0.7))

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
            // Dev: the current item being processed (replaces the production trust footer).
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                Text(currentDisplayPath ?? "—")
                    .lineLimit(1).truncationMode(.middle).monospaced()
            }
            .font(.callout).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Stop the run and return home. The cycle's pointers advance per durable save, so re-running resumes.
    private func stop() {
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
        state = .loadingModel
        currentPrompt = ""; liveResponse = ""; responseComplete = false

        // One unbounded ordered stream carries progress + the dev start/token/itemDone events (tokens
        // must never be dropped, so NOT bufferingNewest). The DevObserver is what flips on streaming —
        // passing it makes IterativeRun use Engine.generateStream; production never passes one.
        let (stream, continuation) = AsyncStream.makeStream(of: RunEvent.self, bufferingPolicy: .unbounded)
        let task = Task<PipelineProgress, Never> {
            defer { continuation.finish() }
            let runner = IterativeRun(modelPath: modelPath)
            let dev = IterativeRun.DevObserver(
                onItemStart: { continuation.yield(.start(prompt: $0, displayPath: $1, filePath: $2)) },
                onToken:     { continuation.yield(.token($0)) },
                onItemDone:  { continuation.yield(.itemDone) },
                afterItem: {
                    // Read the checkbox LIVE on the main actor; sleep so the response stays readable.
                    // Cancellation-aware (Stop during the pause throws → swallowed → loop exits).
                    let shouldPause = await MainActor.run { pauseBetweenItems }
                    if shouldPause { try? await Task.sleep(for: .seconds(8)) }
                })
            return mode == .initial
                ? await runner.runInitial(connectors, dev: dev) { continuation.yield(.progress($0)) }
                : await runner.runIterative(connectors, dev: dev) { continuation.yield(.progress($0)) }
        }
        iterativeTask = task
        for await ev in stream {
            switch ev {
            case .progress(let p):
                if state == .loadingModel { withAnimation { state = .processing } }
                progress = p
            case .start(let prompt, let dp, let fp):
                // New item → show it immediately (no lag), reset the response, back to placeholder.
                currentPrompt = prompt; currentDisplayPath = dp; currentFilePath = fp
                liveResponse = ""; responseComplete = false
            case .token(let t):
                liveResponse += t
            case .itemDone:
                withAnimation { responseComplete = true }   // placeholder → real summary card
            }
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
