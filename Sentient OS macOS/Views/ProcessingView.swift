//
//  ProcessingView.swift
//  Sentient OS macOS
//
//  THE one on-device analysis takeover — a dim, OLED-friendly screen shared by BOTH the home
//  "Analyze Now" button and the dev "start on device" buttons. It drives the connector-agnostic
//  IterativeRun (synchronous generate() + GPU-wedge recovery — NO streaming) over the selected
//  connectors, optionally followed by the cloud Gmail leg, and shows a breathing sparkle, an
//  "Analyzing ___" cycling-gradient title, a glowing progress bar, live verdict counts, and a
//  "just processed" preview (thumbnail + verdict + title + summary).
//
//  The ONLY dev/prod difference is `showPrompt`: the dev buttons pass `true`, which adds a left
//  pane showing the EXACT prompt fed to the model for the item currently on the card. Same engine,
//  same UI, everywhere — there is no separate dev processing view.
//

import SwiftUI

/// One thing the user picked to analyze — a file root or a database/chat source. `RunSource` is the
/// selection model (the dev picker + the home satellites speak it); `connectors(from:)` turns a
/// selection into the iterative-core connectors both run paths share.
enum RunSource: Hashable {
    case files(FileRoot)
    case whatsapp(chatJIDs: Set<String>)    // the opt-in chats to analyze
    case imessage(chatGUIDs: Set<String>)   // the opt-in chats to analyze
    case notes                              // all notes (newest-1000 cap inside the source)

    var label: String {
        switch self {
        case .files(let root): return root.label
        case .whatsapp:        return "WhatsApp"
        case .imessage:        return "iMessage"
        case .notes:           return "Apple Notes"
        }
    }

    /// Map a source selection to the iterative-core connectors. File roots collapse into ONE
    /// FilesConnector (it pages each root itself); chats/Notes each become their own connector.
    /// Shared by the home "Analyze Now" and the dev "start on device" buttons so both run the exact
    /// same engine over the same picks.
    static func connectors(from sources: [RunSource]) -> [any Connector] {
        let roots: [FileRoot] = sources.compactMap { if case .files(let r) = $0 { return r } else { return nil } }
        var connectors: [any Connector] = roots.isEmpty ? [] : [FilesConnector(roots: roots)]
        for s in sources {
            switch s {
            case .whatsapp(let jids):  connectors.append(WhatsAppConnector(chatJIDs: jids))
            case .imessage(let guids): connectors.append(iMessageConnector(chatGUIDs: guids))
            case .notes:               connectors.append(NotesConnector())
            case .files:               break   // rolled into FilesConnector(roots:)
            }
        }
        return connectors
    }
}

struct ProcessingView: View {
    let modelPath: String
    let connectors: [any Connector]   // the on-device sources to analyze (empty = cloud-only)
    let mode: IterativeRun.Mode       // home → .auto · dev INITIAL/ITERATIVE buttons → .initial/.iterative
    let runGmail: Bool                // append the cloud Gmail leg (shown in this same takeover)
    let runCalendar: Bool             // append the cloud Google Calendar leg (same takeover)
    let showPrompt: Bool              // dev: add the left-side prompt pane
    let fullCycle: Bool               // real-mode Analyze Now: after the read, run ProactiveCycle (KB + proactive + wipe)
    let pausable: Bool                // onboarding: the footer button is Pause/Resume (freeze in place) instead of Stop (exit)
    let onExitEarly: (() -> Void)?    // onboarding: where "Back" on a failure returns (nil = onDone, the home behavior)
    var onDone: () -> Void

    init(modelPath: String, connectors: [any Connector], mode: IterativeRun.Mode,
         runGmail: Bool = false, runCalendar: Bool = false, showPrompt: Bool = false,
         fullCycle: Bool = false, pausable: Bool = false, onExitEarly: (() -> Void)? = nil,
         onDone: @escaping () -> Void) {
        self.modelPath = modelPath; self.connectors = connectors; self.mode = mode
        self.runGmail = runGmail; self.runCalendar = runCalendar; self.showPrompt = showPrompt
        self.fullCycle = fullCycle; self.pausable = pausable; self.onExitEarly = onExitEarly
        self.onDone = onDone
    }

    private enum UIState: Equatable { case loadingModel, processing, preparing, completed, failed(String) }
    @State private var state: UIState = .loadingModel
    @State private var prepStatus = "Preparing your suggestions…"
    @State private var progress = RunProgress()
    @State private var started = false
    @State private var paused = false           // pausable only: frozen at the last item, awaiting Resume
    @State private var runTask: Task<RunProgress, Never>?
    @State private var awake = DisplayAwake()   // keeps the screen on during the long first ingest

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch state {
                    case .loadingModel:   loadingView
                    case .processing:     processingContent
                    case .preparing:      preparingView
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
        .onDisappear { runTask?.cancel() }
    }

    // MARK: States

    /// Cloud-only takeover (no on-device connectors): name the leg we're starting.
    private var cloudIcon: String { runGmail && !runCalendar ? "envelope" : (runCalendar && !runGmail ? "calendar" : "cloud") }
    private var cloudLabel: String {
        runGmail && !runCalendar ? "Connecting to Gmail"
            : (runCalendar && !runGmail ? "Connecting to Calendar" : "Connecting to the cloud")
    }

    private var loadingView: some View {
        VStack(spacing: 22) {
            Image(systemName: connectors.isEmpty ? cloudIcon : "cpu").font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.6)).symbolEffect(.pulse)
            Text(connectors.isEmpty ? cloudLabel : "Loading on-device model")
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            ProgressView().tint(.white.opacity(0.4))
        }
    }

    /// Production layout (centered). With `showPrompt`, the same layout sits in the RIGHT column and
    /// the exact prompt for the current item fills the LEFT — the one dev/prod difference.
    @ViewBuilder private var processingContent: some View {
        if showPrompt {
            HStack(spacing: 0) {
                promptPane
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                centerColumn.frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 12)
        } else {
            centerColumn
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles").font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.65)).symbolEffect(.breathe, options: .speed(0.7))

            AnalyzingTitle()

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

            if progress.lastPath != nil { justProcessed }   // files have a path; chat windows do too
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 30)
    }

    /// DEV-only: the EXACT prompt fed to the model for the item currently shown on the card.
    private var promptPane: some View {
        let prompt = progress.lastPrompt ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROMPT").font(.caption2.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("\(prompt.count) chars").font(.caption2).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.25))
            }
            ScrollView {
                Text(prompt.isEmpty ? "—" : prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(prompt.isEmpty ? 0.25 : 0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    private var countsLine: some View {
        HStack(spacing: 16) {
            countTag(progress.survivors, "kept", Theme.verdictColor(.survivor))
            countTag(progress.junk, "junk", Theme.verdictColor(.junk))
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
                    // Pills: sensitive (red) / junk (dim). Kept = none.
                    if verdict == .sensitive || verdict == .junk {
                        HStack(spacing: 6) {
                            if verdict == .sensitive { SensitivePill() }
                            else if verdict == .junk { JunkPill() }
                        }
                    }
                    if let title = progress.lastTitle {
                        Text(title).font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(verdict == .junk ? 0.5 : 1.0))
                            .frame(maxWidth: 340, alignment: .leading)
                    }
                    // Survivors carry a summary; junk/sensitive often don't — show a graceful
                    // placeholder so the round never looks blank.
                    let fallback = verdict == .sensitive ? "Held back: sensitive."
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

    /// Real-mode tail: the read is done; now we're filing into the knowledge base + preparing the
    /// proactive suggestions. A calm breathing sparkle with the live phase line.
    private var preparingView: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles").font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.65)).symbolEffect(.breathe, options: .speed(0.7))
            Text(prepStatus)
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Reading what's new, then preparing a few things worth doing.")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
            ProgressView().tint(.white.opacity(0.4)).padding(.top, 2)
        }
    }

    private var completedView: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58))
                .foregroundStyle(Theme.verdictColor(.survivor))
            VStack(spacing: 6) {
                Text("Analysis complete").display(28).foregroundStyle(.white)
                Text("\(progress.survivors) kept · \(progress.junk) junk · \(progress.failed) failed")
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
                Button("Back", action: onExitEarly ?? onDone).buttonStyle(.bordered).tint(.white)
                Button("Retry") { Task { started = false; await startIfNeeded() } }
                    .buttonStyle(.borderedProminent).tint(.white)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Button(action: pausable ? (paused ? resume : pause) : stop) {
                    Text(pausable ? (paused ? "Resume Analysis" : "Pause Analysis") : "Stop Analysis")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                Text(pausable ? (paused ? "Paused. It picks up exactly where it stopped." : "Pausing keeps your progress.")
                              : "Analysis can always resume later.")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            if showPrompt {
                // Dev: the current item being processed (replaces the trust footer).
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                    Text(progress.lastPath ?? "—").lineLimit(1).truncationMode(.middle).monospaced()
                }
                .font(.callout).foregroundStyle(.white.opacity(0.6))
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield.fill")
                    Text("Private by design. Your files never leave this Mac.")
                }
                .font(.callout).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// Stop the run and return. Pointers advance per durable save, so re-running resumes.
    private func stop() {
        runTask?.cancel()
        onDone()
    }

    /// Pause (pausable/onboarding only): cancel the run and FREEZE in place — the card keeps
    /// showing the item it stopped on. Every item commits atomically, so nothing is lost.
    private func pause() {
        paused = true
        runTask?.cancel()
    }

    /// Resume from the durable marks — the same restart the crash-safe design gives a 3am run.
    private func resume() {
        paused = false
        started = false
        Task { await startIfNeeded() }
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

    /// One progress stream carries the on-device leg (IterativeRun) then the optional cloud Gmail
    /// leg — both feed the SAME bar/card. `.bufferingNewest(1)` is fine: every RunProgress is a
    /// complete, internally-consistent snapshot, so dropping intermediate frames never desyncs the
    /// prompt pane from the card.
    private func run() async {
        // Keep the display awake ONLY for the initial ingest — the long one. The home + 3am both run
        // `.auto`, so the honest "is this the first-ever descent" signal is the flag the 18h auto-enable
        // uses (nil until the first full cycle completes). `defer` releases on completion, failure, or
        // cancellation; the 3am path never reaches here (it never presents this view).
        if mode == .initial || OvernightScheduler.firstCycleCompletedAt == nil {
            awake.begin(reason: "Initial ingestion — keeping the screen on")
        }
        defer { awake.end() }

        state = .loadingModel
        progress = RunProgress()
        let (stream, continuation) = AsyncStream.makeStream(
            of: RunProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task<RunProgress, Never> {
            defer { continuation.finish() }
            var p = RunProgress()
            if !connectors.isEmpty {
                p = await IterativeRun(modelPath: modelPath).run(connectors, mode: mode) { continuation.yield($0) }
            }
            if runGmail {
                p = await runGmailLeg(base: p) { continuation.yield($0) }
            }
            if runCalendar {
                p = await runCalendarLeg(base: p) { continuation.yield($0) }
            }
            return p
        }
        runTask = task
        for await p in stream {
            if state == .loadingModel { withAnimation { state = .processing } }
            if !paused { progress = p }   // paused → freeze the card at the item it stopped on
        }
        let final = await task.value
        if paused { return }              // wait for Resume; never fall through to the cycle/completed
        progress = final

        // Real-mode Analyze Now: after the read, file into the knowledge base + run all three proactive
        // steps + wipe the summaries — surfacing each phase — then reveal the real cards on the home.
        if fullCycle {
            withAnimation { state = .preparing }
            let failure = await ProactiveCycle.shared.run { phase in
                Task { @MainActor in
                    switch phase {
                    case .knowledgeBase(let s): prepStatus = s
                    case .deciding:             prepStatus = "Deciding what's worth doing…"
                    case .researching(let n):   prepStatus = "Preparing \(n) suggestion\(n == 1 ? "" : "s")…"
                    case .done, .failed:        break
                    }
                }
            }
            if let failure { withAnimation { state = .failed(failure) }; return }
        }
        withAnimation { state = .completed }
    }

    /// Cloud Gmail leg — each weekly window maps onto the SAME bar/card: its prompt → the prompt
    /// pane, its summary → the just-processed card, the windows → the bar (extended past `base`, the
    /// device leg's final counts).
    private func runGmailLeg(base: RunProgress,
                             yield: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        let box = ProgressBox(base)
        let baseTotal = base.total, baseDone = base.done, baseKept = base.survivors, baseJunk = base.junk
        let onProgress: @Sendable (GmailConnect.Progress) -> Void = { ev in
            switch ev {
            case let .windowStart(total, label, prompt):
                // All windows start together (parallel); the bar advances only as they finish below.
                var p = box.value
                p.total = baseTotal + total
                p.lastPrompt = prompt
                p.lastPath = "Gmail · \(label)"
                box.value = p
                yield(p)
            case let .windowDone(total, label, summary, threads, completed, keptSoFar):
                var p = box.value
                p.total       = baseTotal + total
                p.done        = baseDone + completed
                p.survivors   = baseKept + keptSoFar
                p.junk        = baseJunk + (completed - keptSoFar)   // a window with nothing notable
                p.lastTitle   = "Email · \(label)"
                p.lastSummary = summary
                p.lastVerdict = summary == nil ? .junk : .survivor
                p.lastFilePath = nil
                p.lastPath    = "Gmail · \(label)" + (threads > 0 ? " · \(threads) threads" : "")
                p.lastSeconds = nil
                box.value = p
                yield(p)
            }
        }
        do {
            // Only the explicit force-initial mode does a full re-read; `.auto` and `.iterative` both
            // use runIterative — which itself falls back to a full initial read when Gmail has no mark
            // yet. (Same auto behavior the scheduler relies on; keeps every entry point in agreement.)
            _ = mode == .initial ? try await GmailConnect.runInitial(onProgress: onProgress)
                                 : try await GmailConnect.runIterative(onProgress: onProgress)
        } catch {
            var p = box.value
            p.lastTitle = "Gmail failed"
            p.lastSummary = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            p.lastVerdict = .junk
            p.lastFilePath = nil
            box.value = p
            yield(p)
            Log("ProcessingView.gmail: ✗ \(error)")
        }
        return box.value
    }

    /// Cloud Google Calendar leg — twin to the Gmail leg: each date window (a month, or the iterative
    /// since-mark window) maps onto the SAME bar/card, extended past `base` (the prior legs' counts).
    private func runCalendarLeg(base: RunProgress,
                                yield: @Sendable @escaping (RunProgress) -> Void) async -> RunProgress {
        let box = ProgressBox(base)
        let baseTotal = base.total, baseDone = base.done, baseKept = base.survivors, baseJunk = base.junk
        let onProgress: @Sendable (CalendarConnect.Progress) -> Void = { ev in
            switch ev {
            case let .windowStart(step, total, label, prompt):
                var p = box.value
                p.total = baseTotal + total
                p.done  = baseDone + (step - 1)
                p.lastPrompt = prompt
                p.lastPath = "Calendar · \(label)"
                box.value = p
                yield(p)
            case let .windowDone(step, total, label, summary, events, keptSoFar):
                var p = box.value
                p.total       = baseTotal + total
                p.done        = baseDone + step
                p.survivors   = baseKept + keptSoFar
                p.junk        = baseJunk + (step - keptSoFar)   // a window with nothing notable
                p.lastTitle   = "Calendar · \(label)"
                p.lastSummary = summary
                p.lastVerdict = summary == nil ? .junk : .survivor
                p.lastFilePath = nil
                p.lastPath    = "Calendar · \(label)" + (events > 0 ? " · \(events) events" : "")
                p.lastSeconds = nil
                box.value = p
                yield(p)
            }
        }
        do {
            // Force-initial only on `.initial`; `.auto`/`.iterative` → runIterative (which falls back
            // to a full initial read when Calendar has no mark yet). Matches the Gmail leg + scheduler.
            _ = mode == .initial ? try await CalendarConnect.runInitial(onProgress: onProgress)
                                 : try await CalendarConnect.runIterative(onProgress: onProgress)
        } catch {
            var p = box.value
            p.lastTitle = "Calendar failed"
            p.lastSummary = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            p.lastVerdict = .junk
            p.lastFilePath = nil
            box.value = p
            yield(p)
            Log("ProcessingView.calendar: ✗ \(error)")
        }
        return box.value
    }
}

/// Thread-safe holder so the Gmail leg's `@Sendable` progress callback can accumulate onto the
/// device leg's final counts and hand the final value back (mirrors CodexCLI's PipeDrain pattern).
private nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var p: RunProgress
    init(_ p: RunProgress) { self.p = p }
    var value: RunProgress {
        get { lock.lock(); defer { lock.unlock() }; return p }
        set { lock.lock(); p = newValue; lock.unlock() }
    }
}

// MARK: - Analyzing title

/// "Analyzing ___" with the right-hand word cycling. Isolated in its OWN view (with its own state +
/// timer) so the cycle runs at a steady pace, immune to the parent's per-file re-renders.
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
        Color(red: 0.29, green: 0.87, blue: 0.50),  // green (Ink.green)
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

    /// The fill-width capsule of the scrolling color gradient — rendered crisp on top and blurred
    /// behind (= the glow). Same gradient/offset, so the glow flows with the colors.
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
    /// tip (fading out toward the start) BEFORE blurring, so it blooms freely but only at the
    /// leading edge — a long bar never glows end-to-end.
    @ViewBuilder
    private func tipGlow(p: CGFloat, fill: CGFloat, blur: CGFloat) -> some View {
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
                        tipGlow(p: p, fill: fill, blur: 38)
                        tipGlow(p: p, fill: fill, blur: 22)
                        tipGlow(p: p, fill: fill, blur: 11)
                        tipGlow(p: p, fill: fill, blur: 5)
                        coloredCapsule(p: p, fill: fill)
                    }
                }
            }
            .overlay {
                // Drive the scroll: phase ACCUMULATES (speed × dt) so changing speed never jumps the
                // colors. Speed ∝ fill width → tiny pill = slow, gentle color fade.
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
