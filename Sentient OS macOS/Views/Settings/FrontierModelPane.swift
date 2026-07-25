//
//  FrontierModelPane.swift
//  Sentient OS macOS
//
//  Settings → Frontier Model Choice: which frontier engine powers the cloud ~10% of Sentient
//  (the on-device model does the rest). Four engine tabs: ChatGPT (recommended, activates
//  directly) · Claude (coming soon) · OpenRouter (prefilled, Kimi K3 forward — the only tested
//  model that reliably drives computer use) · Custom (any Responses-API endpoint, with an
//  LM Studio preset that prefills the base URL and raises the honest local-models warning).
//  Activation is gated on the vision probe: "Use this model" appears only after the
//  model PROVES it can read a screenshot (Test Model). Writes ModelBackend/CustomProvider (the
//  one source of truth); everything applies to the very next run, no restart.
//

import SwiftUI

struct FrontierModelPane: View {

    /// The five engine tabs. OpenRouter, LM Studio, and Custom share the endpoint plumbing;
    /// LM Studio's tab raises the honest local-models warning on first visit (model
    /// capability, not plumbing, is the local blocker — the translator solved the plumbing).
    private enum Tab: String, CaseIterable, Identifiable {
        case chatgpt, claude, openRouter, lmStudio, custom
        var id: Self { self }

        var label: String {
            switch self {
            case .chatgpt:    return "ChatGPT Subscription"
            case .claude:     return "Claude Subscription"
            case .openRouter: return "OpenRouter"
            case .lmStudio:   return "LM Studio"
            case .custom:     return "Custom"
            }
        }

        var badge: String? {
            switch self {
            case .chatgpt:  return "recommended"
            case .claude:   return "coming soon"
            case .lmStudio: return "local"
            case .custom:   return "local"
            case .openRouter: return nil
            }
        }
    }

    /// The one model that cleared the computer-use bar in the 2026-07-24 survey (~10 models,
    /// real tasks). Prefilled on the OpenRouter tab and named in its note.
    private static let kimiSlug = "moonshotai/kimi-k3"

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    @AppStorage(CustomProvider.presetKey) private var presetRaw = CustomProvider.Preset.openRouter.rawValue
    @AppStorage(CustomProvider.baseURLKey) private var baseURL = ""
    @AppStorage(CustomProvider.modelNameKey) private var modelName = ""
    @AppStorage(CustomProvider.reasoningKey) private var reasoningRaw = "low"
    /// Set only by a passing Test Model run; any edit below clears it.
    @AppStorage(CustomProvider.visionVerifiedKey) private var verified = false

    @State private var tab: Tab = .chatgpt
    @State private var apiKey = ""
    @State private var showLocalWarning = false
    /// The local-reality popup fires once per pane visit, on the LM Studio tab.
    @State private var localWarningShown = false

    /// The Test Model probe, narrated: nil = untested, "…" = running, ✓/✗ lines otherwise.
    @State private var testing = false
    @State private var testVerdict: String?

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }
    private var savedPreset: CustomProvider.Preset { CustomProvider.Preset(rawValue: presetRaw) ?? .openRouter }

    /// The tab wearing the "active engine" dot.
    private var activeTab: Tab {
        guard backend == .custom else { return .chatgpt }
        switch savedPreset {
        case .openRouter: return .openRouter
        case .lmStudio:   return .lmStudio
        case .custom:     return .custom
        }
    }

    var body: some View {
        SettingsPane(title: "Frontier Model Choice",
                     whisper: "Sentient's on-device model does about 90% of the thinking. This is the engine behind the last 10%.") {
            VStack(alignment: .leading, spacing: 26) {
                SettingsProse("Everything Sentient reads stays on this Mac. For the heavy cloud reasoning, the knowledge base, the morning cards, Sidekick, it taps one frontier model of your choosing: your ChatGPT subscription, your Claude plan (coming soon), or a model endpoint of your own.")

                tabStrip

                Group {
                    switch tab {
                    case .chatgpt:    chatgptPanel
                    case .claude:     claudePanel
                    case .openRouter: endpointPanel(for: .openRouter)
                    case .lmStudio:   endpointPanel(for: .lmStudio)
                    case .custom:     endpointPanel(for: .custom)
                    }
                }
                .id(tab)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tab)
        }
        .onAppear {
            tab = activeTab
            apiKey = CustomProvider.apiKey ?? ""
        }
        .alert("A note on local frontier models", isPresented: $showLocalWarning) {
            Button("Understood") {}
        } message: {
            Text("Most models you can run locally are far too weak for computer use; in our testing only Kimi K3 performed well enough, and most other open-weights models aren't multimodal (can't see), which computer use requires.\n\nIf you can somehow run Kimi K3 locally, this preset is all yours.\n\nOtherwise run it through OpenRouter, or if privacy is the concern, both OpenAI and Claude subscriptions let you turn off training on your data in your account settings on their own site. Those frontier options remain the best way to use Sentient.")
        }
    }

    // MARK: - The engine tab strip

    /// A FIXED two-row grid of equal-width pills (3 + 2) — deliberately not a flow layout: a
    /// scrollbar appearing must never reflow the strip (the jumpy-rewrap of 2026-07-24), and
    /// the fixed rows keep the pane comfortable at the window's normal width.
    private var tabStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                pill(.chatgpt); pill(.claude); pill(.openRouter)
            }
            HStack(spacing: 8) {
                pill(.lmStudio); pill(.custom)
            }
        }
        .fixedSize()
    }

    private func pill(_ t: Tab) -> some View {
        EngineTab(label: t.label, badge: t.badge,
                  selected: tab == t, active: activeTab == t && isActiveEngineHealthy(t)) {
            selectTab(t)
        }
    }

    /// The active dot stays honest: a custom engine only wears it once it's proven usable.
    private func isActiveEngineHealthy(_ t: Tab) -> Bool {
        t == .chatgpt || CustomProvider.current.isUsable
    }

    /// Browsing tabs never disturbs a live engine: fields are only prefilled while nothing
    /// custom is active (Test Model and Use-this-model pin the right values when the user
    /// actually acts). The LM Studio tab raises the local-reality popup once per visit.
    private func selectTab(_ t: Tab) {
        tab = t
        testVerdict = nil
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

    // MARK: - ChatGPT

    private var chatgptPanel: some View {
        SettingsGroup(label: "Your ChatGPT") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse("Codex runs on your own ChatGPT subscription, so a plan you already pay for powers everything: knowledge base, morning cards, Sidekick, and the Gmail and Calendar connectors. Recommended, because the connectors only exist here.")
                if backend == .chatgpt {
                    activeLine("Sentient is running on your ChatGPT.")
                    SettingsProse("Login and plan live in Permissions & Health.")
                } else {
                    SettingsPillButton(title: "Use ChatGPT") {
                        backendRaw = ModelBackend.chatgpt.rawValue
                        testVerdict = nil
                    }
                }
            }
        }
    }

    // MARK: - Claude (coming soon)

    private var claudePanel: some View {
        SettingsGroup(label: "Your Claude Plan", badge: "coming soon") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsProse("Your Claude subscription will power Sentient the same way ChatGPT does today, through Claude Code's own command line. It's on the bench and coming soon.")
                MonoCaps("claude -p · in the works", size: 8.5, tracking: 1.6, color: Theme.Ink.deepMuted)
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
                    SettingsProse("A model running on your own hardware, through LM Studio's local server. Sentient's translator makes it a first-class engine, computer use included; whether the model is up to the job is the honest question (see the note when this tab opens).")
                case .custom:
                    SettingsProse("Any endpoint that speaks the OpenAI Responses API (a /v1/responses route). Base URL, model name, key if it needs one.")
                }
                if preset != .lmStudio {
                    SettingsProse("One important note: of every model we tested, Kimi K3 at low reasoning is the only open-weights model that can reliably drive computer use. Claude Sonnet 5 with reasoning off, and GPT-5.6 Sol at low reasoning are also great options we can stand by.")
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

                SettingsProse("Your model has to be able to see: Sentient acts on your Mac by looking at the screen, so a text-only model can't drive it. The test below checks that for you by asking your model to read a picture.")

                HStack(spacing: 10) {
                    SettingsPillButton(title: testing ? "Testing…" : "Test & Select") {
                        guard !testing else { return }
                        runTest(preset: preset)
                    }
                    if isActive(preset) {
                        activeLine("This model is running Sentient.")
                    }
                }
                if let testVerdict {
                    SettingsProse(testVerdict)
                }

                SettingsHairline()
                SettingsProse("Gmail and Calendar ride your ChatGPT account, so they sit out while a custom model is active. Everything else works, and your data still never leaves this Mac except what the model itself is sent.")
            }
        }
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
            MonoCaps("applies everywhere this model runs", size: 7.5, tracking: 1.6,
                     color: Theme.Ink.deepMuted)
        }
    }

    // MARK: - Pieces

    private func activeLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            HealthDot(color: Theme.Ink.green)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        }
    }

    private func fieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoCaps(label, size: 8.5, tracking: 2.0, color: Theme.Ink.deepMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.statusInk)
                .padding(.horizontal, 12).padding(.vertical, 8)
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
            MonoCaps(label, size: 8.5, tracking: 2.0, color: Theme.Ink.deepMuted)
            SecureField(placeholder, text: $apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.statusInk)
                .padding(.horizontal, 12).padding(.vertical, 8)
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
            MonoCaps("stored in your mac's keychain", size: 7.5, tracking: 1.6, color: Theme.Ink.deepMuted)
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
    }

    private func runTest(preset: CustomProvider.Preset) {
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
        testVerdict = "Showing your model a picture and asking it to read the number… local models can take a minute to load."
        Task {
            let verdict = await CodexCLI.probeCustomEndpoint()
            await MainActor.run {
                testing = false
                switch verdict {
                case .available:
                    verified = true
                    activate(preset)   // Test & Select: a passing model becomes the engine
                    testVerdict = "✓ Your model answered and read the picture. Sentient is now running on it."
                case .notInstalled:
                    verified = false
                    testVerdict = "✗ Codex CLI is missing on this Mac. Install it in Permissions & Health first; it's the engine room even for custom models."
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
private struct EngineTab: View {
    static let pillWidth: CGFloat = 176
    static let pillHeight: CGFloat = 52

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
                    Text(label)
                        .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .white : Theme.Ink.body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.92)
                }
                if let badge {
                    MonoCaps(badge, size: 7, tracking: 1.4,
                             color: badge == "recommended" ? Theme.Ink.green.opacity(0.85)
                                                           : .white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(width: Self.pillWidth, height: Self.pillHeight)
            .background(selected ? Theme.elevated : Color.white.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                selected ? Color.white.opacity(0.28) : Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }
}

#Preview("Frontier Model Choice") {
    FrontierModelPane()
        .background(Theme.bg)
        .frame(width: 720, height: 820)
}
