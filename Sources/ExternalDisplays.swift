// NUEM · TGTools123. Copyright © 2026 TGTools123, GNU GPL v3.
// Turning external displays off while the lid is closed (Settings → General, off by default).

import Cocoa

enum ExternalDisplays {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private static let configureEnabled: ConfigureEnabled? = {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        let symbol = sky.flatMap { dlsym($0, "SLSConfigureDisplayEnabled") }
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled")   // RTLD_DEFAULT
        return symbol.map { unsafeBitCast($0, to: ConfigureEnabled.self) }
    }()

    private static let key = "switchedOffDisplays"
    private static var lastRestore: CFTimeInterval = -.infinity

    static var available: Bool { configureEnabled != nil }

    /// Displays NUEM switched off and hasn't switched back on yet.
    private static var switchedOff: [CGDirectDisplayID] {
        (UserDefaults.standard.array(forKey: key) as? [Int] ?? []).map { CGDirectDisplayID($0) }
    }
    static var areOff: Bool { !switchedOff.isEmpty }

    /// Online external displays.
    static var connected: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Switches every external display off; false if there was none or it failed.
    @discardableResult
    static func switchOff() -> Bool {
        let displays = connected
        guard let configureEnabled, !displays.isEmpty else { return false }
        // Written down first: whatever happens next, they get switched back on.
        UserDefaults.standard.set(Array(Set(switchedOff + displays)).map(Int.init), forKey: key)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { restore(); return false }
        for display in displays { _ = configureEnabled(config, display, false) }
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { restore(); return false }
        logger.notice("External displays switched off with the lid: \(displays.map(String.init).joined(separator: ", "), privacy: .public)")
        return true
    }

    /// Switches back on the displays NUEM switched off.
    static func restore(force: Bool = false) {
        let displays = switchedOff
        let now = CACurrentMediaTime()
        guard !displays.isEmpty else { restoringSince = nil; attempts = 0; return }
        if restoringSince == nil { restoringSince = now }
        let interval: CFTimeInterval = lastWentThrough ? 8 : now - restoringSince! < 120 ? 2 : 30
        guard force || now - lastRestore > interval else { return }
        lastRestore = now
        let missing = displays.filter { !online.contains($0) }
        guard !missing.isEmpty else {
            if attempts > 0 { logger.notice("External displays back on after \(attempts) attempt(s)") }
            UserDefaults.standard.removeObject(forKey: key)
            restoringSince = nil; attempts = 0; lastWentThrough = false
            return
        }
        guard let configureEnabled else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for display in missing { _ = configureEnabled(config, display, true) }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        lastWentThrough = result == .success
        attempts += 1
        if attempts <= 3 || attempts % 20 == 0 {                // not every 30 s in the log for a display gone for good
            logger.notice("Switching external displays back on: \(missing.map(String.init).joined(separator: ", "), privacy: .public) (\(result.rawValue)), attempt \(attempts)")
        }
    }

    private static var restoringSince: CFTimeInterval?
    private static var attempts = 0
    private static var lastWentThrough = false

    /// Every online display, built-in included.
    private static var online: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
