// Copyright © 2026 TGTools123. Part of NUEM (GNU GPL v3).
// Keyboard light (Settings → Effect Console → Black → Fade the keyboard light): the backlight dims with the fold, off
// by `keyboardFadeAngle`, and comes back to the level it had when the fold ends.

import Cocoa
import QuartzCore

// By TGTools123.
final class KeyboardBacklight {
    private let client: NSObject?
    private let keyboard: UInt64?
    private var original: Float?                          // the level when the fold began; nil while nothing is dimmed
    private var lastSet: Float = -1, lastSetAt: CFTimeInterval = 0

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { client = nil; keyboard = nil; return }
        let client = type.init()
        let ids = NSSelectorFromString("copyKeyboardBacklightIDs")
        let list = client.responds(to: ids) ? client.perform(ids)?.takeRetainedValue() as? [NSNumber] : nil
        self.client = client
        keyboard = list?.first?.uint64Value
        // Quitting mid-fold leaves the keyboard where it was.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restore()
        }
    }

    private func level() -> Float? {
        guard let client, let keyboard else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: selector) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(client.method(for: selector), to: Get.self)(client, selector, keyboard)
    }

    private func set(_ value: Float) {
        guard let client, let keyboard else { return }
        let selector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
        guard client.responds(to: selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
        _ = unsafeBitCast(client.method(for: selector), to: Set.self)(client, selector, value, 80, false, keyboard)   // an 80 ms glide, not saved
        lastSet = value
        lastSetAt = CACurrentMediaTime()
    }

    /// Each sensor reading. `active`: the fold (or its black cover) is on screen.
    func update(angle: CGFloat, start: CGFloat, active: Bool) {
        guard client != nil else { return }
        guard active, Settings.keyboardFade else { restore(); return }
        if original == nil { original = level() ?? 0 }
        guard let original, original > 0.001 else { return }         // off already: nothing to fade
        let end = min(Settings.keyboardFadeAngle, start - 1)
        let u = min(1, max(0, (angle - end) / max(1, start - end)))
        let target = original * Float(u * u * (3 - 2 * u))
        guard abs(target - lastSet) > 0.01 || (target == 0 && lastSet != 0) else { return }
        guard CACurrentMediaTime() - lastSetAt > 0.05 || target == 0 else { return }   // 20 changes a second at most
        set(target)
    }

    /// Back to the level the fold found: the fold ended, the option was turned off, or NUEM quits.
    func restore() {
        guard let original else { return }
        self.original = nil
        if original > 0.001 { set(original) }
        lastSet = -1
    }
}
