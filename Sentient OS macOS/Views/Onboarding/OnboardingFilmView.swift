//
//  OnboardingFilmView.swift
//  Sentient OS macOS
//
//  Onboarding slide 1 — the website's film (sentient-os.ai/onboarding) playing inside a
//  WKWebView. The page drives itself (its Autopilot scrolls the film) and parks at the
//  morning-home rest (?end=0.42 in film progress); at each park it posts "parked" to the
//  `autopilot` message handler and the native Continue button blooms in. Three legs: the
//  night film → the Sidekick scene → the Under-the-hood exhibit (the site's architecture
//  diagram, parked on its "hood" anchor). The webview is a movie, not a page: hit-testing
//  returns nil (no scrolling, no clicks), navigation off our host is blocked, and the view
//  fades in black-on-black only after the page loads (no flash) — with ONE exception: the
//  hood park is interactive (hover captions + the Read More popup), wheel still swallowed.
//  Offline or a failed load falls back to a quiet branded slide, so onboarding is never
//  blocked on the network. Watchdogs bound every wait: 12s to load, 40s to park.
//  DEBUG: `defaults write` the string `dev.film.url` to point the step at a local dev
//  server (e.g. http://localhost:3100/onboarding?end=0.42).
//

import SwiftUI
import WebKit

struct OnboardingFilmView: View {
    let onContinue: () -> Void

    /// For the notch demo: the film step arms the coordinator's one-shot scripted Sidekick
    /// performance while the film is parked on "Click the notch".
    @Environment(AppState.self) private var appState

    /// The step's phases, three film legs in one webview: black until the film is really
    /// rendering → leg 1 (night → the morning park; Continue up) → on Continue, leg 2
    /// (the turn, "One more thing. Meet Sidekick.", the dive, the whole Sidekick scene;
    /// same page instance, `continueTo` over evaluateJavaScript) → parked again → on
    /// Continue, leg 3 (a short ride down to the Under-the-hood exhibit, parked on its
    /// "hood" anchor — the film's one INTERACTIVE beat: hover captions and the Read More
    /// popup work) → the final Continue advances onboarding. `unavailable` is the offline
    /// fallback slide.
    /// The loading → playing fade keys on the page's "ready" message (posted
    /// post-hydration, as the entrance starts) — WKWebView's didFinish fires long before
    /// first paint, so fading on it pops content into an already-visible view; didFinish
    /// survives only as a grace-period fallback for a page that never posts.
    /// With a real notch, the Sidekick leg splits around the hardware beat: ride to the
    /// "Click the notch" whisper (.ridingToInvitation) → wait for the user's REAL bezel click
    /// (.awaitingNotch — the coordinator's armed demo answers it) → the demo fires and the film
    /// rides on (.ridingSidekick). Notch-less Macs skip straight from .parked to .ridingSidekick.
    private enum Phase {
        case loading, playing, parked, ridingToInvitation, awaitingNotch,
             ridingSidekick, sidekickDone, ridingToHood, hoodParked, unavailable
    }
    @State private var phase: Phase = .loading

    /// didFinish fired — arms the fallback fade for a "ready"-less page (older deploy).
    @State private var finishedLoad = false

    /// The bridge for driving the page's autopilot (leg 2's continueTo).
    @State private var driver = FilmDriver()

    /// The parks' page-measured Continue centers — the middle of the free zone the
    /// film reports (driver.morningBand / driver.hoodBand). nil until the page
    /// answers (or an older deploy never does); each park's fallback holds until
    /// then.
    @State private var morningBandCenter: CGFloat?
    @State private var hoodBandCenter: CGFloat?

    /// Leg 1: the film to the morning-home rest — p 0.42 (pNight 0.76: home settled, wake
    /// line up, before the zoom at 0.477 and the turn/dive after it). The turn ("One more
    /// thing. Meet Sidekick.") belongs to LEG 2, which rides from the park to the film's
    /// final frame (0.999 — never 1.0: p ≥ 1 means the page bottom, and the site's tail +
    /// footer must never scroll into the webview). LEG 3 parks on the Under-the-hood
    /// exhibit via its element anchor ("hood" — the exhibit is 100svh, so the park fills
    /// the frame exactly and the tail + footer still never appear); anchors live outside
    /// the film's p space, so re-pacing never moves them.
    /// ⚠️ Parked beats are ADDRESSES into the film's scroll timeline: whenever the website
    /// re-budgets FilmHero's per-scene _VH constants, these must be re-derived in lockstep
    /// (the contract lives in the site's Autopilot.tsx header; p = beat vh / SCROLL_VH —
    /// 0.42 = the 2026-07-16 pacing). Pace rides the page's own defaults.
    private static let productionURL = URL(string: "https://sentient-os.ai/onboarding?end=0.42")!
    private static let sidekickEndP = 0.999

    /// The "Click the notch" park — pDay 0.44 (the invitation whisper holds 0.42–0.47), in
    /// master p: 0.4773 + 0.44 × 0.5227. Only used when a real notch exists.
    private static let invitationEndP = 0.707

    /// A Mac with a real notch gets the hardware beat: the film hides its DOM notch
    /// (?notch=real) and the user's own bezel performs the Sidekick show.
    private static var realNotchAvailable: Bool {
        NotchWindowController.builtInNotchScreen() != nil
    }

    private static var filmURL: URL {
        var base = productionURL
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "dev.film.url"),
           let url = URL(string: raw) { base = url }
        #endif
        guard realNotchAvailable,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "notch" }) {
            items.append(URLQueryItem(name: "notch", value: "real"))
            comps.queryItems = items
        }
        return comps.url ?? base
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if phase == .unavailable {
                fallbackSlide.transition(.opacity)
            } else {
                FilmWebView(url: Self.filmURL,
                            driver: driver,
                            onLoaded: { finishedLoad = true },
                            onReady: { fadeIn() },
                            onParked: { legParked() },
                            onFailed: { if phase == .loading { setPhase(.unavailable) } })
                    .ignoresSafeArea()
                    .opacity(phase == .loading ? 0 : 1)
                    // The movie can't be touched — except the hood park, the film's one
                    // interactive beat (PassiveWebView gates the NSView side in lockstep).
                    .allowsHitTesting(phase == .hoodParked)

                // Continue blooms in whenever a leg parks. On the MORNING park the laptop
                // fills the window's lower half, so the button sits ABOVE it — centered in
                // the black band between the "9:00 AM" whisper and the lid's top edge.
                // The band's position is PAGE-MEASURED (driver.morningBand: the film lays
                // itself out responsively, so any fixed native coordinate drifts onto the
                // whisper or the lid the moment the window resizes), re-asked on every
                // size change; the fraction is only the pre-answer/old-deploy fallback.
                // The film's FINAL park is a full-viewport stage, so that Continue hugs
                // the bottom.
                if phase == .parked {
                    GeometryReader { geo in
                        OnboardingNextButton(title: "Continue", action: advanceFromPark)
                            .position(x: geo.size.width / 2,
                                      y: morningBandCenter ?? geo.size.height * 0.185)
                            .onAppear { measureMorningBand() }
                            .onChange(of: geo.size) { measureMorningBand() }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                } else if phase == .sidekickDone {
                    // Lifted off the very edge — the full-viewport stage has breathing
                    // room below the windows, and a bottom-hugging button read awkward.
                    VStack {
                        Spacer()
                        OnboardingNextButton(title: "Continue", action: advanceFromPark)
                            .padding(.bottom, 44)
                    }
                    .transition(.opacity)
                } else if phase == .hoodParked {
                    // The hood park: page-placed like the morning's — pinned just under
                    // the zone top the exhibit reports (its caption band, tall hover
                    // state reserved; driver.hoodBand), re-asked on every resize and
                    // clamped on-screen. NOT centered in the remaining zone: the
                    // exhibit's bottom chrome leaves only slack there on height-bound
                    // windows, so a centered button always rode the bottom clamp.
                    // Fallback = the old bottom-hug until the page answers.
                    GeometryReader { geo in
                        OnboardingNextButton(title: "Continue", action: advanceFromPark)
                            .position(x: geo.size.width / 2,
                                      y: min(hoodBandCenter ?? (geo.size.height - 68),
                                             geo.size.height - 40))
                            .onAppear { measureHoodBand() }
                            .onChange(of: geo.size) { measureHoodBand() }
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
        }
        // The film step leaving (Continue, back) must never strand an armed demo — the
        // notch goes back to its real behavior the moment onboarding moves on.
        .onDisappear { appState.commandCoordinator.disarmOnboardingNotchDemo() }
        // Load watchdog: a first launch with no internet lands on the fallback, never a void.
        .task {
            try? await Task.sleep(for: .seconds(12))
            if phase == .loading { setPhase(.unavailable) }
        }
        // The "ready"-less fallback: didFinish + a grace beat, for a page that never posts.
        .task(id: finishedLoad) {
            guard finishedLoad else { return }
            try? await Task.sleep(for: .seconds(1.2))
            fadeIn()
        }
        // Park watchdogs, one per leg: if the park signal never arrives (older deploy,
        // JS hiccup), Continue blooms anyway. Leg 1 rides ~15s, leg 2 ~17s, leg 3 ~3s —
        // all bounded.
        .task(id: phase == .playing) {
            guard phase == .playing else { return }
            try? await Task.sleep(for: .seconds(40))
            if phase == .playing { setPhase(.parked) }
        }
        .task(id: phase == .ridingSidekick) {
            guard phase == .ridingSidekick else { return }
            try? await Task.sleep(for: .seconds(45))
            if phase == .ridingSidekick { setPhase(.sidekickDone) }
        }
        .task(id: phase == .ridingToHood) {
            guard phase == .ridingToHood else { return }
            try? await Task.sleep(for: .seconds(15))
            if phase == .ridingToHood { setPhase(.hoodParked) }
        }
        // The notch invitation was the one wait without a watchdog — the corner SKIP
        // used to be its manual exit (removed 2026-07-17). If the bezel never gets
        // clicked, the film rides on by itself, exactly as answering it would.
        .task(id: phase == .awaitingNotch) {
            guard phase == .awaitingNotch else { return }
            try? await Task.sleep(for: .seconds(60))
            if phase == .awaitingNotch {
                appState.commandCoordinator.disarmOnboardingNotchDemo()
                setPhase(.ridingSidekick)
                driver.continueTo(Self.sidekickEndP)
            }
        }
        .task(id: phase == .ridingToInvitation) {
            guard phase == .ridingToInvitation else { return }
            try? await Task.sleep(for: .seconds(30))
            if phase == .ridingToInvitation { armNotchBeat() }
        }
    }

    private func setPhase(_ new: Phase) {
        withAnimation(.easeInOut(duration: 0.45)) { phase = new }
        // The NSView-side hit-testing gate rides the phase in lockstep with the
        // SwiftUI-side .allowsHitTesting above.
        driver.setInteractive(new == .hoodParked)
    }

    /// A leg landed — route the page's "parked" by which leg was riding.
    private func legParked() {
        switch phase {
        case .loading, .playing:    setPhase(.parked)
        case .ridingToInvitation:   armNotchBeat()
        case .ridingSidekick:       setPhase(.sidekickDone)
        case .ridingToHood:         setPhase(.hoodParked)
        default: break
        }
    }

    /// The parked Continue: the first park rides on — to the hardware notch beat when the Mac
    /// has one, else straight through the whole Sidekick scene. The Sidekick park's Continue
    /// rides leg 3 down to the Under-the-hood exhibit; the hood park's Continue hands
    /// onboarding to the next step.
    private func advanceFromPark() {
        switch phase {
        case .parked where Self.realNotchAvailable:
            setPhase(.ridingToInvitation)
            driver.continueTo(Self.invitationEndP)
        case .parked:
            setPhase(.ridingSidekick)
            driver.continueTo(Self.sidekickEndP)
        case .sidekickDone:
            setPhase(.ridingToHood)
            // A deploy without the hood anchor (older site) reports unsupported —
            // then the Continue the user just pressed keeps its old meaning and
            // onboarding simply moves on. Never a second parked-in-place button
            // (field-found 2026-07-17: pre-deploy, the fallback bloomed a stray
            // bottom-right Continue over the Sidekick frame).
            driver.continueToHood { supported in
                if !supported { exitStep() }
            }
        default:
            exitStep()
        }
    }

    /// Leaving the film step (Continue, the fallback slide): the notch beat is behind the
    /// user now — from here to the home screen, a notch/hotkey press answers with the
    /// "finish onboarding" aside instead of pre-beat silence (the coordinator's policy).
    private func exitStep() {
        UserDefaults.standard.set(true, forKey: CommandCoordinator.notchDemoPlayedKey)
        onContinue()
    }

    /// Parked on "Click the notch": arm the coordinator's one-shot demo. The user's real bezel
    /// click opens the real type field, the task types itself, and the moment the demo fires,
    /// the film rides on — the webview's windows play the shopping run while the hardware notch
    /// narrates. Disarmed on step-exit via onDisappear.
    private func armNotchBeat() {
        setPhase(.awaitingNotch)
        appState.commandCoordinator.armOnboardingNotchDemo { [self] in
            driver.continueTo(Self.sidekickEndP)
            setPhase(.ridingSidekick)
        }
    }

    /// Ask the page where the morning band is (whisper bottom → lid top) and center
    /// the Continue in it. Fired when the morning park appears and again on every
    /// window resize; a nil answer keeps whatever we had (fallback or last good).
    /// The floor handles the short-window case where the film's own layout leaves NO
    /// gap (the lid rises past the narration, the band inverts — field-measured at
    /// 1100×700): the button then sits just below the narration, over the lid's dark
    /// top edge. Covering the bezel reads fine; covering text never does.
    private func measureMorningBand() {
        withTrailingRead {
            driver.morningBand { band in
                guard let band else { return }
                morningBandCenter = max((band.top + band.bottom) / 2, band.top + 30)
            }
        }
    }

    /// The hood park: pin the button's center a fixed beat below the reported zone
    /// top (the caption band's reserved bottom edge). Centering in the zone itself
    /// glued the button to the bottom of the window — the exhibit's own chrome
    /// leaves the zone ~30px tall on height-bound windows, and on width-bound ones
    /// the pooled slack put the center far below where the eye wants the button.
    private func measureHoodBand() {
        withTrailingRead {
            driver.hoodBand { band in
                guard let band else { return }
                hoodBandCenter = band.top + 30
            }
        }
    }

    /// Run a band read now AND once more after a beat. The page re-parks its scroll
    /// on a rAF after a resize (Autopilot's onResize); a read racing that reflow
    /// measures the drifted frame — the trailing read lands on the settled one.
    private func withTrailingRead(_ read: @escaping () -> Void) {
        read()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            read()
        }
    }

    /// The webview's entrance — a long, gentle rise from black (the film's entrance is
    /// already playing underneath it). Idempotent: ready + the didFinish fallback can race.
    private func fadeIn() {
        guard phase == .loading else { return }
        withAnimation(.easeInOut(duration: 1.2)) { phase = .playing }
    }

    /// The no-internet stand-in: the promise in one line, and onboarding moves on.
    private var fallbackSlide: some View {
        VStack(spacing: 40) {
            Spacer()
            OnboardingWhisper("STEP 1 OF 3")
            Text("An AI that knows your life, and acts on it.")
                .display(30)
            OnboardingNextButton(title: "Continue", action: exitStep)
            Spacer()
            OnboardingTrustFooter()
        }
        .padding(40)
    }
}

// MARK: - The webview

/// The native → page bridge: holds the webview so the step can drive the page's
/// autopilot (window.__sentientAutopilot, installed by the site on mount).
final class FilmDriver {
    weak var webView: WKWebView?

    /// Resume the parked ride to a new film-p address (leg 2: the Sidekick scene).
    /// delay = the breath before motion. Pace stays the site's: the film's own beat
    /// profile makes the turn + dive transition brisk while the Sidekick scene rides
    /// base speed — the app doesn't second-guess the film's timing.
    func continueTo(_ end: Double, delay: Double = 0.1) {
        Log("Onboarding film: continueTo(\(end), delay: \(delay))")
        webView?.evaluateJavaScript(
            "window.__sentientAutopilot?.continueTo(\(end), \(delay))")
    }

    /// Leg 3: ride to the Under-the-hood exhibit's element anchor. Guarded on the
    /// anchor existing in the deployed page (an older deploy has no "hood" id, and
    /// feeding its Autopilot a string would ride into NaN) — the completion reports
    /// whether the leg actually fired.
    func continueToHood(delay: Double = 0.1, completion: @escaping (Bool) -> Void) {
        guard let webView else { completion(false); return }
        Log("Onboarding film: continueTo(hood, delay: \(delay))")
        webView.evaluateJavaScript(
            """
            (() => {
              if (!document.getElementById('hood') || !window.__sentientAutopilot) return false;
              window.__sentientAutopilot.continueTo('hood', \(delay));
              return true;
            })()
            """) { result, _ in
            completion((result as? Bool) ?? false)
        }
    }

    /// The hood park is the film's one interactive beat — this flips the webview's
    /// hit-testing (hover captions + the Read More popup) and its wheel gate.
    func setInteractive(_ on: Bool) {
        (webView as? PassiveWebView)?.interactive = on
    }

    /// A park's free zone, measured by the PAGE, in viewport px (1:1 with view
    /// points). The film lays itself out responsively, so a fixed native coordinate
    /// for the Continue button goes stale on every window resize — the page is the
    /// only honest source for where the free space actually is. An INVERTED band
    /// (bottom above top) is meaningful, not junk: at short windows the film's own
    /// layout can leave no gap, and the caller's clamp rules place the button
    /// accordingly. nil = no answer (older deploy, mid-load); callers keep their
    /// fallback.
    private func band(_ fn: String,
                      completion: @escaping ((top: CGFloat, bottom: CGFloat)?) -> Void) {
        guard let webView else { completion(nil); return }
        webView.evaluateJavaScript(
            "window.__sentientAutopilot?.\(fn)?.() ?? null") { result, _ in
            guard let band = result as? [Double], band.count == 2 else {
                completion(nil)
                return
            }
            completion((CGFloat(band[0]), CGFloat(band[1])))
        }
    }

    /// The morning park: [narration bottom, lid top].
    func morningBand(completion: @escaping ((top: CGFloat, bottom: CGFloat)?) -> Void) {
        band("morningBand", completion: completion)
    }

    /// The hood park: [under the caption band (tall hover state reserved), viewport
    /// bottom].
    func hoodBand(completion: @escaping ((top: CGFloat, bottom: CGFloat)?) -> Void) {
        band("hoodBand", completion: completion)
    }
}

/// A WKWebView that can't be interacted with, so the film can't be scrolled off its
/// autopilot or clicked away: hitTest nil keeps the whole subtree out of event routing,
/// the scrollWheel stub swallows anything that arrives some other way (responder chain),
/// and refusing first-responder keeps keyboard scrolling (space, arrows) out too.
///
/// One sanctioned exception: the hood park (`interactive`), where the exhibit's hover
/// captions and Read More popup come alive. Even then the WHEEL stays swallowed — one
/// scroll would drag the parked film toward the footer — via a local event monitor. The
/// one wheel that passes is while the page reports its popup open (`popupOpen`): the
/// popup's internal scroller needs it, and the page locks its own scroll then (Lenis
/// stop), so the film can't move underneath.
///
/// ⚠️ Both halves must yield together. The monitor gates AppKit's dispatch, but a
/// WKWebView usually hitTests to ITSELF, so the passed event lands right back on this
/// override — an unconditional no-op here would eat the popup's wheel even after the
/// monitor let it by (field-found 2026-07-17: the popup wouldn't scroll). So the
/// override forwards to super under exactly the same `popupOpen` condition.
private final class PassiveWebView: WKWebView {
    var interactive = false { didSet { syncWheelGate() } }
    /// Mirrors the page's popup state ("popup-open"/"popup-closed" bridge messages).
    var popupOpen = false

    private var wheelGate: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }
    override func scrollWheel(with event: NSEvent) {
        if popupOpen { super.scrollWheel(with: event) }
    }
    override var acceptsFirstResponder: Bool { false }

    private func syncWheelGate() {
        if interactive, wheelGate == nil {
            wheelGate = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, !self.popupOpen else { return event }
                return nil
            }
        } else if !interactive, let gate = wheelGate {
            NSEvent.removeMonitor(gate)
            wheelGate = nil
        }
    }

    deinit {
        if let gate = wheelGate { NSEvent.removeMonitor(gate) }
    }
}

private struct FilmWebView: NSViewRepresentable {
    let url: URL
    let driver: FilmDriver
    let onLoaded: () -> Void
    let onReady: () -> Void
    let onParked: () -> Void
    let onFailed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Onboarding runs once — no cookies or cache worth keeping.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "autopilot")

        // No scrollbar over the film — it's a movie, not a page. Injected at document
        // start so the thumb never flashes even on the first scrolled frame.
        let hideScrollbars = WKUserScript(
            source: """
            const style = document.createElement('style');
            style.textContent = '::-webkit-scrollbar{display:none!important} html{scrollbar-width:none}';
            document.documentElement.appendChild(style);
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(hideScrollbars)

        let webView = PassiveWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .black   // never a white flash behind the film
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        driver.webView = webView
        Log("Onboarding film: loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "autopilot")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let parent: FilmWebView
        init(_ parent: FilmWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "autopilot" else { return }
            Log("Onboarding film: page says '\(message.body as? String ?? "?")'")
            switch message.body as? String {
            case "ready":  parent.onReady()
            case "parked": parent.onParked()
            // The exhibit's Read More popup opening/closing (hood park) — drives the
            // wheel gate: an open popup owns the wheel, a closed one gives it back.
            case "popup-open":   (message.webView as? PassiveWebView)?.popupOpen = true
            case "popup-closed": (message.webView as? PassiveWebView)?.popupOpen = false
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log("Onboarding film: didFinish")
            parent.onLoaded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log("Onboarding film: load failed — \(ErrorLabel(error))")
            parent.onFailed()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log("Onboarding film: provisional load failed — \(ErrorLabel(error))")
            parent.onFailed()
        }

        /// The film is the only thing this view will ever show — same-host loads only.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.host == parent.url.host ? .allow : .cancel)
        }

        /// An HTTP error page (404 before the site route deploys, a server incident) is a
        /// failed load, not a film — cancel it so the fallback slide shows instead.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame,
               let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                Log("Onboarding film: HTTP \(http.statusCode) — falling back")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

#Preview("Onboarding — film slide") {
    OnboardingFilmView(onContinue: {})
        .frame(width: 1180, height: 880)
        .preferredColorScheme(.dark)
}
