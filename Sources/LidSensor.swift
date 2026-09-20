// Copyright © 2026 TGTools123. NUEM is free software under the GNU GPL v3.
// Modified 2026-09-20: retain fixed closing smoothing and opening anticipation only.
// Lid angle sensor: an internal Apple HID device (usage page 0x20 Sensor, usage 0x8A Orientation).

import Foundation
import IOKit.hid
import QuartzCore

final class LidSensor {
    // The manager must stay alive: releasing it closes every device it opened.
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var report = [UInt8](repeating: 0, count: 8)
    private(set) var isAvailable = false
    /// True once report 7 (hundredths of a degree) has answered and agreed with report 1.
    private(set) var hasFineReport = false

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        // Try the known product (0x8104) first. Several nodes can match; only one answers feature reads.
        func productID(_ d: IOHIDDevice) -> Int { IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0 }
        for candidate in devices.sorted(by: { productID($0) == 0x8104 && productID($1) != 0x8104 }) {
            guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            device = candidate
            if let angle = readCoarse(), angle <= 360 {
                isAvailable = true
                return
            }
            device = nil
            IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// Lid angle in degrees, using the fine report when supported.
    func read() -> Double? {
        if hasFineReport, let fine = readFine() { return fine }
        guard let coarse = readCoarse() else { return nil }
        if !hasFineReport, let fine = readFine(), abs(fine - coarse) < 1.5 {
            hasFineReport = true
            return fine
        }
        return coarse
    }

    private func readCoarse() -> Double? {
        guard let device else { return nil }
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        return Double(UInt16(report[2]) << 8 | UInt16(report[1]))
    }

    private func readFine() -> Double? {
        guard let device else { return nil }
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 7, &report, &length)
        guard result == kIOReturnSuccess, length >= 5 else { return nil }
        let raw = UInt32(report[1]) | UInt32(report[2]) << 8 | UInt32(report[3]) << 16 | UInt32(report[4]) << 24
        guard raw <= 36000 else { return nil }
        return Double(raw) / 100
    }
}

/// Turns the 10 Hz sensor into a continuous trajectory without overshoot: a linear ramp to each new reading, rounded
/// by a critically damped spring (which never bounces).
/// (NUEM by TGTools123.)
final class AngleSmoother {
    private var older: (v: CGFloat, t: CFTimeInterval)?     // the reading before `prev`: whether the lid slows down
    private var prev: (v: CGFloat, t: CFTimeInterval)?
    private var curr: (v: CGFloat, t: CFTimeInterval)?
    private var rampFrom: CGFloat?, rampTarget: CGFloat = 0, rampStart: CFTimeInterval = 0, period: CFTimeInterval = 0.1
    private var target: CGFloat = 0
    private var x: CGFloat = 0, velocityState: CGFloat = 0
    private(set) var value: CGFloat = 0
    private let amount: CGFloat = 1.25
    private let lead: CFTimeInterval = 0.11
    private var opening = false
    private static let sensorPeriod: CFTimeInterval = 0.1
    /// The sensor jitters ±0.05° at rest; smaller changes are ignored.
    let deadband: CGFloat = 0.12

    /// Latest accepted reading (one sample fresher than `value`).
    var latest: CGFloat { curr?.v ?? value }
    /// When the lid last moved by more than the deadband.
    var lastChangeAt: CFTimeInterval { curr?.t ?? 0 }
    /// °/s between the last two readings (negative = closing); 0 if still for more than 0.4 s.
    var velocity: CGFloat {
        guard let c = curr, let p = prev, c.t > p.t, CACurrentMediaTime() - c.t <= 0.4 else { return 0 }
        return (c.v - p.v) / CGFloat(c.t - p.t)
    }

    func push(_ v: CGFloat, at t: CFTimeInterval) {
        defer { lastPush = t }
        // The first reading, or the first after readings stopped (the Mac slept): start right there.
        guard let c = curr, t - lastPush < 0.5 else {
            x = v; target = v; value = v; velocityState = 0; curr = (v, t); prev = nil; older = nil; rampFrom = nil
            return
        }
        guard abs(c.v - v) >= deadband else { return }
        older = prev; prev = c; curr = (v, t)
    }

    /// Fixed opening anticipation, bounded to 18 degrees beyond the latest sensor reading.
    // Prediction and Ahead, by TGTools123.
    private func predicted(at t: CFTimeInterval) -> (angle: CGFloat, velocity: CGFloat) {
        guard let c = curr, let p = prev else { return (curr?.v ?? x, 0) }
        let T = Self.sensorPeriod
        // A first change after a rest happened within the last period, not over the whole rest.
        let v = (c.v - p.v) / CGFloat(min(c.t - p.t, 1.1 * T))
        var a: CGFloat = 0
        if let o = older, p.t > o.t, c.t - o.t < 3.5 * T {
            let v0 = (p.v - o.v) / CGFloat(min(p.t - o.t, 1.1 * T))
            a = (v - v0) / CGFloat(max(0.5 * T, (c.t - o.t) / 2))
        }
        let since = t - c.t, moving = since < 1.2 * T
        // Preserve the upstream 50% opening anticipation, including its extra 30 ms lead.
        let tau = CGFloat(min(since, 1.2 * T) + lead + 0.03)
        let due = CGFloat(min(1, max(0, (since - 1.2 * T) / (0.8 * T))))
        let keep = 1 - due * due * (3 - 2 * due)              // eases out once a reading is overdue
        var d = v * tau
        let speed = moving ? v : 0
        if a * v > 0 { d += a * tau * tau / 2 }
        let limit: CGFloat = 18
        let k = tanh(d / limit)
        return (c.v + limit * k * keep, speed * (1 - k * k) * keep)
    }
    private var lastPush: CFTimeInterval = -.infinity

    @discardableResult
    func step(at t: CFTimeInterval, dt: CFTimeInterval) -> CGFloat {
        guard let c = curr else { return x }
        if rampFrom == nil || rampTarget != c.v {
            rampFrom = target; rampTarget = c.v; rampStart = t
            if let p = prev { period = min(0.3, max(0.06, c.t - p.t)) }
            opening = prev.map { c.v > $0.v } ?? false
        }
        let u = min(1, max(0, (t - rampStart) / (period * Double(amount))))
        target = rampFrom! + (c.v - rampFrom!) * u
        // Prediction: the spring follows the guess, its speed fed forward so the spring adds no lag of its own;
        // softer (ω 22 at 100 %), it spreads out the correction each reading brings.
        var drive = target, driveSpeed: CGFloat = 0, omega = 60 / amount
        if opening {
            (drive, driveSpeed) = predicted(at: t)
            omega = 22 / amount
        }
        // Spring, in sub-steps short enough to stay stable when it's stiff (one step at 100 % and 120 Hz).
        let h = min(dt, 1.0 / 30)
        let substeps = max(1, Int((omega * h / 0.6).rounded(.up)))
        let hs = h / Double(substeps)
        for _ in 0..<substeps {
            velocityState += (-2 * omega * (velocityState - driveSpeed) - omega * omega * (x - drive)) * hs
            x += velocityState * hs
        }
        value = x
        return x
    }
}
