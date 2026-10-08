//
//  FrontierEnginePicker.swift
//  Sentient OS macOS
//
//  The shared frontier-engine picker — the five engine pills (EngineTab) over each engine's
//  setup panel, rendered identically by Settings → Frontier Model Choice and onboarding's
//  choose-your-frontier-model step. Shares its visible tab with the host and owns the endpoint fields
//  (ModelBackend/CustomProvider — the one source of truth), Test & Select (vision-gated
//  activation: an unproven model can never become the engine), and the honest local-models
//  warning. The ChatGPT panel is the host's slot: Settings points at Permissions & Health,
//  onboarding embeds the live codex login. Layout knob: Settings' fixed 3+2 grid, or
//  onboarding's single centered row. Deep doc: Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md.
//

import SwiftUI

struct FrontierEnginePicker<ChatGPTPanel: View>: View {
    @Environment(\.settingsFormStyle) private var formStyle

    /// Settings' fixed two-row grid (3 + 2 — a scrollbar appearing must never reflow the strip,
    /// the jumpy-rewrap of 2026-07-24), or onboarding's single centered row of five.
    enum Layout { case settingsGrid, singleRow }

    typealias Tab = FrontierEngineTab

    /// The one model that cleared the computer-use bar in the 2026-07-24 survey (~10 models,
    /// real tasks). Prefilled on the OpenRouter tab and named in its note.
    private static var kimiSlug: String { "moonshotai/kimi-k3" }

    let layout: Layout
    /// Whether the ChatGPT engine counts as healthy (wears the pill's active dot). Settings
    /// passes true — login honesty lives in Permissions & Health there; onboarding passes the
    /// live codex login state.
    let chatgptHealthy: Bool
    private let chatgptPanel: () -> ChatGPTPanel

    init(tab: Binding<Tab>,
         layout: Layout = .settingsGrid,
         chatgptHealthy: Bool = true,
         @ViewBuilder chatgptPanel: @escaping () -> ChatGPTPanel) {
        self._tab = tab
        self.layout = layout
        self.chatgptHealthy = chatgptHealthy
        self.chatgptPanel = chatgptPanel
    }

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    @AppStorage(CustomProvider.presetKey) private var presetRaw = CustomProvider.Preset.openRouter.rawValue
    @AppStorage(CustomProvider.baseURLKey) private var baseURL = ""
    @AppStorage(CustomProvider.modelNameKey) private var modelName = ""
    @AppStorage(CustomProvider.reasoningKey) private var reasoningRaw = "low"
    /// Set only by a passing Test Model run; any edit below clears it.
    @AppStorage(CustomProvider.visionVerifiedKey) private var verified = false

    @Binding private var tab: Tab
    @State private var claude = ClaudeSetup.shared
    @State private var claudePreparationTask: Task<Void, Never>?
    @State private var apiKey = ""
    @State private var showLocalWarning = false
    /// The local-reality popup fires once per picker visit, on the LM Studio tab.
    @State private var localWarningShown = false

    /// The Test Model probe, narrated: nil = untested, "…" = running, ✓/✗ lines otherwise.
    @State private var testing = false
    @State private var testVerdict: String?

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }
    private var savedPreset: CustomProvider.Preset { CustomProvider.Preset(rawValue: presetRaw) ?? .openRouter }

    /// The tab wearing the "active engine" dot.
    private var activeTab: Tab {
        Tab(backend: backend, preset: savedPreset)
    }

    var body: some View {
        VStack(alignment: layout == .singleRow ? .center : .leading, spacing: 26) {
            tabStrip

            Group {
                switch tab {
                case .chatgpt:    chatgptPanel()
                case .claude:     claudePanel
                case .openRouter: endpointPanel(for: .openRouter)
                case .lmStudio:   endpointPanel(for: .lmStudio)
                case .custom:     endpointPanel(for: .custom)
                }
            }
            // The Settings editorial measure — panels never stretch wider than prose stays
            // readable, in either host (SettingsPane caps at the same width).
            .frame(maxWidth: formStyle ? .infinity : 640, alignment: .leading)
            .id(tab)
            // A quiet crossfade — no lateral slide: panels differ in height, and a slide on
            // top of the height change read as an abrupt jump (field feedback 2026-07-25).
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: tab)
        .onAppear {
            tab = activeTab
            apiKey = CustomProvider.apiKey ?? ""
        }
        // The host's ChatGPT panel flipping the backend home (Use ChatGPT) retires any verdict.
        .onChange(of: backendRaw) {
            if backend == .chatgpt { testVerdict = nil }
        }
        .alert("A note on local frontier models", isPresented: $showLocalWarning) {
            Button("Understood") {}
        } message: {
            Text("Computer use needs a model that understands screenshots and uses tools reliably. Larger local models may need more memory. Choose the model and provider that fit your Mac and preferences. Cloud providers process your context under their own policies and your account settings.")
        }
    }

    // MARK: - The engine tab strip

    @ViewBuilder private var tabStrip: some View {
        if formStyle {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Tab.allCases) { pill($0) }
            }
        } else {
            Group {
                switch layout {
                case .settingsGrid:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            pill(.chatgpt); pill(.claude); pill(.openRouter)
                        }
                        HStack(spacing: 8) {
                            pill(.lmStudio); pill(.custom)
                        }
                    }
                case .singleRow:
                    HStack(spacing: 8) {
                        ForEach(Tab.allCases) { pill($0) }
                    }
                }
            }
            .fixedSize()
        }
    }

    private func pill(_ t: Tab) -> some View {
        EngineTab(label: t.label, badge: t.badge,
                  selected: tab == t, active: activeTab == t && isActiveEngineHealthy(t)) {
            selectTab(t)
        }
    }

    /// The active dot stays honest: a custom engine only wears it once it's proven usable,
    /// Claude's is its live login, and ChatGPT's honesty is the host's call (Settings: always;
    /// onboarding: logged in).
    private func isActiveEngineHealthy(_ t: Tab) -> Bool {
        switch t {
        case .chatgpt: return chatgptHealthy
        case .claude:  return claude.loggedIn
        default:       return CustomProvider.current.isUsable
        }
    }

    /// Browsing tabs never disturbs a live engine: fields are only prefilled while nothing
    /// custom is active (Test Model and Use-this-model pin the right values when the user
    /// actually acts). The LM Studio tab raises the local-reality popup once per visit.
    private func selectTab(_ t: Tab) {
        tab = t
        testVerdict = nil
        // NO install kicks here (field-found 2026-08-22: a browsing tab click silently
        // downloaded codex on a Claude-backend Mac). Lazy install fires only on COMMITMENT
        // actions: the sign-in buttons, Use ChatGPT, and Test & Select — never on browsing.
        if t == .lmStudio, !localWarningShown {
            localWarningShown = true
            showLocalWarning = true
        }
        guard backend != .custom else { return }
        switch t {
        case .openRouter:
            if modelName.isEmpty { modelName = Self.kimiSlug }   // Kimi K3 forward
            baseURL = CustomProvider.Preset.openRouter.defaultBaseURL
        case .lmStudio:
            if baseURL.isEmpty || baseURL == CustomProvider.Preset.openRouter.defaultBaseURL {
                baseURL = CustomProvider.Preset.lmStudio.defaultBaseURL
            }
        default:
            break
        }
    }

    // MARK: - Claude (the claude -p engine)

    private var claudePanel: some View {
        SettingsGroup(label: formStyle ? "Claude" : "Your Claude") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse(formStyle ? "Use your Claude Pro, Max, or Team subscription for knowledge, morning suggestions, and Sidekick." : "Claude Code runs on your own Claude subscription (Pro, Max, or Team), so a plan you already pay for powers everything: knowledge base, morning cards, Sidekick, computer use.")

                claudeStates

                if claude.preparing || claude.installing { MonoWaitLine("preparing claude code…") }
                OnboardingStatusText(claude.installStatus)

                if formStyle {
                    SettingsDetails(title: "Using Gmail and Google Calendar") {
                        SettingsProse("Connect them in Claude’s Settings → Connectors to use them in Sentient.")
                    }
                } else {
                    SettingsHairline()
                    SettingsProse("Gmail and Calendar can ride your claude.ai connectors: connect them once at claude.ai, under Settings, then Connectors, and Sentient's reads use them here.")
                }
            }
        }
        .onAppear {
            Task {
                await claude.refreshInstalled()
                await claude.refreshLoginStatus()
            }
        }
        .task(id: claude.loggingIn) {
            // The sign-in watcher: while the browser flow is out, quietly re-check every 2s —
            // the panel flips to the signed-in state by itself the moment the login lands.
            guard claude.loggingIn else { return }
            while !Task.isCancelled, claude.loggingIn, !claude.loggedIn {
                try? await Task.sleep(for: .seconds(2))
                await claude.refreshLoginStatus()
            }
        }
        .onDisappear { claudePreparationTask?.cancel() }
    }

    /// The Claude state machine: signed in (Use Claude in Settings; onboarding uses Continue) → browser
    /// out → install failed → the sign-in CTA (which lazily installs the CLI first).
    @ViewBuilder private var claudeStates: some View {
        if claude.loggedIn {
            OnboardingDoneLine(claude.plan.map { "Signed in to Claude Code · \($0) plan" }
                               ?? "Signed in to Claude Code")
            if backend == .claude {
                FrontierActiveLine("Sentient is running on your Claude.")
            } else if layout == .settingsGrid {
                SettingsPillButton(title: "Use Claude") {
                    prepareClaude(signIn: false)
                }
                .disabled(claude.preparing || claude.installing)
            }
        } else if claude.loggingIn {
            LoginLinkButton(url: claude.loginURL)
            Text("Finish signing in in your browser.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.body)
            MonoWaitLine("waiting for the browser sign-in…")
        } else if claude.installGaveUp && !claude.installed {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sentient couldn't finish installing Claude Code automatically.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Ink.body)
                SettingsProse("You can install it yourself in a minute with this Terminal command, then come back here:")
                Text("curl -fsSL https://claude.ai/install.sh | bash")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Ink.statusInk)
                    .textSelection(.enabled)
                SettingsPillButton(title: "Try again") { prepareClaude(signIn: true) }
                    .disabled(claude.preparing || claude.installing)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SettingsPillButton(title: claude.preparing || claude.installing ? "Setting up…" : "Sign in with Claude") {
                    prepareClaude(signIn: true)
                }
                .disabled(claude.preparing || claude.installing)
                OnboardingStatusText(claude.loginStatusLine)
            }
        }
    }

    private func prepareClaude(signIn: Bool) {
        claudePreparationTask = Task {
            guard await claude.ensureCurrent(), !Task.isCancelled else { return }
            await claude.refreshLoginStatus()
            guard !Task.isCancelled else { return }
            if signIn, !claude.loggedIn { claude.startLogin() }
            if claude.loggedIn {
                backendRaw = ModelBackend.claude.rawValue
                if layout == .settingsGrid { await ComputerUseSetup.instance(for: .cua).install() }
            }
        }
    }

    // MARK: - Configurable endpoints (OpenRouter · Custom + its local presets)

    private func endpointPanel(for preset: CustomProvider.Preset) -> some View {
        SettingsGroup(label: preset == .openRouter ? "Your OpenRouter"
                           : preset == .lmStudio ? "Your LM Studio" : "Your Endpoint") {
            VStack(alignment: .leading, spacing: 14) {
                switch preset {
                case .openRouter:
                    SettingsProse("Any model on OpenRouter, billed to your own key.")
                case .lmStudio:
                    SettingsProse(formStyle
                        ? "Use an image-capable model from LM Studio. Keep its local server running while you use Sentient."
                        : "A model running on your own hardware, through LM Studio's local server. Sentient's translator makes it a first-class engine, computer use included; whether the model is up to the job is the honest question (see the note when this tab opens).")
                case .custom:
                    SettingsProse("Any endpoint that speaks the OpenAI Responses API (a /v1/responses route). Base URL, model name, key if it needs one.")
                }
                if preset != .lmStudio {
                    if formStyle {
                        SettingsDetails(title: "Choosing a model for computer use") {
                            modelGuidance
                        }
                    } else { modelGuidance }
                }

                // OpenRouter's base URL is fixed — no field, the tab pins it itself.
                if preset != .openRouter {
                    fieldRow(label: "BASE URL",
                             placeholder: preset == .lmStudio
                                 ? CustomProvider.Preset.lmStudio.defaultBaseURL
                                 : "https://your-endpoint.example/v1",
                             text: $baseURL)
                }
                fieldRow(label: "MODEL",
                         placeholder: preset == .openRouter ? Self.kimiSlug
                             : preset == .lmStudio ? "the model id shown in LM Studio"
                             : "the model id your server expects",
                         text: $modelName)
                secureRow(label: preset == .openRouter ? "OPENROUTER API KEY" : "API KEY",
                          placeholder: preset == .openRouter ? "sk-or-…" : "optional for keyless servers")

                reasoningField

                SettingsProse(formStyle
                    ? "Test the model’s image support before using it."
                    : "Your model has to be able to see: Sentient acts on your Mac by looking at the screen, so a text-only model can't drive it. The test below checks that for you by asking your model to read a picture.")

                HStack(spacing: 10) {
                    SettingsPillButton(title: testing ? "Testing…" : "Test & Select",
                                       tint: Theme.Ink.bright) {
                        guard !testing else { return }
                        runTest(preset: preset)
                    }
                    if isActive(preset) {
                        FrontierActiveLine("This model is running Sentient.")
                    }
                }
                if let testVerdict {
                    SettingsProse(testVerdict)
                }

                if !formStyle {
                    SettingsHairline()
                    SettingsProse(PrivacyCopy.customProvider)
                }
            }
        }
    }

    private var modelGuidance: some View {
        SettingsProse("For computer use, consider GPT-6 Sol at low reasoning or Claude Sonnet 5 with reasoning off. Of the open-weights models we tested, Kimi K3 at low reasoning is the only one we can recommend for reliably driving computer use.")
    }

    /// The endpoint's ONE reasoning level — free text, because models speak different dialects
    /// (`none`, `low`, `xhigh`, `adaptive`, …), applied to every run this model powers (the
    /// Speed slider is ChatGPT's). Kimi wants low; Claude-class endpoints need none. Editing it
    /// re-runs the gate via the field's invalidate, since a wrong level can break the endpoint
    /// outright.
    private var reasoningField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow(label: "REASONING",
                     placeholder: "low · none · xhigh · whatever your model supports",
                     text: $reasoningRaw)
            if formStyle {
                Text("Applies wherever this model runs.").font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
            } else {
                MonoCaps("applies everywhere this model runs", size: 7.5, tracking: 1.6, color: Theme.Ink.deepMuted)
            }
        }
    }

    // MARK: - Pieces

    private func fieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: formStyle ? 14 : 11.5)).foregroundStyle(Theme.Ink.statusInk)
                .padding(.horizontal, 12).padding(.vertical, formStyle ? 11 : 8)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .onChange(of: text.wrappedValue) { invalidate() }
        }
    }

    /// Any edit to the endpoint retires the old verdict: a different model has to prove it can
    /// see for itself. Also drops the backend back to ChatGPT if the running engine just became
    /// unverified, so Sentient is never left pointed at an unproven model.
    private func invalidate() {
        guard verified || backend == .custom else { return }
        verified = false
        testVerdict = nil
        if backend == .custom { backendRaw = ModelBackend.chatgpt.rawValue }
    }

    private func secureRow(label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: formStyle ? 14 : 11.5)).foregroundStyle(Theme.Ink.statusInk)
                .padding(.horizontal, 12).padding(.vertical, formStyle ? 11 : 8)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1))
                .onChange(of: apiKey) {
                    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        Keychain.delete(CustomProvider.apiKeyAccount)
                    } else {
                        Keychain.set(CustomProvider.apiKeyAccount, trimmed)
                    }
                    invalidate()
                }
            if formStyle {
                Text("Stored in your Mac’s Keychain.").font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
            } else {
                MonoCaps("stored in your mac's keychain", size: 7.5, tracking: 1.6, color: Theme.Ink.deepMuted)
            }
        }
    }

    @ViewBuilder private func fieldLabel(_ label: String) -> some View {
        if formStyle {
            Text(["BASE URL": "Base URL", "MODEL": "Model", "REASONING": "Reasoning",
                  "API KEY": "API key", "OPENROUTER API KEY": "OpenRouter API key"][label] ?? label)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
        } else {
            MonoCaps(label, size: 8.5, tracking: 2.0, color: Theme.Ink.deepMuted)
        }
    }

    private func isActive(_ preset: CustomProvider.Preset) -> Bool {
        backend == .custom && savedPreset == preset && CustomProvider.current.isUsable
    }

    /// Flip the backend to the viewed tab's endpoint — reached ONLY through a passing
    /// Test & Select run, so an unproven model can never become the engine. Fields already
    /// autosave (@AppStorage); activation is just the choice becoming official.
    private func activate(_ preset: CustomProvider.Preset) {
        presetRaw = preset.rawValue
        guard CustomProvider.current.isUsable else { return }
        backendRaw = ModelBackend.custom.rawValue
        if layout == .settingsGrid { Task { await ComputerUseSetup.instance(for: .cua).install() } }
    }

    private func runTest(preset: CustomProvider.Preset) {
        // A pending probe cannot borrow the previous preset's ready state for Continue.
        verified = false
        // OpenRouter's URL is pinned (no field on that tab); elsewhere only fill an empty one.
        if preset == .openRouter {
            baseURL = preset.defaultBaseURL
        } else if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseURL = preset.defaultBaseURL
        }
        presetRaw = preset.rawValue   // the probe reads the SAVED provider — keep it current
        guard CustomProvider.current.isConfigured else {
            testVerdict = "✗ It needs a base URL and a model name first."
            return
        }
        testing = true
        testVerdict = "Preparing Codex CLI to test your model…"
        Task {
            // Custom endpoints run through Codex too. Test & Select must prepare an existing
            // older CLI just as it installs a missing one, before launching the vision probe.
            guard await CodexSetup.shared.ensureCurrent() else {
                testing = false
                verified = false
                testVerdict = CodexSetup.shared.installStatus ?? "✗ Codex CLI couldn't be prepared. Try again."
                return
            }
            testVerdict = "Showing your model a picture and asking it to read the number… local models can take a minute to load."
            let verdict = await CodexTrigger.$current.withValue(.probe) { await CodexCLI.probeCustomEndpoint() }
            await MainActor.run {
                testing = false
                switch verdict {
                case .available:
                    verified = true
                    activate(preset)   // Test & Select: a passing model becomes the engine
                    testVerdict = "✓ Your model answered and read the picture. Sentient is now running on it."
                case .notInstalled:
                    verified = false
                    testVerdict = "✗ Codex CLI couldn't be installed on this Mac (it runs the test). Check your connection and try again."
                case .notWorking(let detail):
                    verified = false
                    testVerdict = "✗ \(friendly(detail))"
                }
            }
        }
    }

    /// Reduce codex's raw stderr to one readable hint; the full detail stays in the console.
    /// A base URL missing its `/v1` is the single most common setup slip (codex appends
    /// `/responses` to whatever you give it, so the request lands on a route the server
    /// doesn't serve), so every failure carries that nudge when it applies.
    private func friendly(_ detail: String) -> String {
        let lowered = detail.lowercased()
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let v1Hint = trimmedURL.hasSuffix("/v1") ? ""
            : " Most servers also expect the base URL to end in /v1."
        if lowered.hasPrefix("blind") || lowered.contains("image input") || lowered.contains("multimodal") {
            return "This model can't see pictures, so it can't act on your Mac. Pick one that accepts images."
        }
        if lowered.contains("401") || lowered.contains("unauthorized") {
            return "The endpoint rejected the API key."
        }
        if lowered.contains("connection refused") || lowered.contains("error sending request") {
            return "Nothing is listening at that base URL. Is the server running?\(v1Hint)"
        }
        if lowered.contains("404") || lowered.contains("not found")
            || lowered.contains("unexpected endpoint") {
            return "The endpoint answered but has no /v1/responses route.\(v1Hint.isEmpty ? " It must support the OpenAI Responses API." : v1Hint)"
        }
        return "No answer from the endpoint.\(v1Hint) \(detail.prefix(180))"
    }
}

// MARK: - The engine tab

/// One tab in the engine strip: a fixed-size pill that reads like a place, not a button —
/// EVERY pill the same width and height so the row's geometry never shifts (scrollbars,
/// badges, and selection can't reflow it). Selected = elevated wash + white ring; the ACTIVE
/// engine wears the small green status dot (the same honest LED the health rows use). Badges
/// whisper in mono-caps under the label.
struct EngineTab: View {
    @Environment(\.settingsFormStyle) private var formStyle
    static var pillWidth: CGFloat { 176 }
    static var pillHeight: CGFloat { 52 }

    let label: String
    var badge: String? = nil
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if active { HealthDot(color: Theme.Ink.green) }
                    Text(formStyle ? label.replacingOccurrences(of: " Subscription", with: "") : label)
                        .font(.system(size: formStyle ? 15 : 12.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .white : Theme.Ink.body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.92)
                }
                if let badge {
                    if formStyle {
                        Text(label == "Custom" ? "Your endpoint" : badge.capitalized)
                            .font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary)
                    } else {
                        MonoCaps(badge, size: 7, tracking: 1.4,
                                 color: badge == "recommended" ? Theme.Ink.green.opacity(0.85) : .white.opacity(0.45))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(width: formStyle ? nil : Self.pillWidth, height: formStyle ? 68 : Self.pillHeight)
            .background(selected ? Theme.elevated : Color.white.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                selected ? Color.white.opacity(0.28) : Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The green "this engine is live" line — shared by the picker's endpoint panels and the
/// Settings pane's ChatGPT panel.
struct FrontierActiveLine: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            HealthDot(color: Theme.Ink.green)
            Text(text).font(.system(size: formStyle ? 14 : 12, weight: .medium)).foregroundStyle(.white)
        }
    }
}
