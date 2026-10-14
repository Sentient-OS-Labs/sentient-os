// ShortcutKey.swift
// The modifier keys shared by Sidekick and Double Tap. Existing preference values stay valid.
// keyCode maps native events; deviceBit distinguishes left and right modifiers.
// Doc: ../Documentation - System (Permissions, Health, Uninstall).md

import AppKit
import Carbon.HIToolbox

enum ShortcutKey: String, CaseIterable {
    case rightCommand, rightOption, leftCommand, leftOption, leftControl, rightControl
    var keyCode: UInt16 {
        switch self {
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .leftCommand: return UInt16(kVK_Command)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftOption: return UInt16(kVK_Option)
        case .rightControl: return UInt16(kVK_RightControl)
        case .leftControl: return UInt16(kVK_Control)
        }
    }

    init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    var deviceBit: UInt64 {
        switch self {
        case .leftControl: return 0x1
        case .leftCommand: return 0x8
        case .rightCommand: return 0x10
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        }
    }

    var label: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .leftCommand: return "Left ⌘"
        case .rightOption: return "Right ⌥"
        case .leftOption: return "Left ⌥"
        case .rightControl: return "Right ⌃"
        case .leftControl: return "Left ⌃"
        }
    }

    var spokenLabel: String {
        switch self {
        case .rightCommand: return "right Command"
        case .leftCommand: return "left Command"
        case .rightOption: return "right Option"
        case .leftOption: return "left Option"
        case .rightControl: return "right Control"
        case .leftControl: return "left Control"
        }
    }

    /// Caps Lock's latched state does not turn a single key into a combination.
    func isAlone(in flags: NSEvent.ModifierFlags) -> Bool {
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let allDeviceBits: UInt64 = 0x207F // Command, Option, Control and Shift, on both sides.
        let generic: NSEvent.ModifierFlags
        switch self {
        case .rightCommand, .leftCommand: generic = .command
        case .rightOption, .leftOption: generic = .option
        default: generic = .control
        }
        return UInt64(flags.rawValue) & allDeviceBits == deviceBit
            && flags.intersection(modifiers) == generic && !flags.contains(.function)
    }
}
