// Copyright © 2026 TGTools123. NUEM, GNU GPL v3.
// Modified 2026-09-20 for NUEM-Essential: fixed classic tuning, no preset/editor storage.
import Cocoa

enum Settings {
    static func register() {
        UserDefaults.standard.register(defaults: ["effectEnabled": true, "adaptiveAngle": true,
                                                 "cursorFade": true, "showMenuBarIcon": true])
    }
    static var effectEnabled: Bool { UserDefaults.standard.bool(forKey: "effectEnabled") }
    static var adaptiveAngle: Bool { UserDefaults.standard.bool(forKey: "adaptiveAngle") }
    static var cursorFade: Bool { UserDefaults.standard.bool(forKey: "cursorFade") }
    static let startAngle: CGFloat = 95
    static let minAngle: CGFloat = 15
    static let adaptiveOffset: CGFloat = 3
    static let adaptiveSettle: Double = 1
    static let vignetteStartAngle: CGFloat = 90
    static let vignetteTopAngle: CGFloat = 60
    static let vignetteFullAngle: CGFloat = 25
    static let cursorFadeSpan: CGFloat = 15
    static let maxBlur: CGFloat = 0.015
}

struct Curve {
    private let samples: [CGFloat]
    init(_ points: [(CGFloat, CGFloat)], end: CGFloat, minimum: CGFloat = 0) {
        var points = points
        if let last = points.last, last.0 < Settings.startAngle - 0.5 { points.append((Settings.startAngle, end)) }
        let f = monotoneCubic(points.map { $0.0 }, points.map { $0.1 })
        samples = (0...Int(Settings.startAngle * 10)).map { i in
            let x = CGFloat(i) / 10
            if x <= points[0].0 { return points[0].1 }
            if x >= points.last!.0 { return points.last!.1 }
            return max(minimum, f(x))
        }
    }
    func value(at angle: CGFloat) -> CGFloat {
        let a = min(CGFloat(samples.count - 1), max(0, angle * 10))
        let i = Int(a), f = a - CGFloat(i)
        return i >= samples.count - 1 ? samples[i] : samples[i] + (samples[i+1] - samples[i]) * f
    }
}

func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
func smoothstep(_ x: CGFloat) -> CGFloat { let c = clamp01(x); return c * c * (3 - 2 * c) }

/// Fixed classic fold timing.
enum Formula {
    /// 0 at `startAngle`, 1 when closed.
    static func progress(_ angle: CGFloat) -> CGFloat { clamp01((Settings.startAngle - angle) / Settings.startAngle) }
    /// The black grows from the top edge while fading in (vignetteStartAngle → vignetteTopAngle), then extends to the
    /// whole screen (→ vignetteFullAngle).
    private static var vignetteAngles: (start: CGFloat, top: CGFloat, full: CGFloat) {
        let full = Settings.vignetteFullAngle, top = max(full + 5, Settings.vignetteTopAngle)
        return (min(Settings.startAngle, max(top + 5, Settings.vignetteStartAngle)), top, full)
    }
    static func vignetteOpacity(_ angle: CGFloat) -> CGFloat {
        let v = vignetteAngles
        return angle >= v.top ? smoothstep((v.start - angle) / (v.start - v.top)) : 1
    }

    /// The pointer copy fades out over `cursorFadeSpan` degrees below startAngle.
    static func cursorOpacity(_ angle: CGFloat) -> CGFloat {
        smoothstep(1 - (Settings.startAngle - angle) / Settings.cursorFadeSpan)
    }
}

func monotoneCubic(_ x: [CGFloat], _ y: [CGFloat]) -> (CGFloat) -> CGFloat {
    let n = x.count
    guard n >= 2 else { return { _ in y.first ?? 0 } }
    var h = [CGFloat](), d = [CGFloat]()
    for i in 0..<(n - 1) { h.append(x[i + 1] - x[i]); d.append((y[i + 1] - y[i]) / max(1e-6, x[i + 1] - x[i])) }
    var m = [CGFloat](repeating: 0, count: n)
    m[0] = d[0]; m[n - 1] = d[n - 2]
    for i in 1..<(n - 1) where d[i - 1] * d[i] > 0 {
        let w1 = 2 * h[i] + h[i - 1], w2 = h[i] + 2 * h[i - 1]
        m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
    }
    return { xv in
        var i = 0
        while i < n - 2 && xv > x[i + 1] { i += 1 }
        let t = (xv - x[i]) / max(1e-6, h[i]), t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y[i] + (t3 - 2 * t2 + t) * h[i] * m[i]
             + (-2 * t3 + 3 * t2) * y[i + 1] + (t3 - t2) * h[i] * m[i + 1]
    }
}

final class Curves {
    let crop = Curve([(17.7,3), (53.5,0.253), (72,0.102), (91.9,0), (95,0)], end: 0)
    let top = Curve([(0,0.5), (15.8,0.312), (44.7,0.44), (60.1,0.043), (90.1,0)], end: 0)
    let bottom = Curve([(0,0.687), (78.2,0), (95,0)], end: 0)
    let lift = Curve([(0,0.834), (95,0.173)], end: 0, minimum: -20)
    let blur = Curve([(57.2,1.093), (83,0.25), (90.4,0), (95,0)], end: 0)
    let grainy = Curve([(0,1), (95,0.08)], end: 0.7)
    let vignette = Curve([(26,1.2), (49.8,0.27), (78.2,0.22), (91.9,0)], end: 0)
}
