// Automatic launches keep Sentient available in the menu bar without opening its main window.
// The privileged wake-helper branches in main.swift before this GUI policy is ever consulted.

import AppKit
import Carbon

@MainActor
enum LaunchPresentation {
    static var isLoginItemLaunch: Bool {
        isLoginItemLaunch(event: NSAppleEventManager.shared().currentAppleEvent)
    }

    static func isLoginItemLaunch(event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func staysInMenuBar(onboarded: Bool, loginItem: Bool, silentUpdate: Bool) -> Bool {
        onboarded && (loginItem || silentUpdate)
    }

    static var staysInMenuBar: Bool {
        staysInMenuBar(onboarded: UserDefaults.standard.bool(forKey: AppState.onboardingKey),
                       loginItem: isLoginItemLaunch, silentUpdate: UpdateNotice.suppressHomeThisLaunch)
    }
}
