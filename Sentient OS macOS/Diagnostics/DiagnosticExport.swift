// Builds an allowlisted support snapshot and saves it only to the user's chosen JSON file.
// collect() reads status and bounded history; save() owns the native Save dialog. No upload path.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import AppKit
import AVFoundation
import Darwin
import Speech
import UniformTypeIdentifiers

@MainActor
enum DiagnosticExport {
    static let disclosure = "Includes your account email, system and app status, the last 15 saved prompts and final responses, any saved errors, and technical Double Tap and overnight logs. No screen captures, captured screen content, computer-use history, or knowledge base (including Double Tap writing examples) is included."
    static let sharingNote = "Saved prompts and responses may contain personal information. Review the file before sharing. Nothing is sent automatically."

    struct Snapshot: Encodable, Sendable {
        let schemaVersion = 1
        let exportedAt: Date
        let disclosure = DiagnosticExport.disclosure
        let notes = [
            "Prompt history contains at most 15 saved requests, newest first. Requests are capped at 300 characters when recorded; final messages and the latest recovery error are retained.",
            "Common credentials, URLs, local paths and contact details in history text are scrubbed. Account email is included explicitly. Review free text before sharing.",
            "Technical history retains up to 50 Double Tap attempts, 30 overnight attempts and 100 structured errors. It starts with this feature; older attempts are unavailable.",
            "Missing fields mean unavailable or not yet recorded, not a successful run. Unfinished prompts have no saved final result.",
            "Connector and CLI status uses local cached/declarative state unless a field says otherwise; it does not prove that a service is reachable.",
            "Double Tap pasteDispatched means paste keystrokes were sent; delivery to the intended field was not verified. No drafts, screenshots, tool calls, or knowledge files are attached."
        ]
        let system: SystemInfo
        let app: AppInfo
        let ai: AIInfo
        let sources: [String: Bool]
        let connectors: [ConnectorInfo]
        let permissions: [String: String]
        let promptHistory: [SidekickHistory.DiagnosticEntry]
        let doubleTap: DoubleTapInfo
        let overnight: OvernightInfo
        let technicalHistory: DiagnosticHistory.State?
        let unavailableSections: [String]
    }

    struct SystemInfo: Encodable, Sendable {
        let hardwareModel: String?
        let chip: String?
        let ramBytes: UInt64
        let processorCount: Int
        let macOS: String
        let osBuild: String?
        let systemUptimeSeconds: Double
        let diskAvailableBytes: Int64?
        let diskAvailableForImportantUsageBytes: Int64?
        let diskTotalBytes: Int64?
        let timeZone: String
        let onACPower: Bool
        let batteryPercent: Int?
        let lowPowerMode: Bool
        let thermalState: String
    }

    struct AppInfo: Encodable, Sendable {
        let version: String
        let build: String
        let buildConfiguration: String
        let launchAtLogin: Bool
        let onboardingComplete: Bool
        let analysisRunning: Bool
        let computerTaskRunning: Bool
        let localModelAvailable: Bool
        let crashReportsEnabled: Bool
        let extendedAnalyticsEnabled: Bool
    }

    struct CLIInfo: Encodable, Sendable {
        let installed: Bool
        let version: String?
        let loggedIn: Bool?
        let plan: String?
        let email: String?
        let statusSource: String
    }

    struct AIInfo: Encodable, Sendable {
        let selectedBackend: String
        let customProvider: String?
        let customModel: String?
        let codex: CLIInfo
        let claude: CLIInfo
        let computerUseHelperInstalled: Bool
    }

    struct ConnectorInfo: Encodable, Sendable {
        let provider: String
        let origin: String
        let status: String
        let knowledgeEnabled: Bool
        let lastCheckedAt: Date?
    }

    struct DoubleTapInfo: Encodable, Sendable {
        let enabled: Bool
        let drafting: Bool
        let provider: String
        let model: String?
        let api: String
    }

    struct OvernightInfo: Encodable, Sendable {
        let enabled: Bool
        let productionEnabled: Bool
        let developerEnabled: Bool
        let configuredMinutesAfterMidnight: Int
        let initialAnalysisCompletedAt: Date?
        let autoEnableDueAt: Date?
        let autoEnableFired: Bool
        let nextArmedWakeAt: Date?
        let helperHealth: String
        let needsSetup: Bool
        let allowBattery: Bool
        let currentPowerBlockReason: String?
        let latestCaution: String?
        let latestCautionAt: Date?
    }

    static func collect(appState: AppState) async -> Snapshot {
        // Passive, bounded probes only. Neither path installs software or requests permissions.
        async let helperHealth = WakeHelperClient.shared.healthProbe()
        async let claudeStatus = ClaudeAuth.refresh()
        let (helper, claude) = await (helperHealth, claudeStatus)
        let defaults = UserDefaults.standard
        let scheduler = appState.scheduler
        var unavailable: [String] = []
        let prompts: [SidekickHistory.DiagnosticEntry]
        do { prompts = try SidekickHistory.diagnosticEntries() }
        catch { prompts = []; unavailable.append("prompt_history_unreadable") }
        let history: DiagnosticHistory.State?
        do { history = try DiagnosticHistory.snapshot() }
        catch { history = nil; unavailable.append("technical_history_unreadable") }

        let info = ProcessInfo.processInfo
        let volume = try? URL.sentientSupport.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        let codex = CodexSetup.shared
        let backend = ModelBackend.current
        let provider = DoubleTapProvider.current
        let caution = OvernightCaution.latest()
        let prodEnabled = defaults.bool(forKey: OvernightScheduler.prodEnabledKey)
        let devEnabled = defaults.bool(forKey: OvernightScheduler.enabledKey)
        let allowBattery = defaults.bool(forKey: OvernightScheduler.allowBatteryKey)
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return Snapshot(exportedAt: Date(), system: SystemInfo(
            hardwareModel: systemString("hw.model"), chip: systemString("machdep.cpu.brand_string"),
            ramBytes: info.physicalMemory, processorCount: info.processorCount,
            macOS: info.operatingSystemVersionString, osBuild: systemString("kern.osversion"),
            systemUptimeSeconds: info.systemUptime,
            diskAvailableBytes: volume?.volumeAvailableCapacity.map(Int64.init),
            diskAvailableForImportantUsageBytes: DiskSpace.available(),
            diskTotalBytes: volume?.volumeTotalCapacity.map(Int64.init),
            timeZone: TimeZone.current.identifier, onACPower: PowerState.onACPower(),
            batteryPercent: PowerState.batteryPercent(), lowPowerMode: PowerState.lowPowerMode,
            thermalState: PowerState.thermalLabel),
            app: AppInfo(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                buildConfiguration: configuration, launchAtLogin: LoginItem.isEnabled,
                onboardingComplete: defaults.bool(forKey: AppState.onboardingKey),
                analysisRunning: PipelineActivity.shared.isRunning,
                computerTaskRunning: appState.commandCoordinator.run.isRunning,
                localModelAvailable: ModelLocator.resolve() != nil,
                crashReportsEnabled: (defaults.object(forKey: "diagnosticsEnabled") as? Bool) ?? true,
                extendedAnalyticsEnabled: (defaults.object(forKey: "analyticsEnabled") as? Bool) ?? true),
            ai: AIInfo(selectedBackend: backend.rawValue,
                customProvider: backend == .custom ? CustomProvider.current.preset.rawValue : nil,
                customModel: backend == .custom ? clean(CustomProvider.current.modelName) : nil,
                codex: CLIInfo(installed: CodexCLI.locateBinary() != nil, version: codex.version.map(clean),
                    loggedIn: codex.loginStatusChecked ? codex.loggedIn : nil,
                    plan: CodexAuth.currentPlan()?.raw, email: CodexAuth.diagnosticEmail(), statusSource: "cached_login_local_claims"),
                claude: CLIInfo(installed: ClaudeCLI.locateBinary() != nil, version: ClaudeSetup.shared.version.map(clean),
                    loggedIn: claude.loggedIn, plan: claude.plan, email: claude.email.flatMap(MailAccount.normalizedEmail),
                    statusSource: "local_cli_probe_with_cached_fallback"), computerUseHelperInstalled: OpenAIComputerUse.isInstalled),
            sources: sourceStatus(defaults), connectors: connectorStatus(),
            permissions: ["fullDiskAccess": String(Permissions.hasFullDiskAccess()),
                "accessibility": String(Permissions.hasAccessibility()), "screenRecording": String(Permissions.hasScreenRecording()),
                "microphone": microphoneStatus(), "speechRecognition": speechStatus(),
                "nativeHelperAccessibilityCached": String(ComputerUseGate.shared.helperAccessibility),
                "nativeHelperScreenRecordingCached": String(ComputerUseGate.shared.helperScreen),
                "nativeHelperAutomationCached": String(describing: ComputerUseGate.shared.automation),
                "nativeHelperNeedsRestartCached": String(ComputerUseGate.shared.nativeRestartRequired)],
            promptHistory: prompts,
            doubleTap: DoubleTapInfo(enabled: DoubleTap.isEnabled, drafting: DoubleTap.shared.isDrafting,
                provider: provider.rawValue, model: provider == .sentient ? nil : clean(provider.model), api: provider.api.rawValue),
            overnight: OvernightInfo(enabled: prodEnabled || devEnabled, productionEnabled: prodEnabled,
                developerEnabled: devEnabled, configuredMinutesAfterMidnight: OvernightScheduler.configuredMinutes,
                initialAnalysisCompletedAt: OvernightScheduler.firstCycleCompletedAt,
                autoEnableDueAt: OvernightScheduler.autoEnableFireDate,
                autoEnableFired: defaults.bool(forKey: OvernightScheduler.autoEnableFiredKey),
                nextArmedWakeAt: scheduler.nextWakeAt, helperHealth: String(describing: helper),
                needsSetup: scheduler.needsSchedulerSetup, allowBattery: allowBattery,
                currentPowerBlockReason: PowerState.overnightBlockReason(allowBattery: allowBattery),
                latestCaution: caution?.kind.rawValue, latestCautionAt: caution?.date),
            technicalHistory: history, unavailableSections: unavailable)
    }

    static func encoded(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    static func save(appState: AppState) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Sentient-Diagnostics-\(Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")).json"
        panel.title = "Export diagnostic file"
        panel.message = "Save a diagnostics file to review and send to the developers. Nothing is sent automatically."
        let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else { panel.begin { continuation.resume(returning: $0) } }
        }
        guard result == .OK, let url = panel.url else { return nil }
        let data = try encoded(await collect(appState: appState))
        try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
        return url
    }

    private static func sourceStatus(_ defaults: UserDefaults) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for source in ["desktop", "documents", "downloads", "whatsapp", "imessage", "notes", "gmail", "calendar"] {
            result[source] = (defaults.object(forKey: "dbg.run.\(source)") as? Bool)
                ?? ["desktop", "documents", "downloads"].contains(source)
        }
        result["customFolders"] = !CustomRoots.urls.isEmpty
        result["appleMail"] = !AppleMailSelection.accounts.isEmpty
        result["appleCalendar"] = AppleCalendarSource.isEnabled
        return result
    }

    private static func connectorStatus() -> [ConnectorInfo] {
        // Curated service names only. No user-supplied labels, server URLs, account IDs, or tool schemas.
        var result: [ConnectorInfo] = []
        var seen: Set<String> = []
        for origin in [ConnectorCensus.DetectedConnector.Origin.chatgpt, .claude] {
            result += ConnectorCensus.cached(for: origin).map { connector in
                seen.insert(connector.id)
                let provider = ConnectorRegistry.pack(forSlug: connector.slug)?.slug ?? "other"
                let knowledgeEnabled = connector.slug == "gmail" ? UserDefaults.standard.bool(forKey: "dbg.run.gmail")
                    : connector.slug == "google-calendar" ? UserDefaults.standard.bool(forKey: "dbg.run.calendar")
                    : ConnectorRegistry.isKBEnabled(connector.slug)
                return ConnectorInfo(provider: provider, origin: origin.rawValue,
                    status: connector.healthy ? "declared_connected" : "unavailable", knowledgeEnabled: knowledgeEnabled,
                    lastCheckedAt: connector.lastSeen > .distantPast ? connector.lastSeen : nil)
            }
        }
        result += DirectMCPStore.connections().map { connection in
            seen.insert(connection.detected.id)
            return ConnectorInfo(provider: connection.provider?.slug ?? "other", origin: "direct",
                status: connection.state.rawValue, knowledgeEnabled: ConnectorRegistry.isKBEnabled(connection.slug),
                lastCheckedAt: connection.verifiedAt)
        }
        for selected in ConnectorRegistry.kbEnabledConnectors() where !seen.contains(selected.id) {
            result.append(ConnectorInfo(provider: ConnectorRegistry.pack(for: selected)?.slug ?? "other",
                origin: selected.origin.rawValue, status: "selected_but_unavailable", knowledgeEnabled: true, lastCheckedAt: nil))
        }
        return result.sorted { ($0.origin, $0.provider) < ($1.origin, $1.provider) }
    }

    private static func microphoneStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_asked"
        @unknown default: "unknown"
        }
    }

    private static func speechStatus() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_asked"
        @unknown default: "unknown"
        }
    }

    private static func clean(_ value: String) -> String { String(CrashReporting.scrub(text: value).prefix(160)) }

    private static func systemString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
