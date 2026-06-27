//
//  NotchSpace.swift
//  Sentient OS macOS
//
//  Pins the notch overlay into a window-server "space" at the top absolute level, via the SkyLight
//  private API — so it stays ROCK-FIXED over the notch on every Space and never slides during the
//  3-finger Spaces swipe (the same trick the menu bar and the real notch use). No public API achieves
//  this: the `.stationary` collection behavior only covers Exposé, not the swipe.
//
//  Fragile by nature (private symbols), so it fails gracefully: if anything is missing, `shared` is nil
//  and the window falls back to its public `collectionBehavior` (.canJoinAllSpaces). Distilled from
//  DynamicNotch's SkyLightOperator down to the one thing we need. Doc: Documentation/Notch Magic/.
//

import AppKit
import Darwin

@MainActor
final class NotchSpace {
    /// nil when SkyLight is unavailable — callers then rely on the public collectionBehavior alone.
    static let shared = NotchSpace()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsAndRemoveFromSpaces

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let connSym   = dlsym(handle, "SLSMainConnectionID"),
              let createSym = dlsym(handle, "SLSSpaceCreate"),
              let levelSym  = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSym   = dlsym(handle, "SLSShowSpaces"),
              let addSym    = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return nil }

        let mainConnectionID = unsafeBitCast(connSym, to: MainConnectionID.self)
        let spaceCreate      = unsafeBitCast(createSym, to: SpaceCreate.self)
        let setAbsoluteLevel = unsafeBitCast(levelSym, to: SpaceSetAbsoluteLevel.self)
        let showSpaces       = unsafeBitCast(showSym, to: ShowSpaces.self)
        self.addWindows      = unsafeBitCast(addSym, to: AddWindowsAndRemoveFromSpaces.self)

        let conn = mainConnectionID()
        let space = spaceCreate(conn, 1, 0)
        guard space != 0 else { return nil }
        _ = setAbsoluteLevel(conn, space, .max)        // top absolute level — above the Spaces swipe
        _ = showSpaces(conn, [space] as CFArray)       // keep it shown everywhere
        self.connection = conn
        self.space = space
    }

    /// Move the window into the fixed notch space (and out of the normal Spaces). The window must be on
    /// screen (valid windowNumber), so call this AFTER orderFront.
    func pin(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
