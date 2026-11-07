// Command-Comma / Command-Period shortcuts, resolved against the current keyboard layout.
// resolve() finds the punctuation key; registration always requires Command alone.
// Doc: ../Documentation - System (Permissions, Health, Uninstall).md
import AppKit
import Carbon.HIToolbox

nonisolated enum QuickActionShortcut: String, CaseIterable, Hashable {
    case summarize, proofread
    var character: String { self == .summarize ? "," : "." }
    var label: String { "⌘" + character }
    var spokenLabel: String { self == .summarize ? "Command comma" : "Command period" }
    struct Chord: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static func resolve(_ action: Self, translate: (UInt16, UInt32) -> String?) -> Chord? {
        // Prefer the unshifted key, then its shifted legend (e.g. period on French AZERTY).
        // Shift locates the key only; neither Shift nor Option is part of the shortcut.
        for modifiers in [UInt32(0), UInt32(shiftKey)] {
            for keyCode in UInt16(0)...127 where translate(keyCode, modifiers) == action.character {
                return Chord(keyCode: UInt32(keyCode), modifiers: UInt32(cmdKey))
            }
        }
        return nil
    }

    @MainActor static func currentChords() -> [Self: Chord] {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()].compactMap { $0 }
        for source in sources {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size, let bytes = CFDataGetBytePtr(data) else { continue }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var result: [Self: Chord] = [:]
            for action in allCases {
                result[action] = resolve(action) { keyCode, modifiers in
                    var dead: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers >> 8,
                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                        characters.count, &length, &characters)
                    guard status == noErr, length > 0 else { return nil }
                    return String(utf16CodeUnits: characters, count: Int(length))
                }
            }
            // A missing character in a real layout is not permission to silently choose another
            // layout's keys. ASCII fallback is only for input methods without Unicode layout data.
            // A custom layout may put both symbols on one key. Do not dispatch the wrong action.
            return result.filter { action, chord in
                !result.contains { $0.key != action && $0.value == chord }
            }
        }
        return [:]
    }
}
