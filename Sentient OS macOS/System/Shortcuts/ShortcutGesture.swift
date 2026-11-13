// ShortcutGesture.swift
// Recognizes completed, standalone taps and pairs without reading typed characters.
// Input counters invalidate shortcuts used while typing, clicking, or scrolling.
// Doc: ../Documentation - System (Permissions, Health, Uninstall).md

import AppKit

struct ShortcutActivity: Equatable {
    var keys: UInt32
    var clicks: UInt32
    var scrolls: UInt32

    /// Event monitors may run after a burst of input has already reached the window server.
    /// Compare against the event's timestamp as well as counters, so a delayed Command-C
    /// delivery cannot look like an isolated Command tap. No key values are read.
    static var lastInputTime: TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .max() ?? -.infinity
    }

    static var current: Self {
        func count(_ type: CGEventType) -> UInt32 {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
        }
        return Self(keys: count(.keyDown),
                    clicks: count(.leftMouseDown) &+ count(.rightMouseDown) &+ count(.otherMouseDown),
                    scrolls: count(.scrollWheel))
    }
}

struct ShortcutTap {
    private var began: TimeInterval?
    private var activity: ShortcutActivity?
    private var holdRecognized = false
    private(set) var isDown = false
    static let maximumDuration: TimeInterval = 0.5
    static let holdDuration: TimeInterval = 0.25
    var isTracking: Bool { isDown && activity != nil }

    func isStandalone(activity current: ShortcutActivity, lastInputTime: TimeInterval) -> Bool {
        guard let began else { return false }
        return isTracking && activity == current && lastInputTime <= began + 0.002
    }

    mutating func takeHold(at time: TimeInterval, activity: ShortcutActivity,
                           lastInputTime: TimeInterval) -> Bool {
        guard !holdRecognized, let began, time - began >= Self.holdDuration,
              isStandalone(activity: activity, lastInputTime: lastInputTime) else { return false }
        holdRecognized = true
        return true
    }

    /// Duplicate down edges cannot turn a held key into repeated taps. Invalidating a held
    /// key keeps it down until its release, so another flagsChanged cannot re-arm it.
    mutating func update(down: Bool, alone: Bool, at time: TimeInterval,
                         activity current: ShortcutActivity,
                         maximumDuration: TimeInterval = Self.maximumDuration,
                         lastInputTime: TimeInterval = -.infinity) -> Bool {
        if !alone { activity = nil }
        guard down != isDown else { return false }
        isDown = down
        if down {
            began = time
            holdRecognized = false
            activity = alone ? current : nil
            return false
        }
        defer { began = nil; activity = nil }
        guard !holdRecognized, let began, time >= began, time - began <= maximumDuration else { return false }
        // Allow a small sampling tolerance between the two system uptime APIs.
        return alone && activity == current && lastInputTime <= began + 0.002
    }

    mutating func cancel() { activity = nil }
}

struct ShortcutTapPair {
    private var previous: (key: ShortcutKey, time: TimeInterval, activity: ShortcutActivity)?

    mutating func register(_ key: ShortcutKey, at time: TimeInterval,
                           activity: ShortcutActivity, window: TimeInterval,
                           lastInputTime: TimeInterval = -.infinity) -> Bool {
        let matched = previous.map {
            $0.key == key && time >= $0.time && time - $0.time <= window
                && activity == $0.activity
                && lastInputTime <= $0.time + 0.002
        } ?? false
        previous = matched ? nil : (key, time, activity)
        return matched
    }

    mutating func reset() { previous = nil }
}
