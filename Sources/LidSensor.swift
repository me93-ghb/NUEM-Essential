// Copyright © 2026 TGTools123. NUEM is free software under the GNU GPL v3.
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

    /// Lid angle in degrees — hundredths if the sensor provides them, whole degrees otherwise.
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
    var amount: CGFloat = 1
    /// Prediction (Settings → Motion), 0 = off … 1: the spring follows `predicted(at:)` — the lid's angle guessed
    /// from its speed — instead of the ramp that trails a period behind the readings. 0 leaves the smoother as it
    /// was.
    var lookAhead: CGFloat = 0
    /// How far past the last reading the guess may run (a soft limit): 3°, 6°, 10°, 16° at 25, 50, 75, 100 %.
    private var cap: CGFloat {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0.25, 3), (0.5, 6), (0.75, 10), (1, 16)]
        for i in 1..<points.count where look <= points[i].0 {
            let (x0, y0) = points[i - 1], (x1, y1) = points[i]
            return y0 + (y1 - y0) * (look - x0) / (x1 - x0)
        }
        return 16
    }
    /// Delay the prediction makes up for beyond the last reading: the sensor's own — ≈ 100 ms, measured on film
    /// (2026-09-13: the lid's true angle from the video against the reading shown in the same frames) — and the frame
    /// still to be shown.
    var lead: CFTimeInterval = 0.11
    /// Opening (Settings → Motion → Opening): the smoothing and Prediction used while the lid opens; `amount` and
    /// `lookAhead` are closing's.
    var openAmount: CGFloat = 1, openLookAhead: CGFloat = 0
    /// Ahead (Settings → Motion, closing and opening), 0 = off … 1: the guess stays past the lid in the direction it
    /// moves (see `predicted(at:)`), even with Prediction off.
    var ahead: CGFloat = 0, openAhead: CGFloat = 0
    private var opening = false
    private var look: CGFloat { opening ? openLookAhead : lookAhead }
    private var push: CGFloat { opening ? openAhead : ahead }
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

    /// The lid's angle now, guessed from the last readings: their speed carried on from the last one, plus `lead` —
    /// less the slowing down they show, never past where the lid would stop, and softly limited to `cap` degrees past
    /// the last reading.
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
        // Ahead (here opening; closing mirrors it): the guess keeps running at the last speed while the lid slows
        // (past the lid, on the open side), counts a speeding up in full, and leads a little more.
        let ahead = push > 0.001 && (opening ? v > 0 : v < 0)
        let tau = CGFloat(min(since, 1.2 * T) + lead + (ahead ? 0.06 * Double(push) : 0))
        let due = CGFloat(min(1, max(0, (since - 1.2 * T) / (0.8 * T))))
        let keep = 1 - due * due * (3 - 2 * due)              // eases out once a reading is overdue
        var d = v * tau, speed = moving ? v : 0
        if ahead {
            if a * v > 0 { d += a * tau * tau / 2 }
        } else if a * v < 0 {                                  // slowing down: not past where it would stop
            let tt = min(tau, -v / a)
            d = v * tt + a * tt * tt / 2
            speed = 0
        }
        let limit = max(0.01, ahead ? max(cap, 6 + 24 * push) : cap), k = tanh(d / limit)
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
        let amount = opening ? openAmount : self.amount
        guard amount > 0.001 else {                          // 0 %: the raw readings
            x = c.v; target = c.v; velocityState = 0; value = x
            return x
        }
        let u = min(1, max(0, (t - rampStart) / (period * Double(amount))))
        target = rampFrom! + (c.v - rampFrom!) * u
        // Prediction: the spring follows the guess, its speed fed forward so the spring adds no lag of its own;
        // softer (ω 22 at 100 %), it spreads out the correction each reading brings.
        var drive = target, driveSpeed: CGFloat = 0, omega = 60 / amount
        if look > 0.001 || push > 0.001 {
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
