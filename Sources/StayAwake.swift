// Copyright © 2026 TGTools123 (NUEM). GNU GPL v3.
// Stay awake with the lid closed (opt-in): the power setting `pmset disablesleep` — the one closed-display utilities
// use — so closing the lid doesn't put the Mac to sleep.

import Cocoa

enum StayAwake {
    /// The system setting now (pmset's "SleepDisabled"). Runs pmset: read it when needed, not per frame.
    static var isOn: Bool {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").contains { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.first == "SleepDisabled" && words.last == "1"
        }
    }

    /// Changes the setting; macOS asks for an administrator password. False if cancelled or refused.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        var error: NSDictionary?
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { logger.error("Stay awake: \(String(describing: error), privacy: .public)") }
        return error == nil
    }
}
