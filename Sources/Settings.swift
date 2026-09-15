// Part of NUEM by TGTools123. Copyright © 2026 TGTools123, GNU GPL v3.
// Tuning model: scalar settings, the reference formulas built on them, and per-angle curves that can override any of
// them (edited in the Tuning Curves window).

import Cocoa

// NUEM's settings — TGTools123.
enum Settings {
    static let defaults: [String: Any] = [
        // When the effect runs
        "startAngle": 95.0,          // degrees — the effect starts when the lid closes past this angle
        "minAngle": 15.0,            // degrees — fully black below this angle
        "restTimeout": 3.0,          // seconds — within 15° of startAngle, fade out if the lid rests this long (0 = never)
        "captureLead": 0.12,         // seconds — snapshot this far ahead of startAngle at the current speed
        "entryTime": 0.2,            // seconds — catch-up ease when the snapshot arrives late
        "smoothing": 1.25,            // Motion Smoothing: 1 = default, 0 = raw sensor steps, up to 4 = softest
        "lookAhead": 0.0,            // Prediction, 0 (off) … 1: the angle guessed from the lid's speed instead of trailing it
        "closingAhead": 0.0,         // Ahead, 0 (off) … 1: the guess stays past the lid in the direction it moves
        "motionSynced": false,        // Motion smoothing, Prediction and Ahead the same for closing and opening
        "openingSmoothing": 1.25, "openingLookAhead": 0.0, "openingAhead": 0.5,   // opening's own (unlinked)
        // openingSmoothing, openingLookAhead, openingAhead: opening's own (Motion → Opening, unlinked); unset,
        // closing's Adaptive angle (AdaptiveAngle.swift): the fold follows the angle you work at
        "adaptiveAngle": true,
        "adaptiveOffset": 3.0,      // degrees — the fold starts this far below your angle
        "adaptiveSettle": 1.0,       // seconds — the lid held within 1° this long becomes your angle
        // Fold style (Shader.swift): 0 classic, 1 frosted glass, 2 particles, 3 CRT TV, 4 black & white, 5 hologram,
        // 6 CRT filter
        "foldStyle": 0.0,
        "glassStrength": 1.5,
        "particleSize": 5.0,         // points per particle
        "snapAnimation": 8,          // SnapAnimation raw value, or 8 = the one matching the fold style (1, the ripple, is set aside)
        "snapOpacity": 0.5,          // snap animation opacity, 0.1…1
        "snapCornersManual": true,  // the snap glow's corners set by hand (Snap-Back); off: 10 pt all round
        "snapCornerTop": 24.0,       // points
        "snapCornerBottom": 0.0,    // points
        "snapColor": "wallpaper",      // edge glow: "#RRGGBB", or "system" for the Mac's accent color
        "particleGlow": 0.84,         // light around each particle, 0 (plain dots) … 2
        // CRT look, both CRT styles
        "crtScanSize": 10.0,          // points from one scanline to the next
        "crtScanlines": 1.0,         // how dark the gaps between scanlines are, 0…1
        "crtMask": 1.0,             // RGB phosphor stripes, 0…1
        "crtGlow": 2.0,              // bloom around the bright parts, 0…2
        "crtSaturation": 2.0,        // 1 = unchanged
        "crtCurve": 0.7,             // CRT TV: tube curvature
        "hologramColor": "#007AFF",  // "#RRGGBB", or "system" for the Mac's accent color
        "blurTint": 0.0,             // Classic and Frosted glass: how much the blur takes on the tint color (0 = off)
        "blurTintColor": "#FFFFFF",   // "#RRGGBB", or "system" for the Mac's accent color
        "backgroundColor": "#000000", // where no picture lands (Lift, Crop): "#RRGGBB", "system" or "wallpaper"
        "particleColor": "picture",  // particles: "picture" (each its own color from the picture), "#RRGGBB" or "system"
        // Viewer position (perspective)
        "eyeHeight": 1.36,            // eye above the hinge, in screen heights
        "eyeDistance": 1.9,         // eye to screen, in screen heights (≈ 45–50 cm)
        "strength": 0.53,            // κ — share of the real tilt the projection compensates (1 = exact)
        "flipPerspective": false,
        "exactPerspective": false,   // the picture held exactly where the screen was at the start angle, seen from the eye
                                     // above: turned by the lid's own rotation, no compensation share, crop or stretch
        // Crop and stretch, all shaped by progress^stretchCurve
        "cropZoom": 4.0,             // extra vertical zoom anchored at the hinge (crops from the top)
        "lift": 0.0,                 // Lift, cm (−20…20; curve "lift"): the classic fold's pivot below the screen (real hinge 2.3; < 0 above)
        "topStretch": 0.5,           // local magnification near the top (hidden under the black)
        "bottomStretch": 0.0,        // local magnification near the hinge
        "stretchCurve": 2.6,
        // Blur
        "maxBlur": 0.015,            // maximum radius, in screen heights
        "grainyBlur": 0.7,           // grainy (8-tap spiral) share vs smooth blur
        "blurStartAngle": 85.0,      // the blur front leaves the top edge here…
        "blurFullAngle": 20.0,       // …and has covered the whole screen here
        "blurBottom": 0.1,           // blur strength at the hinge relative to the top
        // Black vignette growing from the top edge
        "vignetteStartAngle": 90.0,
        "vignetteTopAngle": 60.0,    // angle at which the black covers `vignetteTopReach`
        "vignetteTopReach": 0.25,    // screen heights
        "vignetteFullAngle": 25.0,   // angle at which the black covers everything
        "vignetteIntensity": 0.8,
        "vignetteEdge": 0.25,
        "keyboardFade": true,       // the keyboard backlight dims with the fold (KeyboardBacklight.swift)…
        "keyboardFadeAngle": 45.0,   // …off by this angle, back to its level when the fold ends
        // Mouse pointer: hidden during the effect and replaced by a copy that fades out
        "cursorFade": true,
        "cursorFadeSpan": 15.0,      // degrees below startAngle over which the pointer fades out
        // Snap back (the screen returning to normal after the lid reopens)
        "snapSound": true,
        "snapHaptic": true,
        "snapHapticLevel": 2,        // trackpad tap strength, 1 (one medium tap) … 5 (burst); 2 = one strong tap
        "snapVolume": 0.7,
        "snapMinDepth": 8.0,         // degrees below startAngle the lid must have gone for the snap feedback
        // Hinge notches: a trackpad click every `detentStep` degrees while the fold plays
        "detents": true,
        "detentStep": 5.0,
        "detentStrong": true,       // strongest waveform instead of a medium one
        "detentHaptic": true,        // a trackpad pulse at each notch
        "detentSound": true,         // the hinge click (Resources/hinge.wav, 3 dB under the snap click) at each notch
        "detentVolume": 0.5,         // its volume (0–1); a bit under the snap's 0.7
        // App
        "effectEnabled": true,
        "lockScreen": true,          // the fold also plays over the lock screen (LockScreen.swift)
        "blurClock": true,           // a lock screen captured > 20 s earlier gets its clock frosted
        "lockScreenAwake": 60.0,     // seconds the lock screen stays on after locking and after the lid moves (0 = while it moves)
        "externalOffWhenClosed": false,   // external displays switched off while the lid is closed (ExternalDisplays.swift)
        "showHUD": false,
        "menuBarStyle": "icon",      // "icon" or "angle"
        "appearance": "system",      // NUEM's windows: "system", "light" or "dark"
    ]

    /// The settings a look (.nuemlook file) carries — everything that shapes the picture, nothing about app behavior
    /// or the snap feedback — and the range values from a shared file are clamped to.
    static let lookRanges: [String: ClosedRange<Double>] = [
        "startAngle": 30...170, "minAngle": 0...60,
        "eyeHeight": 0.2...5, "eyeDistance": 0.5...20, "strength": 0...2.5,
        "cropZoom": 0...6, "lift": -20...20, "topStretch": 0...0.95, "bottomStretch": 0...4, "stretchCurve": 0.2...6,
        "maxBlur": 0...0.15, "grainyBlur": 0...1, "blurStartAngle": 5...170, "blurFullAngle": 0...165, "blurBottom": 0...1,
        "vignetteStartAngle": 0...170, "vignetteTopAngle": 0...170, "vignetteTopReach": 0...1.2, "vignetteFullAngle": 0...170,
        "vignetteIntensity": 0...1, "vignetteEdge": 0...1,
        "cursorFadeSpan": 3...60,
        "foldStyle": 0...6, "glassStrength": 0...1.5, "particleSize": 5...24, "particleGlow": 0...2,
        "crtScanSize": 2...12, "crtScanlines": 0...1, "crtMask": 0...1, "crtGlow": 0...2, "crtSaturation": 0...2, "crtCurve": 0...1.5,
        "blurTint": 0...1,
    ]
    /// Color settings that can follow the Mac's accent color (General → Use Accent Color Everywhere).
    static let colorKeys = ["hologramColor", "snapColor", "blurTintColor", "particleColor"]
    static var lookKeys: [String] { lookRanges.keys.sorted() }

    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func reset() {
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
    }

    private static func number(_ key: String) -> CGFloat { CGFloat(UserDefaults.standard.double(forKey: key)) }
    static var startAngle: CGFloat { min(170, max(30, number("startAngle"))) }
    static var minAngle: CGFloat { number("minAngle") }
    static var restTimeout: CGFloat { number("restTimeout") }
    static var captureLead: CGFloat { number("captureLead") }
    static var entryTime: CGFloat { max(0.01, number("entryTime")) }
    static var smoothing: CGFloat { min(4, max(0, number("smoothing"))) }
    static var adaptiveAngle: Bool { UserDefaults.standard.bool(forKey: "adaptiveAngle") }
    static var adaptiveOffset: CGFloat { min(40, max(2, number("adaptiveOffset"))) }
    static var adaptiveSettle: CFTimeInterval { max(0.3, UserDefaults.standard.double(forKey: "adaptiveSettle")) }
    static var eyeHeight: CGFloat { number("eyeHeight") }
    static var eyeDistance: CGFloat { number("eyeDistance") }
    static var strength: CGFloat { number("strength") }
    static var flipPerspective: Bool { UserDefaults.standard.bool(forKey: "flipPerspective") }
    static var exactPerspective: Bool { UserDefaults.standard.bool(forKey: "exactPerspective") }
    static var lookAhead: CGFloat { min(1, max(0, number("lookAhead"))) }
    struct Motion { var smoothing: CGFloat, lookAhead: CGFloat, ahead: CGFloat }
    static var motionSynced: Bool { UserDefaults.standard.bool(forKey: "motionSynced") }
    /// Motion smoothing, Prediction and Ahead for one way of the lid (Settings → Motion).
    static func motion(opening: Bool) -> Motion {
        let closing = Motion(smoothing: smoothing, lookAhead: lookAhead, ahead: min(1, max(0, number("closingAhead"))))
        guard opening, !motionSynced else { return closing }
        func value(_ key: String, _ fallback: CGFloat, _ top: CGFloat) -> CGFloat {
            UserDefaults.standard.object(forKey: key) == nil ? fallback : min(top, max(0, number(key)))
        }
        return Motion(smoothing: value("openingSmoothing", closing.smoothing, 4),
                      lookAhead: value("openingLookAhead", closing.lookAhead, 1),
                      ahead: value("openingAhead", closing.ahead, 1))
    }
    static var cropZoom: CGFloat { number("cropZoom") }
    static var lift: CGFloat { min(20, max(-20, number("lift"))) }
    static var keyboardFade: Bool { UserDefaults.standard.bool(forKey: "keyboardFade") }
    static var keyboardFadeAngle: CGFloat { min(90, max(0, number("keyboardFadeAngle"))) }
    static var topStretch: CGFloat { number("topStretch") }
    static var bottomStretch: CGFloat { number("bottomStretch") }
    static var stretchCurve: CGFloat { number("stretchCurve") }
    static var maxBlur: CGFloat { number("maxBlur") }
    static var grainyBlur: CGFloat { number("grainyBlur") }
    static var blurStartAngle: CGFloat { number("blurStartAngle") }
    static var blurFullAngle: CGFloat { number("blurFullAngle") }
    static var blurBottom: CGFloat { number("blurBottom") }
    static var vignetteStartAngle: CGFloat { number("vignetteStartAngle") }
    static var vignetteTopAngle: CGFloat { number("vignetteTopAngle") }
    static var vignetteTopReach: CGFloat { number("vignetteTopReach") }
    static var vignetteFullAngle: CGFloat { number("vignetteFullAngle") }
    static var vignetteIntensity: CGFloat { number("vignetteIntensity") }
    static var vignetteEdge: CGFloat { number("vignetteEdge") }
    static var cursorFade: Bool { UserDefaults.standard.bool(forKey: "cursorFade") }
    static var cursorFadeSpan: CGFloat { max(1, number("cursorFadeSpan")) }
    static var snapSound: Bool { UserDefaults.standard.bool(forKey: "snapSound") }
    static var snapHaptic: Bool { UserDefaults.standard.bool(forKey: "snapHaptic") }
    static var snapVolume: CGFloat { number("snapVolume") }
    static var snapMinDepth: CGFloat { number("snapMinDepth") }
    static var lockScreen: Bool { UserDefaults.standard.bool(forKey: "lockScreen") }
    static var blurClock: Bool { UserDefaults.standard.bool(forKey: "blurClock") }
    static var lockScreenAwake: CGFloat { min(600, max(0, number("lockScreenAwake"))) }
    static var externalOffWhenClosed: Bool { UserDefaults.standard.bool(forKey: "externalOffWhenClosed") }
    /// Testing: the clock veil also on a fresh lock screen capture (`defaults write … forceClockBlur -bool true`).
    static var forceClockBlur: Bool { UserDefaults.standard.bool(forKey: "forceClockBlur") }
    static var foldStyle: Int { min(6, max(0, Int(number("foldStyle").rounded()))) }
    static var glassStrength: CGFloat { min(1.5, max(0, number("glassStrength"))) }
    static var particleSize: CGFloat { min(24, max(5, number("particleSize"))) }
    static var snapAnimation: Int {
        let value = UserDefaults.standard.integer(forKey: "snapAnimation")
        return value == 1 ? SnapAnimation.matchStyle : value   // the ripple is set aside for now
    }
    /// The snap animation that plays, with "match the fold style" resolved.
    static var snapAnimationKind: SnapAnimation {
        let value = snapAnimation
        return value == SnapAnimation.matchStyle ? .forStyle(foldStyle) : SnapAnimation(rawValue: value) ?? .none
    }
    static var snapOpacity: CGFloat { min(1, max(0.1, number("snapOpacity"))) }
    static var snapCornersManual: Bool { UserDefaults.standard.bool(forKey: "snapCornersManual") }
    /// The screen's corner radii for the snap glow (points). macOS doesn't tell them (NSScreen and the IORegistry
    /// have nothing, and the framebuffer is square: the panel masks its corners), so 10 pt unless they're set by
    /// hand.
    static var snapCorners: (top: CGFloat, bottom: CGFloat) {
        guard snapCornersManual else { return (10, 10) }
        return (min(60, max(0, number("snapCornerTop"))), min(60, max(0, number("snapCornerBottom"))))
    }
    static var particleGlow: CGFloat { min(2, max(0, number("particleGlow"))) }
    static var crtScanSize: CGFloat { min(12, max(2, number("crtScanSize"))) }
    static var crtScanlines: CGFloat { min(1, max(0, number("crtScanlines"))) }
    static var crtMask: CGFloat { min(1, max(0, number("crtMask"))) }
    static var crtGlow: CGFloat { min(2, max(0, number("crtGlow"))) }
    static var crtSaturation: CGFloat { min(2, max(0, number("crtSaturation"))) }
    static var crtCurve: CGFloat { min(1.5, max(0, number("crtCurve"))) }
    static var blurTint: CGFloat { min(1, max(0, number("blurTint"))) }

    /// Particles in a chosen color rather than each in its own from the picture.
    static var particleColorOn: Bool { (UserDefaults.standard.string(forKey: "particleColor") ?? "picture") != "picture" }

    /// The fold style has a color of its own: the blur tint on Classic and Frosted glass when it's on, a chosen
    /// particle color, the hologram's.
    static var foldStyleHasColor: Bool {
        (foldStyle <= 1 && blurTint > 0) || (foldStyle == 2 && particleColorOn) || foldStyle == 5
    }

    /// The color setting the snap animation takes its color from: matching the fold style, the style's own if it has
    /// one; otherwise the Snap-Back color.
    static var snapColorKey: String {
        guard snapAnimation == SnapAnimation.matchStyle, foldStyleHasColor else { return "snapColor" }
        return foldStyle == 5 ? "hologramColor" : foldStyle == 2 ? "particleColor" : "blurTintColor"
    }
    static var snapAnimationColor: SIMD3<Float> { color(snapColorKey) }

    /// The colors set to the wallpaper's, as the shader's mask: 1 hologram, 2 snap animation, 4 blur tint, 8
    /// particles.
    static var wallpaperMask: Int {
        func wallpaper(_ key: String) -> Bool { UserDefaults.standard.string(forKey: key) == "wallpaper" }
        return (wallpaper("hologramColor") ? 1 : 0) | (wallpaper(snapColorKey) ? 2 : 0)
            | (wallpaper("blurTintColor") ? 4 : 0) | (wallpaper("particleColor") ? 8 : 0)
    }

    /// A color setting — "#RRGGBB", "system" for the Mac's accent color, "wallpaper" for the blurred wallpaper (its
    /// average here; the effects read it by position) or "wallpaper:N" for its Nth main color — as sRGB components.
    static func color(_ key: String) -> SIMD3<Float> {
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        let main = value.hasPrefix("wallpaper:") ? Int(value.dropFirst("wallpaper:".count)) : nil
        let chosen = value == "system" ? NSColor.controlAccentColor
            : value == "wallpaper" ? Wallpaper.average ?? .controlAccentColor
            : main.map { index in Wallpaper.mainColors.indices.contains(index) ? Wallpaper.mainColors[index] : Wallpaper.average ?? .controlAccentColor }
            ?? NSColor(hex: value) ?? .white
        let color = chosen.usingColorSpace(.sRGB) ?? .white
        return SIMD3(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
    }
    static var detents: Bool { UserDefaults.standard.bool(forKey: "detents") }
    static var detentStep: CGFloat { min(30, max(3, number("detentStep"))) }
    static var detentStrong: Bool { UserDefaults.standard.bool(forKey: "detentStrong") }
    static var detentHaptic: Bool { UserDefaults.standard.bool(forKey: "detentHaptic") }
    static var detentSound: Bool { UserDefaults.standard.bool(forKey: "detentSound") }
    static var detentVolume: CGFloat { min(1, max(0, number("detentVolume"))) }
}

func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
func smoothstep(_ x: CGFloat) -> CGFloat { let c = clamp01(x); return c * c * (3 - 2 * c) }

/// Default behavior of each parameter as a function of the lid angle (the gray lines in the curve editor).
enum Formula {
    /// 0 at `startAngle`, 1 when closed.
    static func progress(_ angle: CGFloat) -> CGFloat { clamp01((Settings.startAngle - angle) / Settings.startAngle) }
    private static func shape(_ angle: CGFloat) -> CGFloat { pow(progress(angle), Settings.stretchCurve) }

    static func crop(_ angle: CGFloat) -> CGFloat { Settings.cropZoom * shape(angle) }
    static func topStretch(_ angle: CGFloat) -> CGFloat { Settings.topStretch * shape(angle) }
    static func bottomStretch(_ angle: CGFloat) -> CGFloat { min(0.75, Settings.bottomStretch * shape(angle)) }

    /// How far the blur front has travelled down from the top edge (1.3 = its soft edge has left the screen).
    static func blurReach(_ angle: CGFloat) -> CGFloat {
        let start = Settings.blurStartAngle, full = min(start - 5, Settings.blurFullAngle)
        return 1.3 * clamp01((start - angle) / (start - full))
    }

    /// The black grows from the top edge while fading in (vignetteStartAngle → vignetteTopAngle), then extends to the
    /// whole screen (→ vignetteFullAngle).
    private static var vignetteAngles: (start: CGFloat, top: CGFloat, full: CGFloat) {
        let full = Settings.vignetteFullAngle, top = max(full + 5, Settings.vignetteTopAngle)
        return (min(Settings.startAngle, max(top + 5, Settings.vignetteStartAngle)), top, full)
    }
    static func vignetteReach(_ angle: CGFloat) -> CGFloat {
        let v = vignetteAngles, reach = Settings.vignetteTopReach
        if angle >= v.top { return reach * smoothstep((v.start - angle) / (v.start - v.top)) }
        return reach + (1.2 - reach) * pow(clamp01((v.top - angle) / (v.top - v.full)), 1.5)
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

struct CurvePoint: Codable { var angle: Double; var value: Double }

/// One parameter as a function of the lid angle.
final class ParamCurve {
    let id: String, title: String, hint: String, maxValue: CGFloat, minValue: CGFloat
    let landmarks: [(value: CGFloat, label: String)]
    let formula: (CGFloat) -> CGFloat
    let builtIn: [CurvePoint]
    private(set) var points: [CurvePoint] = []
    private var samples: [CGFloat] = []          // every 0.1°, from 0° to startAngle
    private var key: String { "curve.\(id)" }

    init(_ id: String, _ title: String, max: CGFloat, min: CGFloat = 0, hint: String, landmarks: [(value: CGFloat, label: String)] = [],
         builtIn: [CurvePoint] = [], formula: @escaping (CGFloat) -> CGFloat) {
        self.id = id; self.title = title; self.maxValue = max; self.minValue = min; self.hint = hint
        self.landmarks = landmarks; self.builtIn = builtIn; self.formula = formula
        reload()
    }

    func value(at angle: CGFloat) -> CGFloat {
        guard !samples.isEmpty else { return formula(angle) }
        let a = min(CGFloat(samples.count - 1), max(0, angle * 10))
        let i = Int(a), f = a - CGFloat(i)
        if i >= samples.count - 1 { return samples[samples.count - 1] }
        return samples[i] + (samples[i + 1] - samples[i]) * f
    }

    func set(_ newPoints: [CurvePoint]) {
        points = newPoints.sorted { $0.angle < $1.angle }
        if let data = try? JSONEncoder().encode(points) { UserDefaults.standard.set(data, forKey: key) }
        rebuild()
    }
    func resetToDefault() { UserDefaults.standard.removeObject(forKey: key); reload() }
    func reload() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([CurvePoint].self, from: data) {
            points = saved
        } else {
            points = builtIn
        }
        rebuild()
    }

    private func rebuild() {
        guard !points.isEmpty else { samples = []; return }
        let start = Settings.startAngle
        var xs = points.map { CGFloat($0.angle) }, ys = points.map { CGFloat($0.value) }
        if let last = xs.last, last < start - 0.5 { xs.append(start); ys.append(formula(start)) }
        let f = monotoneCubic(xs, ys)
        samples = (0...Int(start * 10)).map { i in
            let x = CGFloat(i) / 10
            if x <= xs[0] { return ys[0] }
            if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
            return max(minValue, f(x))
        }
    }
}

/// Fritsch–Carlson monotone cubic interpolation (no overshoot between points).
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

/// Every tunable curve. The built-in points are the shipped look.
// Curves by TGTools123.
final class Curves {
    let crop = ParamCurve("crop", "Crop (extra vertical zoom − 1)", max: 3,
        hint: "Vertical zoom anchored at the hinge: 0 = none, 1 = content ×2 tall (its top half leaves the screen), 3 = ×4. Real cropping = this + perspective.",
        landmarks: [(1, "×2: top half off-screen"), (0.5, "×1.5")],
        builtIn: [.init(angle: 17.7, value: 3), .init(angle: 53.5, value: 0.253), .init(angle: 72.0, value: 0.102), .init(angle: 91.9, value: 0), .init(angle: 95, value: 0)],
        formula: Formula.crop)
    let top = ParamCurve("top", "Top stretch", max: 0.9,
        hint: "Local magnification just below the crop line, where the black hides it. 0 = none, 0.5 = ×2, 0.9 = ×10. Crops without stretching the bottom.",
        landmarks: [(0.5, "top ×2")],
        builtIn: [.init(angle: 0, value: 0.5), .init(angle: 15.8, value: 0.312), .init(angle: 44.7, value: 0.44), .init(angle: 60.1, value: 0.043), .init(angle: 90.1, value: 0)],
        formula: Formula.topStretch)
    let bottom = ParamCurve("bottom", "Bottom stretch", max: 0.9,
        hint: "Local magnification near the hinge (the Dock). 0 = 1:1, 0.5 = ×2, 0.9 = ×10. Too much makes the whole screen look elongated.",
        landmarks: [(0.5, "bottom ×2")],
        builtIn: [.init(angle: 0, value: 0.687), .init(angle: 78.2, value: 0), .init(angle: 95, value: 0)],
        formula: Formula.bottomStretch)
    let lift = ParamCurve("lift", "Lift (cm below the screen's bottom edge)", max: 20, min: -20,
        hint: "Classic fold: it turns about a point this far below the screen's bottom edge, so the picture rises as the lid folds. The real hinge is 2.3 cm below. Negative: the point is up the screen and the picture sinks. Off with Exact perspective.",
        landmarks: [(2.33, "the real hinge"), (0, "none")],
        builtIn: [.init(angle: 0, value: 0.834), .init(angle: 95, value: 0.173)],
        formula: { _ in Settings.lift })
    let strength = ParamCurve("strength", "Perspective compensation κ", max: 1.5,
        hint: "Share of the real tilt compensated by the projection. 0 = flat image, 1 = exact geometry for the eye position (content looks upright), > 1 = over-tilted.",
        landmarks: [(1, "exact geometry"), (0.5, "half")], formula: { _ in Settings.strength })
    let eyeHeight = ParamCurve("eyeHeight", "Eye height (screen heights above the hinge)", max: 3,
        hint: "0.5 = facing the center of the screen, 1.0 = top of the screen at eye level (typical desk posture), 1.8 = looking down steeply → more cropping and magnification.",
        landmarks: [(0.5, "facing center"), (1, "top at eye level"), (1.8, "looking down")], formula: { _ in Settings.eyeHeight })
    let eyeDistance = ParamCurve("eyeDistance", "Eye distance (screen heights)", max: 8,
        hint: "One screen height is ≈ 20–22 cm on a 14–16\" MacBook. Farther = flatter (more orthographic), closer = stronger keystone.",
        landmarks: [(2.5, "≈ 50–55 cm"), (3.3, "≈ 65–75 cm"), (4.7, "≈ 1 m")], formula: { _ in Settings.eyeDistance })
    let blur = ParamCurve("blur", "Blur front reach (1.3 = whole screen)", max: 1.3,
        hint: "How far the blur front has travelled down from the top edge: 0.5 = half the screen, 1 = reaches the hinge, 1.3 = its soft leading edge has fully passed.",
        landmarks: [(0.5, "half the screen"), (1, "hinge reached")],
        builtIn: [.init(angle: 57.2, value: 1.093), .init(angle: 83.0, value: 0.25), .init(angle: 90.4, value: 0), .init(angle: 95, value: 0)],
        formula: Formula.blurReach)
    let blurAmount = ParamCurve("blurAmount", "Blur amount (× max blur)", max: 1.5,
        hint: "Multiplies the blur radius behind the front. 1 = the `maxBlur` setting.",
        landmarks: [(1, "maxBlur")], formula: { _ in 1 })
    let grainy = ParamCurve("grainy", "Grainy blur share (0…1)", max: 1,
        hint: "Mix between smooth blur (0) and a grainy, 8-tap spiral blur of the sharp image (1).",
        builtIn: [.init(angle: 0, value: 1), .init(angle: 95, value: 0.08)], formula: { _ in Settings.grainyBlur })
    let vignette = ParamCurve("vignette", "Black reach from the top (1.2 = whole screen)", max: 1.2,
        hint: "How far the black has grown down from the top edge: 0.25 = top quarter (solid over 60 % of the reach, then a gradient), 1.2 = everything.",
        landmarks: [(0.25, "top quarter"), (0.5, "half"), (1, "hinge reached")],
        builtIn: [.init(angle: 26.0, value: 1.2), .init(angle: 49.8, value: 0.27), .init(angle: 78.2, value: 0.22),
                  .init(angle: 91.9, value: 0)],
        formula: Formula.vignetteReach)
    let vignetteOpacity = ParamCurve("vignetteOpacity", "Black opacity (0…1)", max: 1,
        hint: "Opacity of the black (× vignetteIntensity).", landmarks: [(1, "full")], formula: Formula.vignetteOpacity)
    let dark = ParamCurve("dark", "Content darkening (× demo curve)", max: 1.5,
        hint: "Multiplies the iPhone Duo demo's darkening, applied in content space behind the blur front. 0 = none, 1 = as in the demo.",
        landmarks: [(1, "as in the demo")], formula: { _ in 1 })
    let cursor = ParamCurve("cursor", "Mouse pointer opacity (0…1)", max: 1,
        hint: "Opacity of the pointer during the effect (the real pointer is hidden and replaced by a copy). 1 = visible, 0 = gone. Needs “Fade the pointer” on (Settings → Effect Console).",
        landmarks: [(1, "visible"), (0.5, "half")], formula: Formula.cursorOpacity)
    let overlay = ParamCurve("overlay", "Overall effect opacity (0…1)", max: 1,
        hint: "Opacity of the whole effect window: 1 = the effect, 0 = the real desktop. Ignored below 30°: the desktop never comes back there (it would light the screen up over the keyboard).",
        landmarks: [(1, "full effect")], formula: { _ in 1 })

    var all: [ParamCurve] { [crop, top, bottom, lift, strength, eyeHeight, eyeDistance, blur, blurAmount, grainy, vignette, vignetteOpacity, dark, cursor, overlay] }
    func reloadAll() { all.forEach { $0.reload() } }
}

extension NSColor {
    /// "#RRGGBB" (sRGB); nil if it isn't one.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? .white
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
