import AppKit
import SwiftUI

/// Mount once as the full Home background and keep mounted when `enabled` becomes false.
/// `activeRect` uses this root's top-left coordinates. The probe never takes focus or hit tests.
struct SidekickOverviewScroll: NSViewRepresentable {
    let enabled: Bool
    let activeRect: CGRect
    let onProgress: (Double) -> Void
    let onSettle: () -> Void
    let onCollapse: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe(frame: .zero)
        view.setAccessibilityElement(false)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.configure(enabled: enabled, activeRect: activeRect,
                       onProgress: onProgress, onSettle: onSettle, onCollapse: onCollapse)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private(set) var enabled = false
        private(set) var activeRect = CGRect.zero
        var policy = SidekickOverviewScrollPolicy()
        private var onProgress: ((Double) -> Void)?
        private var onSettle: (() -> Void)?
        private var onCollapse: (() -> Void)?
        private var monitor: Any?
        private var quietTimer: Timer?
        private var scheduledDeadline: TimeInterval?
        private var deferredSettle: Task<Void, Never>?
        private var callbackVersion = UUID()
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(enabled: Bool, activeRect: CGRect, onProgress: @escaping (Double) -> Void,
                       onSettle: @escaping () -> Void, onCollapse: @escaping () -> Void) {
            let valid = !activeRect.isNull && !activeRect.isInfinite
                && activeRect.origin.x.isFinite && activeRect.origin.y.isFinite
                && activeRect.width.isFinite && activeRect.height.isFinite
                && activeRect.width > 0 && activeRect.height > 0
            let rect = valid ? activeRect : .zero
            let changed = self.enabled != enabled || self.activeRect != rect
            self.enabled = enabled; self.activeRect = rect
            self.onProgress = onProgress; self.onSettle = onSettle; self.onCollapse = onCollapse
            if changed {
                let moved = policy.discardProgress()
                if moved { scheduleSettle() }
                synchronizeQuietTimer()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                let moved = policy.distance > 0
                removeMonitor()
                if moved { scheduleSettle() }
            }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isVisible, !window.isMiniaturized,
                  !isHiddenOrHasHiddenAncestor else {
                let moved = policy.distance > 0
                policy.reset(); synchronizeQuietTimer()
                if moved { return apply(.settle) }
                return false
            }
            let point = convert(event.locationInWindow, from: nil)
            return consume(.init(
                timestamp: event.timestamp, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                inverted: event.isDirectionInvertedFromDevice, precise: event.hasPreciseScrollingDeltas,
                phase: event.phase, momentumPhase: event.momentumPhase,
                enabled: enabled, ownWindow: true, insideView: bounds.contains(point),
                insideActiveRect: activeRect.intersection(bounds).contains(point)))
        }
        /// Event mapping stays at the window boundary; policy, callbacks and timer share this path.
        func consume(_ input: SidekickOverviewScrollPolicy.Input) -> Bool {
            let decision = policy.handle(input)
            let consumed = apply(decision)
            synchronizeQuietTimer()
            return consumed
        }
        private func apply(_ decision: SidekickOverviewScrollPolicy.Decision) -> Bool {
            switch decision {
            case .passThrough: return false
            case .consume: return true
            case .progress(let distance):
                cancelDeferredSettle(); onProgress?(distance); return true
            case .settle:
                cancelDeferredSettle(); onSettle?(); return false
            case .collapse:
                cancelDeferredSettle(); onCollapse?(); return true
            }
        }
        private func scheduleSettle() {
            cancelDeferredSettle()
            let version = callbackVersion
            // configure runs during updateNSView. Never publish SwiftUI state on that stack.
            deferredSettle = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.callbackVersion == version,
                      self.policy.distance == 0, !self.policy.consuming else { return }
                self.deferredSettle = nil
                self.onSettle?()
            }
        }
        private func cancelDeferredSettle() {
            callbackVersion = UUID(); deferredSettle?.cancel(); deferredSettle = nil
        }
        private func synchronizeQuietTimer() {
            guard scheduledDeadline != policy.quietDeadline else { return }
            quietTimer?.invalidate(); quietTimer = nil; scheduledDeadline = policy.quietDeadline
            guard let deadline = scheduledDeadline else { return }
            let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.quietTimer = nil; self.scheduledDeadline = nil
                    let decision = self.policy.settleIfQuiet(at: ProcessInfo.processInfo.systemUptime)
                    _ = self.apply(decision)
                    self.synchronizeQuietTimer()
                }
            }
            quietTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        func detach() {
            removeMonitor()
            onProgress = nil; onSettle = nil; onCollapse = nil
        }
        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            quietTimer?.invalidate(); quietTimer = nil; scheduledDeadline = nil
            cancelDeferredSettle(); policy.reset()
        }
        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            quietTimer?.invalidate(); deferredSettle?.cancel()
        }
    }
}

/// Pure gesture state. Phase-bearing input lasts until its explicit end, even through a long
/// finger pause. Phase-less wheel bursts expose one quiet deadline for the adapter's timer.
nonisolated struct SidekickOverviewScrollPolicy {
    enum Decision: Equatable { case passThrough, consume, progress(Double), settle, collapse }
    struct Input: Sendable {
        let timestamp: TimeInterval
        let deltaX: Double
        let deltaY: Double
        let inverted: Bool
        let precise: Bool
        let phase: NSEvent.Phase
        let momentumPhase: NSEvent.Phase
        let enabled: Bool
        let ownWindow: Bool
        let insideView: Bool
        let insideActiveRect: Bool
    }
    static let preciseThreshold = 140.0
    static let wheelThreshold = 3.0
    static let quietInterval = 0.35
    private(set) var consuming = false
    private(set) var distance = 0.0
    private(set) var quietDeadline: TimeInterval?
    private var preciseDevice: Bool?
    private var lastActivity: TimeInterval?

    mutating func reset() {
        consuming = false; distance = 0; quietDeadline = nil
        preciseDevice = nil; lastActivity = nil
    }
    /// Geometry/enablement invalidates partial motion but preserves a committed gesture's tail.
    @discardableResult mutating func discardProgress() -> Bool {
        guard !consuming else { return false }
        let moved = distance > 0
        reset()
        return moved
    }
    mutating func settleIfQuiet(at timestamp: TimeInterval) -> Decision {
        guard timestamp.isFinite else { return invalidate() }
        guard let deadline = quietDeadline, timestamp >= deadline else { return .passThrough }
        return invalidate()
    }
    private mutating func invalidate() -> Decision {
        let moved = distance > 0
        reset()
        return moved ? .settle : .passThrough
    }

    mutating func handle(_ input: Input) -> Decision {
        guard input.timestamp.isFinite, input.deltaX.isFinite, input.deltaY.isFinite,
              input.ownWindow, input.insideView else { return invalidate() }
        if let lastActivity, input.timestamp < lastActivity { return invalidate() }
        var clearedProgress = false
        if let deadline = quietDeadline, input.timestamp >= deadline {
            clearedProgress = distance > 0; reset()
        }
        let newGesture = input.momentumPhase.isEmpty && !input.phase.intersection([.began, .mayBegin]).isEmpty
        if newGesture { clearedProgress = clearedProgress || distance > 0; reset() }
        lastActivity = input.timestamp
        if consuming {
            if input.phase.contains(.cancelled) || !input.momentumPhase.intersection([.ended, .cancelled]).isEmpty {
                reset()
            } else if !input.momentumPhase.isEmpty {
                quietDeadline = nil
            } else if input.phase.contains(.ended) {
                quietDeadline = input.timestamp + Self.quietInterval
            } else if !input.phase.isEmpty {
                quietDeadline = nil
            } else if abs(input.deltaX) > 0.01 || abs(input.deltaY) > 0.01 {
                quietDeadline = input.timestamp + Self.quietInterval
            }
            // Home may already be disabled or its active rectangle replaced after commit.
            return .consume
        }
        guard input.enabled, input.insideActiveRect, input.momentumPhase.isEmpty,
              input.phase.intersection([.mayBegin, .ended, .cancelled]).isEmpty else {
            let decision = invalidate()
            return clearedProgress && decision == .passThrough ? .settle : decision
        }
        if let preciseDevice, preciseDevice != input.precise {
            clearedProgress = clearedProgress || distance > 0; reset(); lastActivity = input.timestamp
        }
        preciseDevice = input.precise
        let jitter = input.precise ? 1.5 : 0.49
        if abs(input.deltaX) <= jitter, abs(input.deltaY) <= jitter {
            if !input.phase.isEmpty { quietDeadline = nil }
            return clearedProgress ? .settle : (distance > 0 ? .consume : .passThrough)
        }
        guard abs(input.deltaY) > abs(input.deltaX) * 1.2 else {
            let decision = invalidate()
            return clearedProgress && decision == .passThrough ? .settle : decision
        }
        let up = input.inverted ? -input.deltaY : input.deltaY
        guard up > jitter || distance > 0 else { return clearedProgress ? .settle : .passThrough }
        let amount = input.precise ? up : up * Self.preciseThreshold / Self.wheelThreshold
        distance = min(Self.preciseThreshold, max(0, distance + amount))
        quietDeadline = input.phase.isEmpty ? input.timestamp + Self.quietInterval : nil
        if distance >= Self.preciseThreshold {
            consuming = true; distance = 0
            return .collapse
        }
        return .progress(distance)
    }
}
