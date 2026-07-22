//
//  ProcessingView.swift
//  Sentient OS macOS
//
//  THE one on-device analysis takeover — a dim, OLED-friendly screen shared by BOTH the home
//  "Analyze Now" button and the dev "start on device" buttons. It drives the connector-agnostic
//  IterativeRun (synchronous generate() + GPU-wedge recovery — NO streaming) over the selected
//  connectors, optionally followed by the cloud Gmail leg, and shows a breathing sparkle, an
//  "Analyzing ___" cycling-gradient title, a glowing progress bar, live verdict counts, and a
//  "just processed" preview (thumbnail + verdict + title + summary). The real-mode cloud tail
//  (knowledge base → gift → proactive) is the living orb over the phase line, with codex's live
//  play-by-play as a fading three-line mono "thought" trail (liveThought — ProactiveCycle's
//  onLine hook).
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

    /// Dev Tools → "Resizable analysis window (demo)". While ON, the home's takeover loses its
    /// window min size (RootView reads this same key) and this footer's Stop control, so a website
    /// screen recording can frame just the analysis content. Home runs only — onboarding keeps
    /// Pause, dev prompt-pane runs keep Stop.
    static let resizableDemoKey = "dev.processing.resizableDemo"
    @AppStorage(ProcessingView.resizableDemoKey) private var resizableDemo = false

    /// Dev Tools → "Demo bar baseline". While `total` > 0, the bar RENDERS as if a big run were
    /// already mid-flight — `baseDone + real done` of `baseTotal`, with the kept/junk tags seeded
    /// proportionally so a 70% bar never sits over "0 kept · 0 junk" — letting a website screen
    /// recording open at "290 of 416" instead of 0. Display-only: the pipeline, marks, and
    /// lifetime counters are untouched.
    static let demoBaseDoneKey = "dev.processing.demoBaseDone"
    static let demoBaseTotalKey = "dev.processing.demoBaseTotal"
    @AppStorage(ProcessingView.demoBaseDoneKey) private var demoBaseDone = 0
    @AppStorage(ProcessingView.demoBaseTotalKey) private var demoBaseTotal = 0

    /// What the bar and count tags SHOW — real progress plus the demo baseline (when set).
    private var shownDone: Int { progress.done + (demoBaseTotal > 0 ? demoBaseDone : 0) }
    private var shownTotal: Int { demoBaseTotal > 0 ? demoBaseTotal : progress.total }
    private var shownSurvivors: Int { progress.survivors + (demoBaseTotal > 0 ? demoBaseDone * 58 / 100 : 0) }
    private var shownJunk: Int { progress.junk + (demoBaseTotal > 0 ? demoBaseDone * 36 / 100 : 0) }

    private enum UIState: Equatable { case loadingModel, processing, preparing, completed, failed(CycleFailure) }
    @State private var state: UIState = .loadingModel
    /// The failed screen's inline codex login (the "Codex isn't logged in" fix) — same shared
    /// engine Settings → Health drives; `loginStarted` scopes the auto-notice poll + auto-retry
    /// to a login WE opened from that screen.
    @State private var codex = CodexSetup.shared
    @State private var loginStarted = false
    @State private var prepStatus = "Preparing your suggestions…"
    /// The 10-minute patience flip for the cloud tail's bottom line (see `patienceLine`).
    @State private var patienceLong = false
    /// Phase-appropriate caption under the phase line (nil = none) — the proactive stages get
    /// the "things worth doing" promise; the knowledge-base/welcome phases speak for themselves.
    @State private var prepSubtext: String?
    /// The cloud tail's live "thoughts" — codex's reasoning/action lines (humanized by
    /// CodexCLI). `pending` updates freely as lines stream in; `trail` is what's actually on
    /// screen — the last three promoted lines, newest brightest — advanced at a readable
    /// cadence so bursts never strobe. Cleared per phase.
    @State private var thoughtPending: String?
    @State private var thoughtTrail: [Thought] = []
    @State private var thoughtCounter = 0
    /// One promoted thought line. The counter id keeps the trail's ForEach stable even when
    /// codex repeats itself minutes apart.
    private struct Thought: Identifiable, Equatable { let id: Int; let text: String }
    @State private var progress = RunProgress()
    @State private var started = false
    @State private var paused = false           // pausable only: frozen at the last item, awaiting Resume
    @State private var runTask: Task<RunProgress, Never>?
    /// Generation token — pause/stop/disappear bump it, making the (cancelled, still-draining)
    /// run() invocation STALE: it may finish whenever it likes, but it can no longer touch the
    /// UI or fall into the proactive tail. `paused` alone couldn't guarantee that: a quick
    /// pause→resume flipped it back to false before the old run drained, and the stale run
    /// then fired the knowledge-base build mid-read.
    @State private var runGeneration = 0
    /// Counts carried across pause→resume WITHIN this takeover. The resumed engine correctly
    /// plans only the REMAINING items (the marks are the truth), so its numbers restart — the
    /// display composes carried + live instead, and the bar picks up where it froze (6 of 50,
    /// never 1 of 45). In-session only: a relaunch shows the honest remaining count, exactly
    /// like the crash-recovery resume always has.
    @State private var carried = RunProgress()
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
                } else if state == .preparing {
                    patienceLine.padding(.bottom, 30)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await startIfNeeded() }
        .onDisappear { runGeneration += 1; runTask?.cancel() }   // stale: no tail after the view is gone
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
                GlowProgressBar(value: shownTotal > 0 ? Double(shownDone) / Double(shownTotal) : 0)
                HStack {
                    Text("\(shownDone) of \(shownTotal)").fontWeight(.bold).monospacedDigit()
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
            countTag(shownSurvivors, "kept", Theme.verdictColor(.survivor))
            countTag(shownJunk, "junk", Theme.verdictColor(.junk))
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
    /// proactive suggestions. The living orb (processing: alive, fast) over the phase line in the
    /// display voice, and — once codex starts thinking — its fading thought trail where the
    /// anonymous spinner used to sit.
    private var preparingView: some View {
        VStack(spacing: 18) {
            Orb(mode: .processing, size: 110)
            Text(prepStatus)
                .display(22)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let prepSubtext {
                Text(prepSubtext)
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
            liveThought.padding(.top, 6)
        }
    }

    /// The spinner until the first thought lands, then codex's live play-by-play as a fading
    /// trail: a tiny "THINKING" whisper (so a passing thought never reads as an app statement)
    /// over the last three promoted lines — newest brightest at the bottom, older thoughts
    /// dimming as they age out. Fixed-height slot so the layout never jumps; the pump task gives
    /// the stream a readable cadence.
    private var liveThought: some View {
        ZStack {
            if thoughtTrail.isEmpty {
                ProgressView().tint(.white.opacity(0.4))
                    .transition(.blurReplace)
            } else {
                VStack(spacing: 7) {
                    Text("THINKING").font(.caption2).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.3))
                    VStack(spacing: 5) {
                        ForEach(Array(thoughtTrail.enumerated()), id: \.element.id) { i, thought in
                            Text(thought.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(trailOpacity(age: thoughtTrail.count - 1 - i)))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 620)
                                .transition(.blurReplace)
                        }
                    }
                }
                .transition(.blurReplace)
            }
        }
        .frame(height: 84)
        .animation(.easeInOut(duration: 0.55), value: thoughtTrail)
        .task {
            // Promote the newest streamed line at a readable pace — raw JSONL arrives in bursts
            // that would strobe the transition into noise. Dedup is free: identical consecutive
            // lines (codex emits items as both .started and .completed) never extend the trail.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.4))
                if let next = thoughtPending, next != thoughtTrail.last?.text {
                    thoughtCounter += 1
                    thoughtTrail.append(Thought(id: thoughtCounter, text: next))
                    if thoughtTrail.count > 3 { thoughtTrail.removeFirst() }
                }
            }
        }
    }

    /// Trail brightness by age: the newest line reads, the older two linger as texture.
    private func trailOpacity(age: Int) -> Double { [0.52, 0.30, 0.16][min(age, 2)] }

    /// One streamed codex line → a clean single-line thought (nil = nothing showable). Shell
    /// commands and structured output are dropped outright — "$ /bin/zsh -lc …" and the research
    /// stage's closing JSON verdict ({"ready":…}) are machinery, not narration; reasoning,
    /// tool calls, and web searches make the cut. The humanized lines can carry markdown bold +
    /// multi-paragraph reasoning; the ticker wants one quiet line, so markup is stripped and
    /// paragraphs join with the house "·".
    private static func thought(_ raw: String) -> String? {
        guard !raw.hasPrefix("$ ") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return nil }
        let flat = raw.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return flat.isEmpty ? nil : flat
    }

    /// The expectation-setter under the cloud phases (knowledge base + proactive). The instruction
    /// is the headline — big, display-voice, impossible to miss (duration + app open, lid up;
    /// warmer once the wait is genuinely long — the 10-minute flip) — and the subtext is pure
    /// reassurance that the ask is first-run-only: the 3am runs wake a lid-shut, plugged-in Mac
    /// themselves (the root wake helper).
    private var patienceLine: some View {
        VStack(spacing: 12) {
            Text(patienceLong ? "STILL WORKING · ANOTHER 15 MINUTES OR SO" : "FIRST RUN · ABOUT 15 MINUTES")
                .font(.caption2).tracking(1.5)
                .foregroundStyle(.white.opacity(0.3))
            HStack(spacing: 9) {
                Image(systemName: "macbook")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Leave Sentient open and don't shut the lid of your Mac.")
                    .display(17)
                    .foregroundStyle(.white.opacity(0.92))
            }
            Text("Just this once. In the future, Sentient can update your knowledge base at 3 AM even if your Mac's asleep with its lid closed, as long as it's plugged in and Sentient's alive in your menu bar.")
                .font(.callout).foregroundStyle(.white.opacity(0.45))
                .lineSpacing(2)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 560)
        .task {
            try? await Task.sleep(for: .seconds(600))
            withAnimation(.easeInOut(duration: 0.6)) { patienceLong = true }
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
        // Auto-advance: 5s after completion the takeover dismisses itself, so a user who left
        // the analysis running returns to the home + cards (onboarding: the Constellation
        // finale), never a stale "complete" screen. The Done button stays for the impatient;
        // dev runs (showPrompt) keep manual Done so the final counts can be inspected. The
        // cancellation check keeps a manual Done from double-firing the finale.
        .task {
            guard !showPrompt else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { onDone() }
        }
    }

    private func failedView(_ failure: CycleFailure) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46))
                .foregroundStyle(.orange.opacity(0.85))
            Text(Self.failTitle(failure.kind)).font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(Self.failBody(failure)).font(.caption).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button("Back", action: onExitEarly ?? onDone).buttonStyle(.bordered).tint(.white)
                if failure.kind == .loggedOut {
                    Button("Retry") { Task { started = false; await startIfNeeded() } }
                        .buttonStyle(.bordered).tint(.white)
                    Button("Log in to Codex") { loginStarted = true; codex.startLogin(force: true) }
                        .buttonStyle(.borderedProminent).tint(.white)
                        .disabled(codex.loggingIn)
                } else {
                    Button("Retry") { Task { started = false; await startIfNeeded() } }
                        .buttonStyle(.borderedProminent).tint(.white)
                }
            }
            if loginStarted, codex.loggingIn {
                Text("A browser window opened. Finish signing in there; I'll retry on my own.")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        }
        // The browser-login auto-notice, same as Settings → Health and onboarding: while our
        // login is out, poll `codex login status` (the codex login process self-exits once
        // auth.json lands, no confirm button); the moment it reads logged-in, retry the cycle
        // on our own. Leaving the failed state cancels the poll.
        .task(id: loginStarted) {
            guard loginStarted else { return }
            while !Task.isCancelled, !codex.loggedIn {
                try? await Task.sleep(for: .seconds(1.5))
                await codex.refreshLoginStatus()
            }
            guard !Task.isCancelled, codex.loggedIn else { return }
            loginStarted = false
            // Unstructured on purpose: the retry flips state out of .failed, which tears THIS
            // task down — the run must survive that.
            Task { started = false; await startIfNeeded() }
        }
    }

    private static func failTitle(_ kind: OvernightCaution.Kind?) -> String {
        let locale = AppLanguage.resolvedLocale
        switch kind {
        case .loggedOut:      return String(localized: "Codex isn't logged in", locale: locale)
        case .usageLimit:     return String(localized: "We hit ChatGPT's usage limit", locale: locale)
        case .noInternet:     return String(localized: "No internet connection", locale: locale)
        case .inputTooLarge:  return String(localized: "This batch was too big to send", locale: locale)
        case nil:             return String(localized: "Processing failed", locale: locale)
        }
    }

    /// Classified failures get a friendly, actionable line (the raw detail is in the log +
    /// Sentry); unclassified ones show the step's own message, as before.
    private static func failBody(_ failure: CycleFailure) -> String {
        let locale = AppLanguage.resolvedLocale
        switch failure.kind {
        case .loggedOut:      return String(localized: "Sentient runs on your own ChatGPT account through codex, and that login has stopped working. Log back in and I'll pick up right where we stopped.", locale: locale)
        case .usageLimit:     return String(localized: "Your plan's window resets on its own. Everything so far is saved; retry in a while and I'll pick up right where we stopped.", locale: locale)
        case .noInternet:     return String(localized: "This step runs in the cloud. Once you're back online, hit Retry; everything so far is saved.", locale: locale)
        case .inputTooLarge:  return String(localized: "Sentient tried to send ChatGPT more than it accepts in one request. Your analysis is saved; if a retry hits this again, update Sentient OS and retry once more.", locale: locale)
        case nil:             return failure.message
        }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            // Demo mode drops the Stop control (home runs only) — the recording wants a clean frame.
            if !(resizableDemo && !pausable && !showPrompt) {
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

    /// Stop the run and return. Pointers advance per durable save, so re-running resumes. The
    /// generation bump keeps the draining run from starting the proactive tail behind the home.
    private func stop() {
        runGeneration += 1
        runTask?.cancel()
        onDone()
    }

    /// Pause (pausable/onboarding only): cancel the run and FREEZE in place — the card keeps
    /// showing the item it stopped on. Every item commits atomically, so nothing is lost; the
    /// generation bump makes the draining run stale (see `runGeneration`).
    private func pause() {
        paused = true
        runGeneration += 1
        runTask?.cancel()
    }

    /// Resume from the durable marks — the same restart the crash-safe design gives a 3am run.
    /// Waits for the cancelled run to finish draining FIRST, so two engines never overlap on
    /// the GPU and the stopped item's atomic commit lands before the fresh run reads the marks.
    /// The drained run's REAL counts (it may have committed the item it was on mid-pause) fold
    /// into `carried`, so the fresh run's numbers stack on top instead of restarting the bar.
    private func resume() {
        paused = false
        started = false
        Task {
            if let finished = await runTask?.value {
                carried.done             += finished.done
                carried.survivors        += finished.survivors
                carried.junk             += finished.junk
                carried.sensitive        += finished.sensitive
                carried.failed           += finished.failed
                carried.parseFailures    += finished.parseFailures
                carried.extractionFailed += finished.extractionFailed
                carried.totalSeconds     += finished.totalSeconds
            }
            await startIfNeeded()
        }
    }

    /// Overlay a live run on the carried base: the counters add, and the total re-anchors to
    /// carried.done + the live run's own total (which counts only what's LEFT) — so 5 done of
    /// 50 resumes as 5 of 50, not 0 of 45. The just-processed card always shows the live item.
    private static func composed(_ base: RunProgress, _ p: RunProgress) -> RunProgress {
        guard base.done > 0 else { return p }
        var c = p
        c.done             = base.done + p.done
        c.total            = base.done + p.total
        c.survivors        = base.survivors + p.survivors
        c.junk             = base.junk + p.junk
        c.sensitive        = base.sensitive + p.sensitive
        c.failed           = base.failed + p.failed
        c.parseFailures    = base.parseFailures + p.parseFailures
        c.extractionFailed = base.extractionFailed + p.extractionFailed
        c.totalSeconds     = base.totalSeconds + p.totalSeconds
        return c
    }

    private var percent: Int {
        shownTotal > 0 ? Int(Double(shownDone) / Double(shownTotal) * 100) : 0
    }

    // MARK: Run

    private func startIfNeeded() async {
        // !paused: the user re-paused while resume() was still draining the old run — they win.
        guard !started, !paused else { return }
        started = true
        await run()
    }

    /// One progress stream carries the on-device leg (IterativeRun) then the optional cloud Gmail
    /// leg — both feed the SAME bar/card. `.bufferingNewest(1)` is fine: every RunProgress is a
    /// complete, internally-consistent snapshot, so dropping intermediate frames never desyncs the
    /// prompt pane from the card.
    private func run() async {
        let generation = runGeneration   // this invocation's identity — stale once pause/stop bump it
        // Keep the display awake ONLY for the initial ingest — the long one. The home + 3am both run
        // `.auto`, so the honest "is this the first-ever descent" signal is the flag the 14h auto-enable
        // uses (nil until the first full cycle completes). `defer` releases on completion, failure, or
        // cancellation; the 3am path never reaches here (it never presents this view).
        if mode == .initial || OvernightScheduler.firstCycleCompletedAt == nil {
            awake.begin(reason: "Initial ingestion — keeping the screen on")
        }
        defer { awake.end() }

        // A resumed run keeps the frozen card + composed bar on screen while the engine reloads
        // (the reload is real, but "Loading on-device model" + a 0% bar read as progress lost).
        if carried.done == 0 {
            state = .loadingModel
            progress = RunProgress()
        }
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
            guard generation == runGeneration else { continue }   // stale: drain silently, freeze the card
            if state == .loadingModel { withAnimation { state = .processing } }
            progress = Self.composed(carried, p)
        }
        let final = await task.value
        // Paused, stopped, or superseded by a resume: this invocation is stale — the proactive
        // tail (knowledge base + cycle) must ONLY ever run at the end of a live, complete read.
        guard generation == runGeneration else { return }
        progress = Self.composed(carried, final)   // completion shows the whole session's counts

        // Real-mode Analyze Now: after the read, file into the knowledge base + run all three proactive
        // steps + wipe the summaries — surfacing each phase — then reveal the real cards on the home.
        if fullCycle {
            withAnimation { state = .preparing }
            thoughtPending = nil; thoughtTrail = []
            let failure = await ProactiveCycle.shared.run(progress: { phase in
                Task { @MainActor in
                    thoughtPending = nil; thoughtTrail = []          // a new phase, a fresh thought stream
                    switch phase {
                    case .knowledgeBase(let s):
                        prepStatus = s; prepSubtext = nil            // the phase line says it all
                    case .deciding:
                        prepStatus = "Creating proactive intelligence…"
                        prepSubtext = "Reading what's new, then preparing a few things worth doing."
                    case .researching(let n):
                        prepStatus = "Preparing \(n) suggestion\(n == 1 ? "" : "s")…"
                        prepSubtext = "Reading what's new, then preparing a few things worth doing."
                    case .done, .failed:
                        break
                    }
                }
            }, onLine: { line in
                Task { @MainActor in
                    if let t = Self.thought(line) { thoughtPending = t }
                }
            })
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
            Log("ProcessingView.gmail: ✗ \(ErrorLabel(error))")
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
            Log("ProcessingView.calendar: ✗ \(ErrorLabel(error))")
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

// MARK: - Previews

#if DEBUG
/// The cloud-tail "preparing" stage, frozen at a representative moment. The real view starts the
/// actual pipeline on appear, so this factory pre-sets `started` — `startIfNeeded()` no-ops and
/// the REAL layout renders with nothing running.
extension ProcessingView {
    static func preparingPreview() -> ProcessingView {
        var view = ProcessingView(modelPath: "", connectors: [], mode: .auto, fullCycle: true, onDone: {})
        view._started = State(initialValue: true)
        view._state = State(initialValue: .preparing)
        view._prepStatus = State(initialValue: "Creating your perfect knowledge base from everything we've analyzed…")
        view._thoughtPending = State(initialValue: "The corpus resolves into five durable domains: education, AI research, creative interests…")
        view._thoughtTrail = State(initialValue: [
            Thought(id: 1, text: "Reading the week's summaries for durable facts worth keeping long-term…"),
            Thought(id: 2, text: "Searched the web: \"YC S26 interview format\" — 6 results"),
            Thought(id: 3, text: "The corpus resolves into five durable domains: education, AI research, creative interests…"),
        ])
        view._thoughtCounter = State(initialValue: 3)
        return view
    }
}

#Preview("Preparing — cloud tail") {
    ProcessingView.preparingPreview()
        .frame(width: 1160, height: 780)
}
#endif

