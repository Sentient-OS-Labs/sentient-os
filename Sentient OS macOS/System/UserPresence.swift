//
//  UserPresence.swift
//  Sentient OS macOS  ·  System/
//
//  One question, answered in one place: is the user away from Sentient right now? Background
//  housekeeping that must never land in someone's lap (Sparkle's silent relaunch, the daily
//  Codex CLI update) asks this before acting. "Away" = the app isn't frontmost with a key window,
//  OR no keyboard/mouse input has arrived for five minutes. Being away from the APP is enough:
//  a user busy in another app never sees a background install happen.
//
//  Callers layer their own work gates on top (PipelineActivity, the Sidekick run lock); this file
//  only knows about the human.
//
//  Key members: isAwayFromApp
//

import AppKit
import CoreGraphics

enum UserPresence {

    /// Seconds of no input before a frontmost user counts as away.
    private static let idleThreshold: TimeInterval = 300

    /// Session-wide inactivity, independent of which application is frontmost. Conservative:
    /// synthetic input also resets this clock, so an agent driving the Mac postpones analysis.
    static var systemIdleSeconds: TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    /// True when acting silently in the background can't interrupt anyone: the app is not the
    /// active app with a key window, or the whole session has been idle for 5+ minutes.
    @MainActor
    static var isAwayFromApp: Bool {
        let appIsFrontmost = NSApp.isActive && NSApp.keyWindow != nil
        return !appIsFrontmost || systemIdleSeconds > idleThreshold
    }
}
