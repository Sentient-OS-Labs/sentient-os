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

    /// The step's phases: black until the page loads → the ride → parked (Continue up).
    /// `unavailable` is the offline fallback slide.
    private enum Phase { case loading, playing, parked, unavailable }
    @State private var phase: Phase = .loading

    /// The production cut: the film to the morning-home rest. p 0.50 = cards dealt (done
    /// 0.426), camera settled (0.493), morning line up (0.347), with a full 0.08p of margin
    /// before Scene III's turn text at 0.58 — the turn must never be seen in onboarding.
    /// Pace rides the page's own defaults.
    private static let productionURL = URL(string: "https://sentient-os.ai/onboarding?end=0.50")!

    private static var filmURL: URL {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "dev.film.url"),
           let url = URL(string: raw) { return url }
        #endif
        return productionURL
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if phase == .unavailable {
                fallbackSlide.transition(.opacity)
            } else {
                FilmWebView(url: Self.filmURL,
                            onLoaded: { setPhase(.playing) },
                            onParked: { setPhase(.parked) },
                            onFailed: { if phase != .parked { setPhase(.unavailable) } })
                    .ignoresSafeArea()
                    .opacity(phase == .loading ? 0 : 1)
                    .allowsHitTesting(false)

                // Continue blooms in the moment the film parks on the morning home.
                if phase == .parked {
                    VStack {
                        Spacer()
                        OnboardingNextButton(title: "Continue", action: onContinue)
                            .padding(.bottom, 42)
                    }
                    .transition(.opacity)
                }
            }
        }
        // A quiet skip for the impatient, gone once Continue is up.
        .overlay(alignment: .bottomLeading) {
            if phase == .loading || phase == .playing {
                FilmSkipButton(action: onContinue)
                    .padding(.leading, 22).padding(.bottom, 13)
                    .transition(.opacity)
            }
        }
        // Load watchdog: a first launch with no internet lands on the fallback, never a void.
        .task {
            try? await Task.sleep(for: .seconds(12))
            if phase == .loading { setPhase(.unavailable) }
        }
        // Park watchdog: the ride to p 0.54 takes ~15s after load; if the park signal never
        // arrives (old deploy without ?end, JS hiccup), Continue blooms anyway.
        .task(id: phase == .playing) {
            guard phase == .playing else { return }
            try? await Task.sleep(for: .seconds(40))
            if phase == .playing { setPhase(.parked) }
        }
    }

    private func setPhase(_ new: Phase) {
        withAnimation(.easeInOut(duration: 0.45)) { phase = new }
    }

    /// The no-internet stand-in: the promise in one line, and onboarding moves on.
    private var fallbackSlide: some View {
        VStack(spacing: 40) {
            Spacer()
            OnboardingWhisper("STEP 1 OF 3")
            Text("An AI that knows your life, and acts on it.")
                .display(30)
            OnboardingNextButton(title: "Continue", action: onContinue)
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
    let onLoaded: () -> Void
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
            if message.name == "autopilot", message.body as? String == "parked" {
                parent.onParked()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
