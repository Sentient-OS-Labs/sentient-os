// Owns the single analysis task for the app, independent of every window. Persists intent,
// admits work through shared power checks, and drains cancellation before another run starts.
// Doc: Documentation - Ingestion Pipeline.md

import Foundation
import Observation

@MainActor @Observable
final class ProcessingCoordinator {
    static let shared = ProcessingCoordinator()

    enum State: Equatable {
        case idle, scheduled, loadingModel, processing, preparing, stopping, paused, completed, diskFull
        case waiting(Wait), failed(CycleFailure)
    }
    enum Wait: Equatable {
        case power(PowerState.Block), model, sources
    }
    enum Timing: String, CaseIterable { case now, overnight }
    private enum Stop { case user, power, stalled, ceiling, cancelled }

    private(set) var state: State = .idle
    private(set) var progress = RunProgress()
    private(set) var prepStatus = "Preparing your knowledge…"
    private(set) var prepSubtext: String?
    private(set) var thought: String?
    private(set) var updatingExistingKnowledge = false
    private(set) var record: ProcessingPlan.Record {
        didSet { ProcessingPlan.save(record, to: defaults) }
    }
    private(set) var initialComplete: Bool
    private(set) var isBusy = false
    private(set) var isSuspended = false
    private(set) var activeRequest: ProcessingRequest?
    private(set) var knowledgeRevision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var requestOverride: ProcessingRequest?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var stopReason: Stop?
    @ObservationIgnored private var lastProgressAt = Date()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var lastHeartbeatAt = Date.distantPast
    @ObservationIgnored private var helperHeld = false
    @ObservationIgnored private var helperRelease: Task<Void, Never>?
    @ObservationIgnored private var diagnosticID: UUID?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var carried = RunProgress()

    #if DEBUG
    static func preview(state: State) -> ProcessingCoordinator {
        let instance = ProcessingCoordinator(defaults: UserDefaults(suiteName: "ai.sentient.processing-preview.\(UUID())")!)
        instance.state = state
        return instance
    }
    func setPreviewProgress(_ progress: RunProgress) { self.progress = progress }
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        record = ProcessingPlan.recovered(ProcessingPlan.read(defaults))
        initialComplete = ProcessingPlan.initialCompletedAt(defaults) != nil
        ProcessingPlan.save(record, to: defaults)
        switch record.status {
        case .scheduled: state = .scheduled
        case .paused: state = .paused
        case .completed: state = .completed
        case .failed: state = .paused
        default: break
        }
    }

    var batteryFloor: Int { initialComplete ? PowerState.iterativeBatteryFloor : PowerState.initialBatteryFloor }
    var paused: Bool { record.status == .paused }
    var hasPendingFirstNight: Bool { !initialComplete && record.status == .scheduled }
    var needsAttention: Bool {
        switch state {
        case .waiting, .paused, .diskFull, .failed: true
        default: false
        }
    }
    var statusLine: String {
        switch state {
        case .idle: return initialComplete ? "Analysis is up to date" : "Ready to build your knowledge"
        case .scheduled:
            if let due = record.due { return "Scheduled for \(Self.scheduleLabel(due))" }
            return "Scheduled for the next 3 AM"
        case .waiting(.model): return "Waiting for the on-device model"
        case .waiting(.sources): return "Choose sources to analyze"
        case .waiting(.power(.thermal)): return "Waiting for your Mac to cool down"
        case .waiting(.power): return "Waiting for power"
        case .loadingModel: return activeRequest?.connectors.isEmpty == true ? "Connecting to your sources" : "Loading the on-device model"
        case .processing: return "Analyzing your sources"
        case .preparing: return "Building your knowledge"
        case .stopping: return "Pausing analysis safely"
        case .paused: return "Analysis paused"
        case .completed: return record.notice == nil ? "Analysis complete" : "Some sources need another try"
        case .diskFull: return "Analysis needs disk space"
        case .failed: return "Analysis needs attention"
        }
    }

    var waitingDetail: String {
        switch state {
        case .waiting(.power(.thermal)): return "Your progress is saved. Analysis will resume when your Mac cools down."
        case .waiting(.power(.unknown)): return "Connect your Mac to power. Its battery level could not be read."
        case .waiting(.power(.onBattery)): return "Connect your Mac to power, or allow battery processing in Analysis."
        case .waiting(.sources): return "Select sources in Settings, then retry analysis."
        case .waiting(.model): return "The model is downloading in the background. Sidekick is ready to use."
        default: return "Plug in your Mac or make sure the battery is at least \(batteryFloor)%."
        }
    }

    static func scheduleLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Persist before the caller marks onboarding complete. Only explicit Run now opens progress.
    func choose(_ timing: Timing) {
        guard !isBusy else { return }
        requestOverride = nil
        carried = RunProgress()
        if timing == .overnight {
            record = .init(status: .scheduled, trigger: .overnight,
                           due: OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes))
            state = .scheduled
        } else {
            record = .init(status: .requested, trigger: .onboarding)
            state = .idle
        }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.checkPendingWork()
                await self.checkRunningWork()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        checkPendingWork()
    }

    @discardableResult
    func requestNow(_ request: ProcessingRequest? = nil, trigger: ProcessingPlan.Trigger = .manual) -> Bool {
        guard !isBusy, !isSuspended else { return false }
        if record.status != .paused && record.status != .requested { carried = RunProgress() }
        requestOverride = request
        record = .init(status: .requested, trigger: trigger)
        startMonitoring()
        checkPendingWork()
        return true
    }

    func retry() { _ = requestNow(requestOverride) }
    func pause() {
        if isBusy { stop(.user) }
        else {
            record.status = .paused; record.due = nil
            state = .paused
        }
    }

    /// The scheduler never queues a second analysis or overrides an explicit pause.
    func runScheduled() async {
        guard !isBusy, !paused, !isSuspended, record.status != .requested else { return }
        requestOverride = nil
        let request = ProcessingRequest.current()
        if let blocked = admission(request, scheduled: true) {
            let diagnosticID = DiagnosticHistory.begin(.overnight, provider: ModelBackend.current.rawValue)
            let reason: String
            switch blocked {
            case .power(let block): reason = block.rawValue
            case .model: reason = "model_missing"
            case .sources: reason = "no_sources"
            }
            DiagnosticHistory.finish(.overnight, id: diagnosticID, outcome: .blocked, reason: reason)
            Analytics.signal("Scheduler.gated", parameters: ["reason": reason])
            deferNight(notice: detail(for: blocked))
            return
        }
        carried = RunProgress()
        record = .init(status: .requested, trigger: .overnight)
        begin(request)
        let ownedTask = task
        // Editing tomorrow's schedule must not cancel today's app-owned task.
        await ownedTask?.value
    }

    func deferNight(notice: String) {
        guard !isBusy, !paused else { return }
        record = .init(status: .scheduled, trigger: .overnight,
            due: OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes), notice: notice)
        state = .scheduled
    }

    /// Reset must invalidate pending intent before it wipes checkpoints. A draining task retains
    /// ownership and Reset waits for it; no callback can recreate knowledge after the wipe.
    func reset() async {
        await suspend()
        requestOverride = nil; carried = RunProgress(); progress = RunProgress()
        defaults.removeObject(forKey: ProcessingPlan.key)
        defaults.removeObject(forKey: ProcessingPlan.initialCompletedKey)
        record = .init(); initialComplete = false; state = .idle
    }

    /// Reset and Uninstall hold this fence across every suspension during teardown.
    func suspend() async {
        isSuspended = true
        monitor?.cancel(); monitor = nil
        if isBusy { stop(.cancelled); await task?.value }
        await WritingStyle.cancelSetupAndDrain()
    }

    func resumeMonitoring() {
        isSuspended = false
        startMonitoring()
    }

    private var power: PowerState.Snapshot {
        return PowerState.snapshot()
    }

    private func admission(_ request: ProcessingRequest, scheduled: Bool) -> Wait? {
        guard request.hasSources else { return .sources }
        let allowBattery = (defaults.object(forKey: OvernightScheduler.allowBatteryKey) as? Bool) ?? true
        if let block = PowerState.block(power, initial: !initialComplete, allowBattery: allowBattery,
                                        scheduled: scheduled) { return .power(block) }
        if !request.connectors.isEmpty && request.modelPath == nil { return .model }
        return nil
    }

    private func detail(for wait: Wait) -> String {
        switch wait {
        case .model: "Analysis couldn't start because the on-device model wasn't ready."
        case .sources: "Analysis couldn't start because no sources were selected."
        case .power(.thermal): "Analysis waited because your Mac was too warm."
        case .power(.unknown): "Analysis couldn't read the battery level. Connect your Mac to power."
        case .power(.onBattery): "Analysis waited for your Mac to be plugged in."
        case .power(.batteryLow): "Analysis needed power or at least \(batteryFloor)% battery."
        }
    }

    private func checkPendingWork() {
        guard !isBusy, !isSuspended, record.status == .requested else { return }
        var request = requestOverride ?? .current()
        if request.modelPath == nil { request.modelPath = ModelLocator.resolve() }
        if let blocked = admission(request, scheduled: false) {
            state = .waiting(blocked)
            if blocked == .model, ModelDownload.shared.phase == .idle { ModelDownload.shared.kickIfNeeded() }
            return
        }
        begin(request)
    }

    private func begin(_ request: ProcessingRequest) {
        guard !isBusy, !isSuspended else { return }
        isBusy = true
        activeRequest = request
        PipelineActivity.shared.acquire()
        stopReason = nil; runID = UUID()
        let id = runID
        record.status = .running; record.due = nil; record.notice = nil
        let trigger = record.trigger
        startedAt = Date(); lastProgressAt = Date(); lastHeartbeatAt = .distantPast
        updatingExistingKnowledge = FileManager.default.fileExists(atPath: VaultGenerator.vaultRoot.path)
        thought = nil; prepSubtext = nil
        state = .loadingModel
        if carried.done == 0 { progress = RunProgress() }
        // Hold system idle sleep without forcing the display to stay illuminated.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Sentient analysis in the background")
        let backend = ModelBackend.current
        task = Task(priority: .utility) {
            await ModelBackend.$runOverride.withValue(backend) {
                await CodexTrigger.$current.withValue(trigger.diagnostic) {
                    await self.perform(request, id: id, trigger: trigger)
                }
            }
            runID = UUID() // queued progress callbacks cannot overwrite the final state
            await releaseAwake()
            releaseSystemActivity()
            PipelineActivity.shared.release()
            diagnosticID = nil
            isBusy = false
            task = nil
        }
    }

    private func perform(_ request: ProcessingRequest, id: UUID, trigger: ProcessingPlan.Trigger) async {
        let scheduled = trigger == .overnight
        let diagnosticID = scheduled ? DiagnosticHistory.begin(.overnight, provider: ModelBackend.current.rawValue) : nil
        self.diagnosticID = diagnosticID
        if scheduled {
            Analytics.signal("Scheduler.overnightStarted")
            helperHeld = await WakeHelperClient.shared.beginAwake(timeout: 1800)
            if !helperHeld {
                record = .init(status: .scheduled, trigger: .overnight,
                    due: OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes),
                    notice: "Overnight wake needs attention. Open Settings, Permissions & Health.")
                state = .scheduled
                if let diagnosticID { DiagnosticHistory.finish(.overnight, id: diagnosticID, outcome: .blocked, reason: "wake_helper") }
                return
            }
        }
        if Task.isCancelled { finishStopped(RunProgress()); return }
        let report: @Sendable (RunProgress) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self, self.runID == id, self.stopReason == nil else { return }
                self.lastProgressAt = Date()
                self.progress = Self.composed(self.carried, p)
                if self.state == .loadingModel { self.state = .processing }
            }
        }
        let result = await execute(request, scheduled: scheduled, id: id, report: report)
        progress = Self.composed(carried, result.progress)
        // A valid vault can be published before a later proactive stage fails or is paused.
        if request.fullCycle { knowledgeRevision += 1 }
        if Task.isCancelled || stopReason != nil {
            finishStopped(result.progress)
            if let diagnosticID { DiagnosticHistory.finish(.overnight, id: diagnosticID, outcome: .stopped, reason: "paused") }
            return
        }
        if result.progress.diskFull {
            state = .diskFull; record.status = .failed
            record.notice = "Free up disk space, then retry analysis."
            if scheduled { OvernightCaution.record(.diskFull) }
        } else if let failure = result.failure {
            state = .failed(failure); record.status = .failed
            record.notice = "Analysis needs attention. Your progress is saved."
        } else {
            state = .completed; record.status = .completed
            if request.fullCycle && result.complete {
                ProcessingPlan.completeInitial(defaults)
                initialComplete = true
            }
            record.notice = result.complete ? nil : "Some sources need another try. Completed work is saved."
        }
        if let diagnosticID {
            DiagnosticHistory.finish(.overnight, id: diagnosticID,
                outcome: result.complete ? .completed : (result.failure == nil ? .partial : .failed),
                measurements: ["elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                               "device_items": result.progress.total, "device_failed": result.progress.failed])
            if result.complete { Analytics.signal("Scheduler.overnightCompleted", tier: .core) }
        }
        if scheduled && !initialComplete {
            // A partial first night remains pending even for knowledge-base-only users.
            record.status = .scheduled
            record.due = OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes)
        }
        // Release stale preview payloads only when the next run begins; reopening progress shows
        // the actual result. Reading or hiding a window never changes task lifetime.
    }

    private func execute(_ request: ProcessingRequest, scheduled: Bool, id: UUID,
                         report: @escaping @Sendable (RunProgress) -> Void) async -> ProcessingRun.Result {
        await ProcessingRun(request: request, scheduled: scheduled).execute(progress: report, phase: { [weak self] phase in
            Task { @MainActor [weak self] in
                guard let self, self.runID == id, self.stopReason == nil else { return }
                self.lastProgressAt = Date(); self.thought = nil
                switch phase {
                case .knowledgeBase(let text): self.state = .preparing; self.prepStatus = text; self.prepSubtext = nil
                case .deciding: self.state = .preparing; self.prepStatus = "Finding things worth doing…"
                case .researching(let n): self.state = .preparing; self.prepStatus = "Preparing \(n) suggestions…"
                case .done, .failed: break
                }
            }
        }, onLine: { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, self.runID == id, self.stopReason == nil else { return }
                self.lastProgressAt = Date(); self.thought = line
            }
        })
    }

    private func stop(_ reason: Stop) {
        // Ownership also covers wake-helper cleanup after the result is final. A late Pause or
        // power tick must not turn that completed result back into a pending/stopping run.
        guard isBusy, stopReason == nil, record.status == .running else { return }
        stopReason = reason
        state = .stopping
        // Persist the user's pause immediately, even if the app quits while work is draining.
        record.status = reason == .user ? .paused : .requested
        if reason == .stalled || reason == .ceiling {
            record.status = .failed
            record.notice = "Analysis stopped making progress. Waiting for it to finish stopping; completed work is saved."
            if record.trigger == .overnight { OvernightCaution.record(.stalled) }
            CrashReporting.captureEvent("processing.stalled", level: .warning,
                tags: ["trigger": record.trigger.rawValue], fingerprint: ["processing", "stalled"])
        }
        task?.cancel()
        if let diagnosticID {
            DiagnosticHistory.finish(.overnight, id: diagnosticID,
                outcome: reason == .stalled ? .stalled : .stopped,
                reason: reason == .power ? "power" : (reason == .stalled ? "no_progress" : "paused"))
        }
        // A wedged worker retains the analysis lock, but must not retain the lid-shut awake hold.
        releaseSystemActivity()
        Task { await releaseAwake() }
    }

    private func finishStopped(_ final: RunProgress) {
        carried = Self.composed(carried, final)
        switch stopReason {
        case .user:
            record.status = .paused; state = .paused
        case .power:
            record.status = .requested
            state = .waiting(.power(power.critical ? .thermal : .batteryLow))
        case .stalled, .ceiling:
            record.status = .failed; state = .paused
            record.notice = "Analysis paused to let your Mac rest. Your progress is saved."
            if record.trigger == .overnight { OvernightCaution.record(.stalled) }
        case .cancelled, nil:
            record.status = .paused; state = .paused
        }
        if record.trigger == .overnight, stopReason != .user {
            record.status = .scheduled
            record.due = OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes)
            if record.notice == nil { record.notice = "Overnight analysis paused. Your progress is saved for the next run." }
            state = .scheduled
        }
    }

    private func checkRunningWork() async {
        guard isBusy, stopReason == nil, record.status == .running else { return }
        if PowerState.shouldPause(power, scheduled: record.trigger == .overnight) { stop(.power); return }
        if Date().timeIntervalSince(lastProgressAt) > OvernightScheduler.stallSeconds { stop(.stalled); return }
        if record.trigger == .overnight {
            if Date().timeIntervalSince(startedAt) >= Double(WakeHelperConfig.maxAwakeSeconds) { stop(.ceiling); return }
            if helperHeld && Date().timeIntervalSince(lastHeartbeatAt) >= 60 {
                lastHeartbeatAt = Date()
                _ = await WakeHelperClient.shared.heartbeat()
            }
        }
    }

    private func releaseAwake() async {
        if let helperRelease { await helperRelease.value; return }
        guard helperHeld else { return }
        helperHeld = false
        let release = Task { _ = await WakeHelperClient.shared.endAwake() }
        helperRelease = release
        await release.value
        helperRelease = nil
    }

    private func releaseSystemActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private static func composed(_ base: RunProgress, _ p: RunProgress) -> RunProgress {
        guard base.done > 0 else { return p }
        var c = p
        c.done += base.done; c.total += base.done
        c.survivors += base.survivors; c.junk += base.junk; c.sensitive += base.sensitive
        c.failed += base.failed; c.parseFailures += base.parseFailures; c.extractionFailed += base.extractionFailed
        c.totalSeconds += base.totalSeconds; c.quietReads += base.quietReads
        c.mergeSourceResults(from: base)
        return c
    }
}
