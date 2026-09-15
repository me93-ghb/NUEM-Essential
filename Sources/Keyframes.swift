// NUEM, by TGTools123. Copyright © 2026 TGTools123, GNU GPL v3.
// Keyframes mode (menu → Keyframes…): the fold shaped by hand, apart from every setting.

import Foundation
import simd

struct Quad: Codable, Equatable {
    /// Heights from the screen's bottom edge and widths, as fractions of the screen.
    var topY: Double, topWidth: Double, bottomY: Double, bottomWidth: Double
    /// Sideways shift of each edge's middle, as a fraction of the screen's width (+ = right): the sides lean on their
    /// own.
    var topShift: Double = 0, bottomShift: Double = 0
    static let identity = Quad(topY: 1, topWidth: 1, bottomY: 0, bottomWidth: 1)
}

extension Quad {
    /// Keyframes saved before the shifts existed have none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topY = try c.decode(Double.self, forKey: .topY)
        topWidth = try c.decode(Double.self, forKey: .topWidth)
        bottomY = try c.decode(Double.self, forKey: .bottomY)
        bottomWidth = try c.decode(Double.self, forKey: .bottomWidth)
        topShift = try c.decodeIfPresent(Double.self, forKey: .topShift) ?? 0
        bottomShift = try c.decodeIfPresent(Double.self, forKey: .bottomShift) ?? 0
    }
}

struct Keyframe: Codable, Identifiable, Equatable {
    var id = UUID()
    var angle: Double
    var quad: Quad
}

// Keyframes, TGTools123.
final class KeyframeStore: ObservableObject {
    static let shared = KeyframeStore()
    /// NUEM draws the fold from the keyframes instead of the settings.
    @Published var isOn = false { didSet { if isOn != oldValue { save() } } }
    @Published private(set) var keyframes: [Keyframe] = []
    /// Being edited, not saved yet: shown at every angle until Keyframe or Discard.
    @Published var pending: Quad?
    /// The lid and the fold's start, for the window (15 times a second while it's open).
    @Published var liveAngle: Double = 0
    @Published var start: Double = 95

    private struct Saved: Codable { var on: Bool; var keyframes: [Keyframe] }
    private let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NUEM")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("keyframes.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            isOn = saved.on
            keyframes = saved.keyframes.sorted { $0.angle > $1.angle }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(Saved(on: isOn, keyframes: keyframes)).write(to: file, options: .atomic)
    }

    /// Saves `quad` at `angle` rounded to a whole degree, replacing the keyframe already there.
    func commit(_ quad: Quad, at angle: Double) {
        let whole = angle.rounded()
        keyframes.removeAll { $0.angle.rounded() == whole }
        keyframes.append(Keyframe(angle: whole, quad: quad))
        keyframes.sort { $0.angle > $1.angle }
        pending = nil
        save()
    }
    func remove(_ id: UUID) { keyframes.removeAll { $0.id == id }; save() }
    func removeAll() { keyframes = []; pending = nil; save() }

    /// The picture's trapezoid for a lid at `angle`, the fold starting at `start`.
    func quad(at angle: Double, start: Double) -> Quad {
        if let pending { return pending }
        let frames = keyframes.filter { $0.angle < start - 0.5 }.sorted { $0.angle < $1.angle }
        guard !frames.isEmpty, angle < start else { return .identity }
        let xs = frames.map { CGFloat($0.angle) } + [CGFloat(start)]
        func value(_ field: KeyPath<Quad, Double>, _ untouched: Double) -> Double {
            let ys = frames.map { CGFloat($0.quad[keyPath: field]) } + [CGFloat(untouched)]
            if angle <= Double(xs[0]) { return Double(ys[0]) }
            return Double(monotoneCubic(xs, ys)(CGFloat(angle)))
        }
        return Quad(topY: value(\.topY, 1), topWidth: value(\.topWidth, 1), bottomY: value(\.bottomY, 0), bottomWidth: value(\.bottomWidth, 1),
                    topShift: value(\.topShift, 0), bottomShift: value(\.bottomShift, 0))
    }
}

// NUEM · TGTools123
extension Quad {
    /// Screen point → picture point (both in points, top-left origin), for the shader: the inverse of the homography
    /// that takes the picture's rectangle onto this trapezoid (square to quad, Heckbert 1989).
    func screenToPicture(size: CGSize) -> simd_double3x3 {
        let w = Double(size.width), h = Double(size.height)
        let top = h * (1 - topY), bottom = h * (1 - bottomY)
        // Corners on screen: top left, top right, bottom right, bottom left.
        let (x0, y0) = (w * ((1 - topWidth) / 2 + topShift), top), (x1, y1) = (w * ((1 + topWidth) / 2 + topShift), top)
        let (x2, y2) = (w * ((1 + bottomWidth) / 2 + bottomShift), bottom), (x3, y3) = (w * ((1 - bottomWidth) / 2 + bottomShift), bottom)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g = 0.0, k = 0.0
        let den = dx1 * dy2 - dx2 * dy1
        if abs(dx3) > 1e-9 || abs(dy3) > 1e-9, abs(den) > 1e-9 {
            g = (dx3 * dy2 - dx2 * dy3) / den
            k = (dx1 * dy3 - dx3 * dy1) / den
        }
        let square = simd_double3x3(rows: [SIMD3(x1 - x0 + g * x1, x3 - x0 + k * x3, x0),   // unit square → screen
                                           SIMD3(y1 - y0 + g * y1, y3 - y0 + k * y3, y0),
                                           SIMD3(g, k, 1)])
        let picture = simd_double3x3(rows: [SIMD3(w, 0, 0), SIMD3(0, h, 0), SIMD3(0, 0, 1)])   // unit square → picture
        return picture * square.inverse
    }
}
