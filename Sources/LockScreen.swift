// Copyright © 2026 TGTools123. Part of NUEM, under the GNU GPL v3.
// Lock screen: showing the fold above the lock screen, and knowing when the Mac is locked.

import Cocoa
import IOKit.pwr_mgt

enum LockScreen {
    /// True while the lock screen (or the login window) is up.
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Posted by the system when the screen locks and unlocks.
    static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindow = @convention(c) (Int32, Int32, UnsafePointer<CGPoint>) -> Int32

    private struct Space {
        let connection: Int32, id: Int32
        let add: AddWindows
        let copySpaces: CopySpaces?
        let move: MoveWindow?
    }

    /// The space shown above the lock screen, created on first use; nil if SkyLight lacks the calls.
    private static let space: Space? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainConnection = dlsym(sky, "SLSMainConnectionID"), let create = dlsym(sky, "SLSSpaceCreate"),
              let setLevel = dlsym(sky, "SLSSpaceSetAbsoluteLevel"), let show = dlsym(sky, "SLSShowSpaces"),
              let add = dlsym(sky, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
        let connection = unsafeBitCast(mainConnection, to: MainConnection.self)()
        let id = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, 0)
        let notificationCenterAtScreenLock: Int32 = 400
        guard id != 0,
              unsafeBitCast(setLevel, to: SpaceSetAbsoluteLevel.self)(connection, id, notificationCenterAtScreenLock) == 0,
              unsafeBitCast(show, to: ShowSpaces.self)(connection, [id] as CFArray) == 0 else { return nil }
        return Space(connection: connection, id: id, add: unsafeBitCast(add, to: AddWindows.self),
                     copySpaces: dlsym(sky, "SLSCopySpacesForWindows").map { unsafeBitCast($0, to: CopySpaces.self) },
                     move: dlsym(sky, "SLSMoveWindow").map { unsafeBitCast($0, to: MoveWindow.self) })
    }()

    /// Moves `window` above the lock screen and places its top-left corner at `origin` (global display coordinates,
    /// top-left origin).
    @discardableResult
    static func raise(_ window: NSWindow, at origin: CGPoint) -> Bool {
        window.canBecomeVisibleWithoutLogin = true
        guard let space else { return false }
        for _ in 0..<2 {
            _ = space.add(space.connection, space.id, [window.windowNumber] as CFArray, 7)
            if isRaised(window) { break }
        }
        var target = origin
        if let move = space.move {
            _ = move(space.connection, Int32(window.windowNumber), &target)   // moving into the space can shift it
        }
        return isRaised(window)
    }

    /// True if `window` is in the lock-screen space: the window server then lists no ordinary space for it (checked
    /// on macOS 26.5: [] in the space, [1] for the same window outside it).
    static func isRaised(_ window: NSWindow) -> Bool {
        guard let space, let copySpaces = space.copySpaces else { return true }   // can't tell: assume it worked
        let spaces = copySpaces(space.connection, 7, [window.windowNumber] as CFArray)?.takeRetainedValue() as? [Int] ?? []
        return spaces.isEmpty || spaces.contains(Int(space.id))
    }
}

/// Keeping the display on at the lock screen, for the fold.
enum LockScreenLight {
    private static var assertion: IOPMAssertionID = 0            // 0: none
    private static var until: CFTimeInterval = 0
    private static var activity: IOPMAssertionID = 0
    private static var lastWake: CFTimeInterval = -.infinity
    private static var noNap: NSObjectProtocol?

    /// Keeps the display on for `seconds` from now, at least.
    static func keepOn(for seconds: CGFloat) {
        let now = CACurrentMediaTime(), deadline = now + Double(seconds)
        guard seconds > 0, until <= now + 1 || deadline > until + 3 else { return }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionNameKey: "NUEM keeps the lock screen on for the fold",
            kIOPMAssertionTimeoutKey: Int(seconds.rounded(.up)),
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &id) == kIOReturnSuccess else { return }
        if assertion != 0 { IOPMAssertionRelease(assertion) }        // after creating the next one: no gap
        assertion = id
        until = deadline
    }

    /// Lets macOS turn the display off again as usual.
    static func release() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        until = 0
    }

    /// Turns the display on, at most once a second.
    static func wake() {
        let now = CACurrentMediaTime()
        guard now - lastWake > 1 else { return }
        lastWake = now
        IOPMAssertionDeclareUserActivity("NUEM: the lid is moving on the lock screen" as CFString, kIOPMUserActiveLocal, &activity)
    }

    /// While locked, App Nap stays off — the display may be off and every window hidden, and the lid must still be
    /// followed at full rate.
    static func setLocked(_ locked: Bool) {
        if locked {
            guard noNap == nil else { return }
            noNap = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                          reason: "Following the lid on the lock screen")
        } else {
            noNap.map(ProcessInfo.processInfo.endActivity)
            noNap = nil
            release()
        }
    }
}
