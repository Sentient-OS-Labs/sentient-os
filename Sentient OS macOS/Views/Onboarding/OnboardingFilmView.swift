//
//  OnboardingFilmView.swift
//  Sentient OS macOS
//
//  Onboarding slide 1 — the website's film (sentient-os.ai/onboarding) playing inside a
//  WKWebView. The page drives itself (its Autopilot scrolls the film) and parks at the
//  morning-home rest (?end=0.54 in film progress); at the park it posts "parked" to the
//  `autopilot` message handler and the native Continue button blooms in. The webview is a
//  movie, not a page: hit-testing returns nil (no scrolling, no clicks), navigation off our
//  host is blocked, and the view fades in black-on-black only after the page loads (no
//  flash). Offline or a failed load falls back to a quiet branded slide, so onboarding is
//  never blocked on the network. Watchdogs bound every wait: 12s to load, 40s to park.
//  DEBUG: `defaults write` the string `dev.film.url` to point the step at a local dev
//  server (e.g. http://localhost:3100/onboarding?end=0.54).
//

import SwiftUI
import WebKit

struct OnboardingFilmView: View {
    let onContinue: () -> Void

    /// For the notch demo: the film step arms the coordinator's one-shot scripted Sidekick
    /// performance while the film is parked on "Click the notch".
    @Environment(AppState.self) private var appState

    /// The step's phases, two film legs in one webview: black until the film is really
    /// rendering → leg 1 (night → the morning park; Continue up) → on Continue, leg 2
    /// (the turn, "One more thing. Meet Sidekick.", the dive, the whole Sidekick scene;
    /// same page instance, `continueTo` over evaluateJavaScript) → parked again → the
    /// final Continue advances onboarding. `unavailable` is the offline fallback slide.
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
             ridingSidekick, sidekickDone, unavailable
    }
    @State private var phase: Phase = .loading

    /// didFinish fired — arms the fallback fade for a "ready"-less page (older deploy).
    @State private var finishedLoad = false

    /// The bridge for driving the page's autopilot (leg 2's continueTo).
    @State private var driver = FilmDriver()

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
                    .allowsHitTesting(false)

                // Continue blooms in whenever a leg parks. On the MORNING park the laptop
                // fills the window's lower half, so the button sits ABOVE it — in the black
                // band between the "9:00 AM" whisper and the lid's top edge (~18.5% down;
                // the film's frame scales with the window, so the gap does too). The film's
                // FINAL park is a full-viewport stage, so that Continue hugs the bottom.
                if phase == .parked {
                    GeometryReader { geo in
                        VStack {
                            OnboardingNextButton(title: "Continue", action: advanceFromPark)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, geo.size.height * 0.185)
                    }
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
        // A quiet skip for the impatient, gone whenever Continue is up. (Also the only exit
        // from .awaitingNotch besides clicking the bezel — the park is a calm rest state.)
        .overlay(alignment: .bottomLeading) {
            if phase == .loading || phase == .playing || phase == .ridingToInvitation
                || phase == .awaitingNotch || phase == .ridingSidekick {
                FilmSkipButton(action: exitStep)
                    .padding(.leading, 22).padding(.bottom, 13)
                    .transition(.opacity)
            }
        }
        // The film step leaving (SKIP, Continue, back) must never strand an armed demo — the
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
        // JS hiccup), Continue blooms anyway. Leg 1 rides ~15s, leg 2 ~17s — both bounded.
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
        .task(id: phase == .ridingToInvitation) {
            guard phase == .ridingToInvitation else { return }
            try? await Task.sleep(for: .seconds(30))
            if phase == .ridingToInvitation { armNotchBeat() }
        }
    }

    private func setPhase(_ new: Phase) {
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

    /// The parked Continue: the first park rides on — to the hardware notch beat when the Mac
    /// has one, else straight through the whole Sidekick scene. The final park's Continue hands
    /// onboarding to the next step.
    private func advanceFromPark() {
        switch phase {
        case .parked where Self.realNotchAvailable:
            setPhase(.ridingToInvitation)
            driver.continueTo(Self.invitationEndP)
        case .parked:
            setPhase(.ridingSidekick)
            driver.continueTo(Self.sidekickEndP)
        default:
            exitStep()
        }
    }

    /// Leaving the film step (Continue, SKIP, the fallback slide): the notch beat is behind the
    /// user now — from here to the home screen, a notch/hotkey press answers with the
    /// "finish onboarding" aside instead of pre-beat silence (the coordinator's policy).
    private func exitStep() {
        UserDefaults.standard.set(true, forKey: CommandCoordinator.notchDemoPlayedKey)
        onContinue()
    }

    /// Parked on "Click the notch": arm the coordinator's one-shot demo. The user's real bezel
    /// click opens the real type field, the task types itself, and the moment the demo fires,
    /// the film rides on — the webview's windows play the shopping run while the hardware notch
    /// narrates. Disarmed on SKIP/step-exit via onDisappear.
    private func armNotchBeat() {
        setPhase(.awaitingNotch)
        appState.commandCoordinator.armOnboardingNotchDemo { [self] in
            driver.continueTo(Self.sidekickEndP)
            setPhase(.ridingSidekick)
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

/// The corner skip — a mono whisper, quiet until hovered.
private struct FilmSkipButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("SKIP")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(hovering ? Theme.secondary : Theme.Ink.deepMuted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(0.6)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
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
}

/// A WKWebView that can never be interacted with, so the film can't be scrolled off its
/// autopilot or clicked away: hitTest nil keeps the whole subtree out of event routing,
/// the scrollWheel stub swallows anything that arrives some other way (responder chain),
/// and refusing first-responder keeps keyboard scrolling (space, arrows) out too.
private final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollWheel(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }
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
