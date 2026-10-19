// Passive presentation of app-owned analysis: progress, waiting, pause/resume and retry.
// Production windows never start work on appearance or cancel it on disappearance.
// Developer callers can submit a selected request through the same coordinator.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI

struct ProcessingView: View {
    private let request: ProcessingRequest?
    let showPrompt: Bool
    let onExitEarly: (() -> Void)?
    var onDone: () -> Void
    @State private var session: ProcessingCoordinator
    private var connectors: [any Connector] { (session.activeRequest ?? request)?.connectors ?? [] }
    private var runGmail: Bool { (session.activeRequest ?? request)?.runGmail ?? false }
    private var runCalendar: Bool { (session.activeRequest ?? request)?.runCalendar ?? false }

    /// Production windows only observe. Creating or closing one never starts or stops work.
    init(onDone: @escaping () -> Void = {}) {
        self.init(session: .shared, onDone: onDone)
    }

    private init(session: ProcessingCoordinator, onDone: @escaping () -> Void = {}) {
        request = nil; showPrompt = false; onExitEarly = nil; self.onDone = onDone
        _session = State(initialValue: session)
    }

    /// Developer callers retain their selected fixture/source configuration, using the same owner.
    init(modelPath: String, connectors: [any Connector], mode: IterativeRun.Mode,
         runGmail: Bool = false, runCalendar: Bool = false, mcpSlugs: [String] = [],
         showPrompt: Bool = false, fullCycle: Bool = false,
         onExitEarly: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        request = ProcessingRequest(modelPath: modelPath, connectors: connectors, mode: mode,
            runGmail: runGmail, runCalendar: runCalendar, mcpSlugs: mcpSlugs, fullCycle: fullCycle)
        self.showPrompt = showPrompt; self.onExitEarly = onExitEarly; self.onDone = onDone
        _session = State(initialValue: .shared)
    }

    /// Developer recordings can resize the production analysis window freely.
    static let resizableDemoKey = "dev.processing.resizableDemo"

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

    private var state: ProcessingCoordinator.State { session.state }
    private var progress: RunProgress { session.progress }
    private var prepStatus: String { session.prepStatus }
    private var prepSubtext: String? { session.prepSubtext }
    private var updatingExistingKnowledge: Bool { session.updatingExistingKnowledge }
    private var paused: Bool { state == .paused }
    /// The failed screen's inline engine login (the "isn't logged in" fix) — the same shared
    /// setup engines Settings drives, picked by the live backend; `loginStarted` scopes the
    /// auto-notice poll + auto-retry to a login WE opened from that screen.
    @State private var codex = CodexSetup.shared
    @State private var claude = ClaudeSetup.shared
    @State private var loginStarted = false
    /// The 10-minute patience flip for the cloud tail's bottom line (see `patienceLine`).
    @State private var patienceLong = false
    /// Phase-appropriate caption under the phase line (nil = none) — the proactive stages get
    /// the "things worth doing" promise; the knowledge-base/welcome phases speak for themselves.
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
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch state {
                    case .idle, .scheduled, .waiting, .paused, .stopping: waitingView
                    case .loadingModel:   loadingView
                    case .processing:     processingContent
                    case .preparing:      preparingView
                    case .completed:      completedView
                    case .failed(let e):  failedView(kind: e.kind, message: e.message)
                    case .diskFull:       failedView(kind: .diskFull, message: "")
                    }
                }
                Spacer(minLength: 0)
                if !progress.sourceReadFailures.isEmpty {
                    sourceFailuresView.padding(.bottom, 20)
                }
                if session.isBusy || paused || isWaiting {
                    footer.padding(.bottom, 30)
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            if let request, session === ProcessingCoordinator.shared { session.requestNow(request, trigger: .developer) }
        }
        .onChange(of: session.thought) { _, line in
            if let line, let text = Self.thought(line) { thoughtPending = text }
        }
        .onChange(of: session.prepStatus) { _, _ in thoughtPending = nil; thoughtTrail = [] }
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

            Text(progress.sourceRead.map { "Analyzing \($0.name)" } ?? "Analyzing your sources")
                .display(26).foregroundStyle(.white)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                GlowProgressBar(value: shownTotal > 0 ? Double(shownDone) / Double(shownTotal) : 0)
                HStack {
                    Text("\(shownDone) of \(shownTotal)")
                        .fontWeight(.bold).monospacedDigit()
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
            if progress.quietReads > 0 { countTag(progress.quietReads, "quiet", Theme.secondary) }
            if progress.failed > 0 { countTag(progress.failed, "failed", Theme.Ink.amber) }
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
            Text(progress.sourceRead?.caption ?? "JUST PROCESSED")
                .font(.caption2).tracking(1.5).foregroundStyle(.white.opacity(0.3))
            HStack(alignment: .top, spacing: 16) {
                if let source = progress.sourceRead {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.04))
                        if source.status == .reading {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 25)).foregroundStyle(Theme.secondary)
                                .symbolEffect(.pulse)
                        } else {
                            Image(systemName: source.status == .failed ? "exclamationmark.triangle" : "text.book.closed")
                                .font(.system(size: 25))
                                .foregroundStyle(source.status == .failed ? Theme.Ink.amber : Theme.secondary)
                        }
                    }.frame(width: 66, height: 66)
                } else {
                    FileThumbnail(path: progress.lastFilePath, size: 66)
                        .id(progress.done)
                        .transition(.blurReplace)
                }
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
                            .foregroundStyle(.white.opacity(verdict == .survivor || progress.sourceRead != nil ? 0.85 : 0.32))
                            .lineLimit(3).frame(maxWidth: 340, alignment: .leading)
                            // Redact source content, but keep the app-authored explanation readable.
                            .blur(radius: verdict == .sensitive && progress.lastSummary != nil ? 6 : 0)
                    }
                    if let path = progress.lastPath {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let date = progress.lastItemDate {
                                Spacer(minLength: 0)
                                Text(date, format: .dateTime.month(.abbreviated).day().year())
                                    .fixedSize()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.3))
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
            patienceLine.padding(.top, 12)
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
            Text(patienceLong ? "STILL WORKING · KEEP SENTIENT OPEN"
                 : (updatingExistingKnowledge ? "UPDATING YOUR KNOWLEDGE" : "BUILDING YOUR KNOWLEDGE"))
                .font(.caption2).tracking(1.5)
                .foregroundStyle(.white.opacity(0.3))
            HStack(spacing: 9) {
                Image(systemName: "macbook")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Keep Sentient open in your menu bar.")
                    .display(17)
                    .foregroundStyle(.white.opacity(0.92))
            }
            Text(updatingExistingKnowledge
                 ? "Your existing knowledge stays in place while this update is prepared. Large libraries can take several passes; completed work is kept."
                 : "The first analysis can take several passes for a large library. Completed work is kept, and future updates can run overnight while Sentient stays open in your menu bar.")
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

    private var sourceFailuresView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCES TO RETRY").font(.caption2).tracking(1.5).foregroundStyle(Theme.Ink.amber)
            ForEach(progress.sourceReadFailures.keys.sorted(), id: \.self) { name in
                Text("\(name): \(progress.sourceReadFailures[name] ?? "The read did not finish.")")
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            Text("Run analysis again to retry these sources.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var needsAnotherPass: Bool {
        session.record.notice != nil || !progress.sourceReadFailures.isEmpty
            || progress.mailIncomplete || progress.mailDeferred > 0
    }

    private var completedView: some View {
        VStack(spacing: 22) {
            Image(systemName: needsAnotherPass ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(needsAnotherPass ? Theme.Ink.amber : Theme.verdictColor(.survivor))
            VStack(spacing: 6) {
                Text(!progress.sourceReadFailures.isEmpty ? "Some sources need another try"
                    : needsAnotherPass ? "Analysis saved" : "Analysis complete")
                    .display(28).foregroundStyle(.white).multilineTextAlignment(.center)
                if progress.total > 0 || progress.done > 0 {
                    Text("\(progress.survivors) kept · \(progress.junk) junk · \(progress.quietReads) quiet · \(progress.failed) failed")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                }
                if progress.mailIncomplete || progress.mailDeferred > 0 {
                    Text(UserDefaults.standard.string(forKey: AppleMailHealth.key) ?? "Apple Mail will resume during the next analysis.")
                        .font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: 430)
                }
                if let notice = session.record.notice {
                    Text(notice).font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: 430)
                }
            }
            if progress.sourceRead?.status == .summarized || progress.sourceRead?.status == .quiet {
                justProcessed
            }
            Button(action: onDone) {
                Text("Done").font(.headline).foregroundStyle(.black)
                    .frame(width: 200, height: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain).padding(.top, 6)
            if needsAnotherPass {
                Button("Retry analysis") { session.retry() }.buttonStyle(BackButtonStyle())
            }
        }

    }

    /// The failed screen for BOTH failure kinds the takeover can end in: the cloud tail's
    /// classified `CycleFailure` (kind + its own message) and the on-device read's disk-full stop
    /// (kind `.diskFull`, no message of its own). Classified kinds get a friendly title/body and,
    /// where there's something to click, the fix next to Retry.
    private func failedView(kind: OvernightCaution.Kind?, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46))
                .foregroundStyle(.orange.opacity(0.85))
            Text(Self.failTitle(kind)).font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(Self.failBody(kind: kind, message: message)).font(.caption).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 12) {
                Button(action: onExitEarly ?? onDone) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(BackButtonStyle())
                if kind == .loggedOut {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.bordered).tint(.white)
                    if ModelBackend.current == .claude {
                        Button("Sign in to Claude") { loginStarted = true; claude.startLogin(force: true) }
                            .buttonStyle(.borderedProminent).tint(.white)
                            .disabled(claude.loggingIn)
                    } else {
                        Button("Log in to Codex") { loginStarted = true; Task { await codex.startLogin(force: true) } }
                            .buttonStyle(.borderedProminent).tint(.white)
                            .disabled(codex.loggingIn)
                    }
                } else if kind == .diskFull {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.bordered).tint(.white)
                    Button("Manage Storage") { DiskSpace.openStorageSettings() }
                        .buttonStyle(.borderedProminent).tint(.white)
                } else {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.borderedProminent).tint(.white)
                }
            }
            if loginStarted, (ModelBackend.current == .claude ? claude.loggingIn : codex.loggingIn) {
                Text("A browser window opened. Finish signing in there; I'll retry on my own.")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        }
        // The browser-login auto-notice, same as Settings → Health and onboarding: while our
        // login is out, poll the active engine's login status (the login process self-exits
        // once the sign-in lands, no confirm button); the moment it reads logged-in, retry the
        // cycle on our own. Leaving the failed state cancels the poll.
        .task(id: loginStarted) {
            guard loginStarted else { return }
            let isClaude = ModelBackend.current == .claude
            while !Task.isCancelled, !(isClaude ? claude.loggedIn : codex.loggedIn) {
                try? await Task.sleep(for: .seconds(1.5))
                if isClaude { await claude.refreshLoginStatus() }
                else { await codex.refreshLoginStatus() }
            }
            guard !Task.isCancelled, (isClaude ? claude.loggedIn : codex.loggedIn) else { return }
            loginStarted = false
            // Unstructured on purpose: the retry flips state out of .failed, which tears THIS
            // task down — the run must survive that.
            session.retry()
        }
    }

    private static func failTitle(_ kind: OvernightCaution.Kind?) -> String {
        let claude = ModelBackend.current == .claude
        return switch kind {
        case .loggedOut:      claude ? "Claude isn't signed in" : "Codex isn't logged in"
        case .usageLimit:     claude ? "We hit Claude's usage limit" : "We hit ChatGPT's usage limit"
        case .noInternet:     "No internet connection"
        case .inputTooLarge:  "This batch was too big to send"
        case .diskFull:       "Your Mac's disk is full"
        case .connectorAuth:  "A connected app needs a fresh sign-in"
        case .stalled:        "Processing got stuck"   // recorded only by the 3 AM watchdog; here for exhaustiveness
        case nil:             "Processing failed"
        }
    }

    /// Classified failures get a friendly, actionable line (the raw detail is in the log +
    /// Sentry); unclassified ones show the step's own message, as before.
    private static func failBody(kind: OvernightCaution.Kind?, message: String) -> String {
        let claude = ModelBackend.current == .claude
        return switch kind {
        case .loggedOut:      claude
            ? "Sentient runs on your own Claude account through Claude Code, and that sign-in has stopped working. Sign back in and I'll pick up right where we stopped."
            : "Sentient runs on your own ChatGPT account through codex, and that login has stopped working. Log back in and I'll pick up right where we stopped."
        case .usageLimit:     "Your plan's window resets on its own. Everything so far is saved; retry in a while and I'll pick up right where we stopped."
        case .noInternet:     "This step runs in the cloud. Once you're back online, hit Retry; everything so far is saved."
        case .inputTooLarge:  claude
            ? "Sentient tried to send Claude more than it accepts in one request. Your analysis is saved; if a retry hits this again, update Sentient OS and retry once more."
            : "Sentient tried to send ChatGPT more than it accepts in one request. Your analysis is saved; if a retry hits this again, update Sentient OS and retry once more."
        case .diskFull:       "I can't save what I read until there's room on this Mac. Free up some space (a few GB is plenty), then hit Retry; everything so far is saved and I'll pick up right where we stopped."
        case .connectorAuth:  claude
            ? "One of your connected apps has stopped accepting its sign-in. Reconnect it on claude.ai, then hit Retry; everything so far is saved."
            : "One of your connected apps has stopped accepting its sign-in. Reconnect it on chatgpt.com, then hit Retry; everything so far is saved."
        case .stalled:        "The work stopped making progress, so I ended it. Everything so far is saved; hit Retry and I'll pick up right where we stopped."
        case nil:             message
        }
    }

    private var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }

    private var waitingView: some View {
        VStack(spacing: 22) {
            Image(systemName: state == .scheduled ? "moon.stars" : "pause.circle")
                .font(.system(size: 40, weight: .light)).foregroundStyle(Theme.secondary)
            Text(session.statusLine).display(27).foregroundStyle(.white)
            if isWaiting {
                if state == .waiting(.model) {
                    OnboardingModelDownloadView(download: ModelDownload.shared)
                        .frame(height: 230)
                } else {
                    Text(session.waitingDetail).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
            } else if let notice = session.record.notice {
                Text(notice).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            Text(CodexAuth.knowledgeBaseOnly ? "Your main window is ready to use." : "Sidekick is ready to use in your main window.")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
            if state == .scheduled || state == .idle {
                OnboardingNextButton(title: "Start now") { session.requestNow() }
                    .disabled(session.isBusy || session.isSuspended)
                    .accessibilityIdentifier("analysis.startNow")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button { if paused { session.retry() } else { session.pause() } } label: {
                Text(paused ? "Resume Analysis" : "Pause Analysis")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(state == .stopping)
            Text(paused ? "Your progress is saved. Resume when you're ready."
                 : isWaiting ? "Keep Sentient open. Analysis will start when your Mac is ready."
                 : "You can close this window. Analysis continues in the background.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
            if showPrompt {
                Text(progress.lastPath ?? "").font(.caption.monospaced()).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var percent: Int {
        shownTotal > 0 ? Int(Double(shownDone) / Double(shownTotal) * 100) : 0
    }
}

// MARK: - Previews

#if DEBUG
/// Frozen presentation fixtures never submit work to the app-owned coordinator.
extension ProcessingView {
    static func appleMailPreview() -> ProcessingView {
        let preview = ProcessingCoordinator.preview(state: .processing)
        let view = ProcessingView(session: preview)
        var progress = RunProgress()
        progress.total = 600; progress.done = 63; progress.junk = 63
        progress.lastPath = "Apple Mail"
        progress.lastItemDate = ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z")
        progress.lastTitle = "Weekly reading digest"
        progress.lastSummary = "A roundup of articles and product updates for this week."
        progress.lastVerdict = .junk; progress.lastSeconds = 3.2
        preview.setPreviewProgress(progress)
        return view
    }

    static func connectorPreview(_ status: String) -> ProcessingView {
        let preview = ProcessingCoordinator.preview(state: status.hasPrefix("completed") ? .completed : .processing)
        let view = ProcessingView(session: preview)
        var progress = RunProgress()
        progress.total = 1
        progress.beginSourceRead(name: "Granola", label: "recent 30-day note sample", prompt: "")
        if status == "summary" || status == "completed-summary" {
            progress.done = 1; progress.survivors = 1
            progress.finishSourceRead(name: "Granola", label: "recent 30-day note sample",
                summary: "The user and their team agreed to review the prototype together next week.", items: 3)
        } else if status == "quiet" {
            progress.done = 1; progress.quietReads = 1
            progress.finishSourceRead(name: "Notion", label: "initial page sample", summary: nil, items: 6)
        } else if status == "failed" || status == "completed" {
            progress.done = 1
            progress.failSourceRead(name: "Granola", message: "The service returned a response Sentient couldn't verify.")
        }
        preview.setPreviewProgress(progress)
        return view
    }

    static func preparingPreview() -> ProcessingView {
        var view = ProcessingView(session: .preview(state: .preparing))
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

#Preview("Connector reading") {
    ProcessingView.connectorPreview("reading").frame(width: 680, height: 720)
}
#Preview("Connector summary") {
    ProcessingView.connectorPreview("summary").frame(width: 680, height: 720)
}
#Preview("Connector needs another try") {
    ProcessingView.connectorPreview("completed").frame(width: 680, height: 720)
}

#Preview("Preparing — cloud tail") {
    ProcessingView.preparingPreview()
        .frame(width: 1160, height: 780)
}
#Preview("Apple Mail message date") {
    ProcessingView.appleMailPreview().frame(width: 1040, height: 800)
}
#endif
