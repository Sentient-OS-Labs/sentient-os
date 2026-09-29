//
//  OnboardingFilmView.swift
//  Sentient OS macOS
//
//  Onboarding slide 1 — the website's film (sentient-os.ai/onboarding) playing inside a
//  WKWebView. The page drives itself (its Autopilot scrolls the film) and parks at the
//  morning-home rest (?end=0.42 in film progress); at each park it posts "parked" to the
//  `autopilot` message handler and the native Continue button blooms in. The night film leads
//  into Sidekick, then a native Double Tap lesson before the frontier-model picker.
//  The webview is a movie, not a page: hit-testing
//  returns nil (no scrolling, no clicks), navigation off our host is blocked, and the view
//  fades in black-on-black only after the page loads (no flash).
//  Offline or a failed load falls back to a quiet branded slide, so onboarding is never
//  blocked on the network. Watchdogs bound every wait: 12s to load, 40s to park.
//  DEBUG: `defaults write` the string `dev.film.url` to point the step at a local dev
//  server (e.g. http://localhost:3100/onboarding?end=0.42).
//

import AppKit
import SwiftUI
import WebKit

struct OnboardingFilmView: View {
    let onContinue: () -> Void

    #if DEBUG
    /// Publishes the active web intro to the shared dev footer; nil during native screens.
    var onWebIntroChange: (FilmDriver?) -> Void = { _ in }
    #endif

    /// For the notch demo: the film step arms the coordinator's one-shot scripted Sidekick
    /// performance while the film is parked on the invitation (click the notch / press right ⌘).
    @Environment(AppState.self) private var appState

    /// The step's phases, two film legs in one webview: black until the film is really
    /// rendering → leg 1 (night → the morning park; Continue up) → on Continue, leg 2
    /// (the turn, "One more thing. Meet Sidekick.", the dive, the whole Sidekick scene;
    /// same page instance, `continueTo` over evaluateJavaScript) → parked again → the native
    /// Double Tap lesson → the final Continue advances onboarding. `unavailable` is the offline
    /// fallback slide.
    /// The loading → playing fade keys on the page's "ready" message (posted
    /// post-hydration, as the entrance starts) — WKWebView's didFinish fires long before
    /// first paint, so fading on it pops content into an already-visible view; didFinish
    /// survives only as a grace-period fallback for a page that never posts.
    /// The Sidekick leg splits around the hardware beat on EVERY Mac: ride to the invitation
    /// whisper (.ridingToInvitation — "Click the notch" on a lone notch display, "Press the
    /// right ⌘ key" otherwise) → wait for the user's real answer (.awaitingNotch — the
    /// coordinator's armed demo takes a bezel click or a hotkey press alike) → the demo fires
    /// and the film rides on (.ridingSidekick).
    private enum Phase {
        case loading, playing, parked, ridingToInvitation, awaitingNotch,
             ridingSidekick, sidekickDone, doubleTap, unavailable
    }
    @State private var phase: Phase = .loading

    /// didFinish fired — arms the fallback fade for a "ready"-less page (older deploy).
    @State private var finishedLoad = false
    @State private var filmUnavailable = false

    /// The bridge for driving the page's autopilot (leg 2's continueTo).
    @State private var driver = FilmDriver()

    /// The morning park's page-measured Continue center. Its fallback holds until the
    /// page reports the free zone between the narration and the laptop.
    @State private var morningBandCenter: CGFloat?

    /// Leg 1: the film to the morning-home rest — p 0.42 (pNight 0.76: home settled, wake
    /// line up, before the zoom at 0.477 and the turn/dive after it). The turn ("One more
    /// thing. Meet Sidekick.") belongs to LEG 2, which rides from the park to the film's
    /// final frame (0.999 — never 1.0: p ≥ 1 means the page bottom, and the site's tail +
    /// footer must never scroll into the webview).
    /// ⚠️ Parked beats are ADDRESSES into the film's scroll timeline: whenever the website
    /// re-budgets FilmHero's per-scene _VH constants, these must be re-derived in lockstep
    /// (the contract lives in the site's Autopilot.tsx header; p = beat vh / SCROLL_VH —
    /// 0.42 = the 2026-07-16 pacing). Pace rides the page's own defaults.
    private static let productionURL = URL(string: "https://sentient-os.ai/onboarding?end=0.42")!
    private static let sidekickEndP = 0.999

    /// The invitation park — pDay 0.44 (the invitation whisper holds 0.42–0.47), in
    /// master p: 0.4773 + 0.44 × 0.5227. Every Mac rides here.
    private static let invitationEndP = 0.707

    /// Which door the film's invitation names (the ?notch= query value). "real" = a lone
    /// built-in notch display — "Click the notch", the bezel moment. "key" = everything else
    /// (external display connected, iMac, clamshell, a notch-less MacBook) — "Press the
    /// right ⌘ key": the press drops the overlay on the main display, a software notch when
    /// there's no cutout (the hotkey path's shipped rendering). Either way the film hides its
    /// DOM notch and the user's own notch performs the Sidekick show. During the beat BOTH
    /// doors answer (the coordinator arms click and hotkey alike), so the variant only picks
    /// the whisper — baked once at film load; a mid-film display change just means the
    /// whisper names the other door, which still works.
    private static var notchBeat: String {
        NotchWindowController.builtInNotchScreen() != nil && NSScreen.screens.count == 1
            ? "real" : "key"
    }

    /// The Sidekick ride's pinned duration, in seconds. The native notch's scripted
    /// story (CommandRunModel.startOnboardingDemo) reaches its ✓ at ~10.3s of wall
    /// clock, and the film's ✓-beat (stage 9, pDay 0.97) sits ~90% into this leg —
    /// 11.5s lands the two together. Absolute on purpose: the site's pace-share math
    /// shortens every leg as the page's tail grows (field-found 2026-07-17: the new
    /// Close scenes silently sped this leg up and desynced the notch narration).
    private static let sidekickRideSeconds = 11.5

    private static var filmURL: URL {
        var base = productionURL
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "dev.film.url"),
           let url = URL(string: raw) { base = url }
        #endif
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "notch" }) {
            items.append(URLQueryItem(name: "notch", value: notchBeat))
            comps.queryItems = items
        }
        return comps.url ?? base
    }

    private var stage: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if phase == .unavailable {
                fallbackSlide.transition(.opacity)
            } else {
                if !filmUnavailable {
                    FilmWebView(url: Self.filmURL,
                                driver: driver,
                                onLoaded: { finishedLoad = true },
                                onReady: { fadeIn() },
                                onParked: { legParked() },
                                onFailed: { if phase == .loading { setPhase(.unavailable) } })
                        .ignoresSafeArea()
                        .opacity(phase == .loading || phase == .doubleTap ? 0 : 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }

                // Keep the page mounted and hidden during the native lesson so a stale
                // Sidekick frame cannot flash through the transition to the next step.
                if phase == .doubleTap {
                    OnboardingDoubleTapView(coordinator: appState.commandCoordinator,
                                            onContinue: finishDoubleTap)
                        .transition(.opacity)
                }

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
                }
            }
        }
    }

    var body: some View {
        stage
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
        // JS hiccup), Continue blooms anyway. Leg 1 rides ~15s, leg 2 ~17s —
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
        // The notch invitation was the one wait without a watchdog — the corner SKIP
        // used to be its manual exit (removed 2026-07-17). If the invitation is never
        // answered, the film rides on by itself, exactly as answering it would.
        .task(id: phase == .awaitingNotch) {
            guard phase == .awaitingNotch else { return }
            try? await Task.sleep(for: .seconds(60))
            if phase == .awaitingNotch {
                appState.commandCoordinator.disarmOnboardingNotchDemo()
                setPhase(.ridingSidekick)
                driver.continueTo(Self.sidekickEndP, seconds: Self.sidekickRideSeconds)
            }
        }
        .task(id: phase == .ridingToInvitation) {
            guard phase == .ridingToInvitation else { return }
            try? await Task.sleep(for: .seconds(30))
            if phase == .ridingToInvitation { armNotchBeat() }
        }
        #if DEBUG
        .onChange(of: phase, initial: true) { publishWebIntro() }
        .onDisappear { onWebIntroChange(nil) }
        #endif
    }

    #if DEBUG
    private func publishWebIntro() {
        switch phase {
        case .loading, .doubleTap, .unavailable: onWebIntroChange(nil)
        default: onWebIntroChange(driver)
        }
    }
    #endif

    private func setPhase(_ new: Phase) {
        if new == .unavailable { filmUnavailable = true }
        withAnimation(.easeInOut(duration: 0.45)) { phase = new }
    }

    /// A leg landed — route the page's "parked" by which leg was riding.
    private func legParked() {
        switch phase {
        case .loading, .playing:    setPhase(.parked)
        case .ridingToInvitation:   armNotchBeat()
        case .ridingSidekick:       setPhase(.sidekickDone)
        default: break
        }
    }

    /// The parked Continue: the first park rides on to the invitation beat. The Sidekick park's
    /// Continue opens the native Double Tap lesson, which owns its own completion gate.
    private func advanceFromPark() {
        switch phase {
        case .parked:
            setPhase(.ridingToInvitation)
            driver.continueTo(Self.invitationEndP)
        case .sidekickDone:
            setPhase(.doubleTap)
        default:
            exitStep()
        }
    }

    private func finishDoubleTap() {
        guard phase == .doubleTap else { return }
        exitStep()
    }

    /// Leaving the film step (Continue, the fallback slide): the notch beat is behind the
    /// user now — from here to the home screen, a notch/hotkey press answers with the
    /// "finish onboarding" aside instead of pre-beat silence (the coordinator's policy).
    private func exitStep() {
        UserDefaults.standard.set(true, forKey: CommandCoordinator.notchDemoPlayedKey)
        onContinue()
    }

    /// Parked on the invitation: arm the coordinator's one-shot demo. The user's answer — a
    /// bezel click or a hotkey press — opens the real type field, the task types itself, and
    /// the moment the demo fires, the film rides on — the webview's windows play the shopping
    /// run while the real notch narrates. Disarmed on step-exit via onDisappear.
    private func armNotchBeat() {
        driver.hideLogo()
        setPhase(.awaitingNotch)
        appState.commandCoordinator.armOnboardingNotchDemo { [self] in
            driver.continueTo(Self.sidekickEndP, seconds: Self.sidekickRideSeconds)
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
            driver.repark()
            driver.morningBand { band in
                guard let band else { return }
                morningBandCenter = max((band.top + band.bottom) / 2, band.top + 30)
            }
        }
    }

    /// Run a park re-assert + band read now AND once more after a beat. The page
    /// re-parks itself through a resize (its enforcement burst), but the trailing
    /// pass catches WebKit's late post-resize scroll anchoring — and its band read
    /// lands on the settled frame, not the drifting one.
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
            Text("An AI that knows your life, and acts on it.")
                .display(30)
            OnboardingNextButton(title: "Continue", action: { setPhase(.doubleTap) })
            Spacer()
            OnboardingTrustFooter()
        }
        .padding(40)
    }
}

// MARK: - The webview

/// The native → page bridge: holds the webview so the step can drive the page's
/// autopilot (window.__sentientAutopilot, installed by the site on mount).
@Observable final class FilmDriver {
    @ObservationIgnored
    weak var webView: WKWebView?

    #if DEBUG
    private(set) var introSpedUp = false
    @ObservationIgnored private var currentEnd = 0.42
    @ObservationIgnored private var currentSeconds: Double?

    /// Restart the remaining ride from its current scroll position at 50×. The flag also
    /// applies to later Continue calls, without skipping any of the film's interaction stops.
    func speedUpIntro() {
        guard !introSpedUp else { return }
        introSpedUp = true
        continueTo(currentEnd, delay: 0, seconds: currentSeconds)
    }
    #endif

    /// Resume the parked ride to a new film-p address (leg 2: the Sidekick scene).
    /// delay = the breath before motion. Pace stays the site's: the film's own beat
    /// profile makes the turn + dive transition brisk while the Sidekick scene rides
    /// base speed — the app doesn't second-guess the film's timing. The one exception
    /// is `seconds`, an absolute leg duration: the Sidekick ride pins itself to the
    /// notch story's wall clock (an older deploy ignores the extra argument and keeps
    /// the site's pace).
    func continueTo(_ end: Double, delay: Double = 0.1, seconds: Double? = nil) {
        Log("Onboarding film: continueTo(\(end), delay: \(delay), seconds: \(seconds.map { "\($0)" } ?? "site pace"))")
        var playbackRate = 1.0
        var paceArg = "undefined"
        #if DEBUG
        currentEnd = end
        currentSeconds = seconds
        if introSpedUp {
            playbackRate = 50
            // Match Autopilot's default (30s), including a dev URL's valid duration override.
            // Its third argument scales the normal scene pacing; the fourth pins Sidekick.
            paceArg = """
            (() => {
              const duration = Number(new URLSearchParams(window.location.search).get('duration'));
              return (Number.isFinite(duration) && duration >= 1 ? duration : 30) / 50;
            })()
            """
        }
        #endif
        let secondsArg = seconds.map { "\($0 / playbackRate)" } ?? "undefined"
        webView?.evaluateJavaScript(
            "window.__sentientAutopilot?.continueTo(\(end), \(delay / playbackRate), \(paceArg), \(secondsArg))")
    }

    /// The website brings its logo back after the notch invitation. Keep it hidden for
    /// the rest of this page's lifetime, including Sidekick's finish and the native lesson.
    func hideLogo() {
        webView?.evaluateJavaScript("document.documentElement.classList.add('sentient-hide-logo')")
    }

    /// Re-assert the page's park. The page re-snaps itself through a resize (its own
    /// enforcement burst), but some WKWebView resize pipelines reflow without a timely
    /// page-side resize event — so the app also asserts from its side whenever ITS
    /// geometry changes at a park. No-op mid-ride or after user input (the page guards).
    func repark() {
        webView?.evaluateJavaScript("window.__sentientAutopilot?.repark?.()")
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
}

/// A WKWebView that can't be interacted with, so the film can't be scrolled off its
/// autopilot or clicked away: hitTest nil keeps the whole subtree out of event routing,
/// the scrollWheel stub swallows anything that arrives some other way (responder chain),
/// and refusing first-responder keeps keyboard scrolling (space, arrows) out too.
private final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollWheel(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }

    /// No browser context menu, ever — right-click/ctrl-click "Reload Page" would restart
    /// the film and shatter the native-screen illusion. Emptying the menu shows nothing.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
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
            style.textContent = `
              ::-webkit-scrollbar{display:none!important} html{scrollbar-width:none}
              html.sentient-hide-logo .film-logo-link{visibility:hidden!important;opacity:0!important;pointer-events:none!important}
            `;
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
