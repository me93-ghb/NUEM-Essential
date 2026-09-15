// Copyright © 2026 TGTools123 (NUEM). GNU GPL v3.
// Adaptive angle: the fold follows the angle you actually work at instead of a fixed start angle. - Your angle: when
// the lid stays within ±1° for `adaptiveSettle` seconds (open at least 75°), that's your viewing angle.

import QuartzCore

// Written by TGTools123 for NUEM.
final class AdaptiveAngle {
    static let lowestViewingAngle: CGFloat = 75            // a lid held lower than this isn't a viewing angle
    static let glideDuration: CFTimeInterval = 0.6

    private var rest: CGFloat?                             // your viewing angle, once the lid has settled
    private var glide: (from: CGFloat, to: CGFloat, since: CFTimeInterval)?
    private var still: (angle: CGFloat, since: CFTimeInterval)?

    /// Your viewing angle (nil until the lid first settles, or when the feature is off).
    var viewingAngle: CGFloat? { Settings.adaptiveAngle ? (glide?.to ?? rest) : nil }

    /// Where the fold starts now.
    func start(at now: CFTimeInterval) -> CGFloat {
        guard Settings.adaptiveAngle, let rest = restAngle(at: now) else { return Settings.startAngle }
        return min(170, max(30, rest - Settings.adaptiveOffset))
    }

    /// Every sensor reading (degrees). `effectVisible`: the fold is on screen. `paused`: tuning or preview.
    func observe(_ angle: CGFloat, at now: CFTimeInterval, effectVisible: Bool, paused: Bool) {
        guard Settings.adaptiveAngle, !paused else { still = nil; return }
        if let g = glide {
            if now - g.since >= Self.glideDuration {
                rest = g.to
                glide = nil
            } else if abs(angle - g.to) > 1.5 {             // the lid moved again: stay where the glide got to
                rest = restAngle(at: now)
                glide = nil
            }
        }
        guard let s = still, abs(angle - s.angle) < 1 else { still = (angle, now); return }
        guard now - s.since >= Settings.adaptiveSettle, glide == nil, angle >= Self.lowestViewingAngle else { return }
        still = (angle, now)
        let current = rest ?? Settings.startAngle + Settings.adaptiveOffset
        guard abs(angle - current) >= 1 else { return }
        if effectVisible { glide = (current, angle, now) } else { rest = angle }
    }

    /// The angle the tuning is written for, for a lid at `angle`.
    func reference(_ angle: CGFloat, at now: CFTimeInterval) -> CGFloat {
        let s = start(at: now), sRef = Settings.startAngle
        guard Settings.adaptiveAngle, abs(s - sRef) > 0.001 else { return angle }
        if angle >= s { return sRef + (angle - s) }
        return sRef * pow(max(0, angle) / s, s / sRef)
    }

    /// How far the lid has turned from where the fold starts, in real degrees, for an angle of the tuning (the
    /// inverse of `reference`): the exact perspective turns the picture by just that.
    func lidRotation(_ reference: CGFloat, at now: CFTimeInterval) -> CGFloat {
        let s = start(at: now), sRef = Settings.startAngle
        guard Settings.adaptiveAngle, abs(s - sRef) > 0.001, reference < sRef else { return sRef - reference }
        return s - s * pow(max(0, reference) / sRef, sRef / s)
    }

    private func restAngle(at now: CFTimeInterval) -> CGFloat? {
        guard let g = glide else { return rest }
        let u = smoothstep(CGFloat((now - g.since) / Self.glideDuration))
        return g.from + (g.to - g.from) * u
    }
}
