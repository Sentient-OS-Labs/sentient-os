// Registers the two quick-action chords globally with Carbon, without keyboard monitoring.
// Re-registers on layout changes, rejects stale/repeated events, and releases registrations on stop.
// Doc: ../Documentation - System (Permissions, Health, Uninstall).md
import AppKit
import Carbon.HIToolbox
import Observation

@MainActor @Observable final class QuickActionHotkeys {
    enum Problem: Equatable {
        case layout, registration(OSStatus)
        var explanation: String {
            switch self {
            case .layout: "Shortcut isn’t available on this keyboard layout."
            case .registration(let status) where status == eventHotKeyExistsErr: "Shortcut is already in use by another app."
            case .registration: "Shortcut couldn’t be registered. Restart Sentient to retry."
            }
        }
    }
    private(set) var problems: [QuickActionShortcut: Problem] = [:]
    private(set) var registeredActions: Set<QuickActionShortcut> = []
    @ObservationIgnored var onAction: ((QuickActionShortcut) -> Void)?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var references: [EventHotKeyRef] = []
    @ObservationIgnored private var actions: [UInt32: QuickActionShortcut] = [:]
    @ObservationIgnored private var pressed: Set<UInt32> = []
    @ObservationIgnored private var serial: UInt32 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var awake = true
    @ObservationIgnored private var activeSession = true
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    nonisolated static let signature: OSType = 0x534E5141 // SNQA

    func start() {
        guard !started else { return }
        started = true
        if NSApp?.isRunning == true { install() }
        else {
            observe(.default, NSApplication.didFinishLaunchingNotification) { [weak self] in self?.install() }
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        rebuild()
    }

    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll(); started = false
    }

    isolated deinit { stop() }

    private func install() {
        guard started, handler == nil else { return }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.eventHandler, events.count, &events,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            problems = Dictionary(uniqueKeysWithValues: QuickActionShortcut.allCases.map { ($0, .registration(status)) })
            return
        }
        observe(DistributedNotificationCenter.default(), Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)) { [weak self] in self?.rebuild() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.awake = false; self?.rebuild() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.awake = true; self?.rebuild() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.activeSession = false; self?.rebuild() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.activeSession = true; self?.rebuild() }
        rebuild()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }

    private func unregister() {
        // Release both before claiming either; layouts can move the same physical key between actions.
        actions.removeAll(); pressed.removeAll(); registeredActions.removeAll(); problems.removeAll()
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    private func rebuild() {
        unregister()
        guard started, handler != nil, enabled, awake, activeSession else { return }
        let chords = QuickActionShortcut.currentChords()
        for action in QuickActionShortcut.allCases {
            guard let chord = chords[action] else { problems[action] = .layout; continue }
            serial &+= 1
            if serial == 0 { serial = 1 }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: serial)
            let status = RegisterEventHotKey(chord.keyCode, chord.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference {
                references.append(reference); actions[id.id] = action; registeredActions.insert(action)
            } else {
                problems[action] = .registration(status)
                Log("quick action shortcut unavailable action=\(action.rawValue) status=\(status)")
            }
        }
    }

    @discardableResult
    func receive(identifier: UInt32, isPressed: Bool) -> Bool {
        guard enabled, let action = actions[identifier] else { return false }
        if isPressed {
            guard pressed.insert(identifier).inserted else { return true }
            onAction?(action)
        } else { pressed.remove(identifier) }
        return true
    }

    private nonisolated static let eventHandler: EventHandlerUPP = { _, event, context in
        guard Thread.isMainThread, let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == signature else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<QuickActionHotkeys>.fromOpaque(context).takeUnretainedValue()
        return MainActor.assumeIsolated {
            owner.receive(identifier: id.id, isPressed: GetEventKind(event) == UInt32(kEventHotKeyPressed)) ? noErr : OSStatus(eventNotHandledErr)
        }
    }

    #if DEBUG
    var identifiersForTesting: [UInt32: QuickActionShortcut] { actions }
    func installForTesting() { started = true; install() }
    #endif
}
