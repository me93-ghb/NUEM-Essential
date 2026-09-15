// Copyright © 2026 TGTools123. Part of NUEM, under the GNU GPL v3.
// The fold effect: a borderless window over the built-in screen showing a snapshot of that screen, re-projected so
// the content seems to stay upright while the panel tilts toward the keyboard, with a blur front and a black vignette
// growing from the top edge as the lid closes.

import Cocoa
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MetalKit
import QuartzCore
import ScreenCaptureKit
import Vision
import os

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NUEM", category: "effect")

/// Diagnostics: every step of the effect's life in the log, when `trace` is on (`defaults write
/// io.github.tgtools123.nuem trace -bool true`; read with Console or `log show`).
private var traceTimes: [String: CFTimeInterval] = [:]
func trace(_ message: @autoclosure () -> String, every interval: CFTimeInterval = 0, key: String? = nil) {
    guard UserDefaults.standard.bool(forKey: "trace") else { return }
    let text = message()
    if interval > 0 {
        let now = CACurrentMediaTime(), k = key ?? text
        if let last = traceTimes[k], now - last < interval { return }
        traceTimes[k] = now
    }
    logger.notice("trace: \(text, privacy: .public)")
}

enum EffectState: String {
    case idle = "Idle", capturing = "Capturing…", ready = "Ready", active = "Active"
    case needsPermission = "Needs Screen Recording permission", captureFailed = "Capture failed"
    case noDisplay = "Built-in display unavailable"
    case mirrored = "Off while the display is mirrored"
}

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }
    var isBuiltin: Bool { CGDisplayIsBuiltin(displayID) != 0 }
}

/// Pre-blurred copies of the snapshot, increasing radii, rendered with a margin so edges bleed into black.
private struct BlurSet {
    let textures: [MTLTexture]
    let radii: [CGFloat]        // points
    let margins: [CGFloat]      // points beyond each screen edge
}

/// ScreenCaptureKit lists no display while it sleeps, nor for a moment after it turns on.
private enum CaptureError: Error { case displayNotListed, stillDark }

/// A snapshot and its blur set.
private final class Snapshot {
    let sharp: MTLTexture
    let blurs: BlurSet
    let locked: Bool                         // it shows the lock screen
    let takenAt: CFTimeInterval
    let takenDate = Date()
    let signature: String                    // the display it belongs to (FoldOverlay.signature)
    var clock: CGRect?                       // lock screen: where the time and date are (normalized, top-left origin)
    /// The lock screen's clock in it still shows the right time.
    var showsCurrentMinute: Bool {
        Calendar.current.isDate(takenDate.addingTimeInterval(-2), equalTo: Date(), toGranularity: .minute)
    }

    init(sharp: MTLTexture, blurs: BlurSet, locked: Bool, takenAt: CFTimeInterval, signature: String) {
        self.sharp = sharp; self.blurs = blurs; self.locked = locked; self.takenAt = takenAt; self.signature = signature
    }
}

/// Snapshots kept so an opening can draw from its first frame instead of waiting for a capture (≈ 60 MB of GPU memory
/// each, never written anywhere): - the lock screen, from every capture made while locked (and one taken just after
/// each lock); kept across unlocks — it only ever shows on the lock screen, and only what the lock screen shows
/// anyone — so a lid that locks the Mac as it closes (the display already off: nothing to capture) still unfolds from
/// the first frame; - the desktop, only when the lid closes all the way (the Mac goes to sleep, or the built-in
/// display goes away with an external one); used once, and for 30 minutes at most.
private enum SnapshotCache {
    static var desktop: Snapshot?
    static var lockScreen: Snapshot?

    static func store(_ snapshot: Snapshot) {
        if snapshot.locked { lockScreen = snapshot } else { desktop = snapshot }
    }

    static func take(locked: Bool, signature: String, now: CFTimeInterval) -> Snapshot? {
        if locked { return lockScreen?.signature == signature ? lockScreen : nil }
        defer { desktop = nil }
        guard let desktop, desktop.signature == signature, now - desktop.takenAt < 30 * 60 else { return nil }
        return desktop
    }
}

/// Same memory layout as `Uniforms` in Shader.swift.
private struct Uniforms {
    var radii: SIMD4<Float>, margins: SIMD4<Float>
    var size: SIMD2<Float>, scale: Float, D: Float
    var A: Float, sinPhi: Float, s: Float, rMax: Float
    var levels: Int32, black: Int32, bottom: Float, top: Float
    var crop: Float, vignette: Float, vignetteReach: Float, vignetteEdge: Float
    var blurReach: Float, blurBottom: Float, grainy: Float, blurScale: Float
    var darkScale: Float, brightness: Float
    var veil: SIMD4<Float>
    var style: Int32, fx: Int32, styleAmount: Float, fxTime: Float
    var glassStrength: Float, particleSize: Float, time: Float, corner: Float
    var holoColor: SIMD4<Float>, fxColor: SIMD4<Float>
    var particleGlow: Float, crtScan: Float, crtScanlines: Float, crtGlow: Float
    var crtSaturation: Float, crtMask: Float, crtCurve: Float, veilAmount: Float
    var tint: SIMD4<Float>
    var particleColor: SIMD4<Float>
    var fxOnly: Int32 = 0, wallMask: Int32 = 0, pad2: Int32 = 0, pad3: Int32 = 0
    var hinge: SIMD4<Float> = .zero
    var background: SIMD4<Float> = .zero
    var kf0: SIMD4<Float> = .zero, kf1: SIMD4<Float> = .zero, kf2: SIMD4<Float> = .zero
    var cornerBottom: Float = 0
}

/// What plays on the picture as the screen snaps back.
enum SnapAnimation: Int, CaseIterable {
    case none = 0, ripple, edgeGlow, frostedGlow, particleBurst, crtGlow, invertedGlow, hologramGlow
    /// Setting value: the animation that goes with the fold style.
    static let matchStyle = 8

    static func forStyle(_ style: Int) -> SnapAnimation {
        switch style {
        case 1: return .frostedGlow
        case 2: return .particleBurst
        case 3, 6: return .crtGlow
        case 4: return .invertedGlow
        case 5: return .hologramGlow
        default: return .edgeGlow
        }
    }

    var duration: CFTimeInterval {
        switch self {
        case .ripple, .particleBurst: return 0.9
        case .hologramGlow: return 0.7
        default: return 0.6
        }
    }

    var name: String { ["None", "Ripple", "Edge glow", "Frosted glow", "Particle burst", "CRT glow", "Inverted glow", "Hologram glow"][rawValue] }

    var detail: String {
        switch self {
        case .none: return "The screen simply snaps back."
        case .ripple: return "A wobbling ring leaves the middle of the screen."
        case .edgeGlow: return "A glowing stroke runs around the screen's edge as it snaps back."
        case .frostedGlow: return "The edge glows through frosted glass: bent, icy, with glints."
        case .particleBurst: return "The edge flashes, then breaks into glowing particles of the picture's colors that drift inward and fade."
        case .crtGlow: return "An old-TV edge glow: scanlines run through it, its colors split, and it flickers."
        case .invertedGlow: return "A black glow runs along the edge, and the picture's colors turn over under it, then fade back."
        case .hologramGlow: return "A flickering, interlaced edge glow with glitches, in the hologram's color (Effect Console)."
        }
    }

    /// Drawn in the Snap animation color (the hologram glow takes the hologram's; the inverted glow has none).
    var usesSnapColor: Bool { self != .none && self != .invertedGlow && self != .hologramGlow }
}

/// Hiding the pointer from a background app needs a private Window Server connection property,
/// "SetsCursorInBackground" (used by many utilities), resolved at runtime.
private enum PointerVisibility {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, UnsafeRawPointer, UnsafeRawPointer) -> Int32

    private static let allowed: Bool = {
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)          // RTLD_DEFAULT
        guard let mainSymbol = dlsym(anyImage, "CGSMainConnectionID"),
              let setSymbol = dlsym(anyImage, "CGSSetConnectionProperty") else { return false }
        let connection = unsafeBitCast(mainSymbol, to: MainConnectionFn.self)()
        let key = "SetsCursorInBackground" as CFString
        return withExtendedLifetime(key) {
            unsafeBitCast(setSymbol, to: SetPropertyFn.self)(connection, connection,
                                                            Unmanaged.passUnretained(key).toOpaque(),
                                                            Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque()) == 0
        }
    }()

    static func hide(on display: CGDirectDisplayID) -> Bool { allowed && CGDisplayHideCursor(display) == .success }
    static func show(on display: CGDirectDisplayID) { CGDisplayShowCursor(display) }
}

final class FoldOverlay: NSObject {
    let smoother = AngleSmoother()
    var onStateChange: ((EffectState) -> Void)?
    var onAngle: ((CGFloat) -> Void)?            // played angle, for the curve editor
    /// The screen just snapped back to normal after the lid reopened (argument: opening speed, °/s).
    var onSnap: ((CGFloat) -> Void)?
    /// The played angle crossed a notch (Hinge notches).
    var onNotch: (() -> Void)?
    private var lastNotch: CGFloat?              // index of the last notch felt (played angle / detentStep)
    var isTuning: () -> Bool = { false }         // curve editor open: never fade out on rest
    /// Maps a lid angle to the angle the tuning is written for (Adaptive angle); identity otherwise.
    var reference: (CGFloat) -> CGFloat = { $0 }
    /// The lid's own rotation since the fold began (real degrees) for a played angle of the tuning (exact
    /// perspective).
    var lidRotation: (CGFloat) -> CGFloat = { Settings.startAngle - $0 }
    /// Where the fold starts, in real lid degrees (Adaptive angle included): the plane the picture stays in.
    var lidStart: () -> CGFloat = { Settings.startAngle }
    /// The hinge axis, measured on film (MacBook Pro 16", 2026: the lid's pose in 2,695 frames, 1.2 px from a single
    /// fixed axis): the screen's bottom edge is 2.33 cm from it along the lid, and the screen's surface 0.68 cm
    /// behind it.
    private static let hingeCM = (along: CGFloat(2.33), out: CGFloat(-0.68))
    /// Points per centimetre on the built-in display (the hinge is measured in cm).
    // Screen scale for the hinge offsets. NUEM, TGTools123.
    private lazy var pointsPerCM: CGFloat = {
        let mm = CGDisplayScreenSize(screen.displayID).height
        return screen.frame.height / (mm > 0 ? mm / 10 : 22.3)
    }()
    private(set) var isVisible = false
    private var lastLid: CGFloat = 0                          // the smoothed lid angle (Keyframes mode plays real angles)
    /// On screen: the effect, or the black cover of an opening.
    var isBusy: Bool { isVisible || covering }
    /// The fold itself is on screen (not its snap animation, which plays over the real screen).
    var isFolding: Bool { covering || (isVisible && snapFX == nil && hiding == nil) }

    static func signature(of screen: NSScreen) -> String { "\(screen.displayID) \(screen.frame) \(screen.backingScaleFactor)" }

    private let curves: Curves
    private let screen: NSScreen
    private let window: NSWindow
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState?      // Particles style: instanced glowing sprites, added on
    private let snapParticlePipeline: MTLRenderPipelineState?  // Particle burst snap: sprites leaving the screen's edge
    private let sampler: MTLSamplerState
    private var snapFX: (kind: SnapAnimation, since: CFTimeInterval)?
    private let ciContext: CIContext
    private let pixelSize: CGSize

    // Snapshot
    private var capturing = false
    private var isArmed = false                  // snapshot ready
    private var armedAt: CFTimeInterval = 0
    private var lastFailure: CFTimeInterval = -.infinity
    private var generation = 0                   // bumped by stop(): late captures are dropped
    private var sharpTexture: MTLTexture?
    private var blurSet: BlurSet?

    // Display
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var shownAt: CFTimeInterval = 0
    private var hiddenAt: CFTimeInterval = 0
    private var entryOffset: CGFloat = 0
    private var playedAngle: CGFloat = 0
    private var deepestAngle: CGFloat = 0        // lowest played angle since the effect appeared
    private var hiding: (since: CFTimeInterval, duration: CFTimeInterval, angle: CGFloat, alpha: CGFloat)?
    private var restingAngle: CGFloat?           // faded out because the lid rested; dormant until it moves

    // Lock screen and opening from sleep (LockScreen.swift)
    private let lockScreenEnabled: Bool          // the window is raised above the lock screen
    private var locked = LockScreen.isLocked     // refreshed a few times per second, and on lock, unlock and wake
    private var lockCheckedAt: CFTimeInterval = 0
    private var snapshotLocked = false           // the snapshot shows the lock screen (it was taken while locked)
    private var covering = false                 // black cover up, waiting for the snapshot of an opening
    private var openedAt: CFTimeInterval?        // the effect was shown by an opening
    private var openingAllowedUntil: CFTimeInterval = 0   // shortly after a wake or the display appearing
    private var lastReadingAt: CFTimeInterval = 0
    private var refreshAt: CFTimeInterval?       // a kept snapshot is up: capture a fresh one from then on
    private var wakeAnchor: CGFloat?             // lid angle when it last stood still (turning the display on)
    private var wokeDisplayAt: CFTimeInterval = -.infinity   // NUEM turned the display on for a moving lid
    private var placementRetryAt: CFTimeInterval = 0         // an opening that couldn't be placed tries again then
    private var blackShown = false                           // the last frame drawn was black: no need for another
    private var revealAt: CFTimeInterval = -.infinity        // an opening's picture fades in from black from then
    private var displayWokeAt: CFTimeInterval = -.infinity   // the display last woke, locked
    private var lockScreenLitInARow = 3                      // lock screen captures in a row come out drawn since then
    private var snapHeldSince: CFTimeInterval?               // the snap waits for the lock screen to be drawn
    private var seeThroughAt: CFTimeInterval = 0             // the window last turned see-through (a snap animation)
    private var blackCaptures = 0                            // lock screen captures thrown away as black, this effect
    /// Frames of the effect on screen: how many, how many came late, the longest gap and the longest frame's work.
    private var frameStats: (frames: Int, late: Int, worstGap: CFTimeInterval, worstWork: CFTimeInterval) = (0, 0, 0, 0)
    /// Per fold: the longest each step took on the main thread, and the late frames whose own work was short (the
    /// time went elsewhere: the window server's transaction, the sensor timer…).
    private var worstSteps: [String: CFTimeInterval] = [:]
    private var lateElsewhere = 0
    private var lastWork: CFTimeInterval = 0

    @discardableResult
    private func timed<T>(_ step: String, _ work: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = work()
        let spent = CACurrentMediaTime() - start
        if spent > worstSteps[step] ?? 0 { worstSteps[step] = spent }
        return result
    }
    /// The effect's colors, read from the settings a few times a second rather than every frame.
    private var backgroundCache: (at: CFTimeInterval, color: SIMD3<Float>)?
    private func backgroundColor() -> SIMD3<Float> {
        let now = CACurrentMediaTime()
        if let cached = backgroundCache, now - cached.at < 0.25 { return cached.color }
        let color = Settings.color("backgroundColor")
        backgroundCache = (now, color)
        return color
    }
    private var styleColorsCache: (at: CFTimeInterval, hologram: SIMD3<Float>, snap: SIMD3<Float>, tint: SIMD3<Float>,
                                   particle: SIMD4<Float>, wallMask: Int32)?
    private var current: Snapshot?               // the snapshot being drawn
    // Clock veil: a lock screen captured more than 20 s ago shows an old time, so its clock stays frosted until the
    // effect ends (sticky, so a fresh capture doesn't un-blur it mid-animation).
    private var veilOn = false
    private var veilRect: CGRect?
    private var lastVeilRefresh: CFTimeInterval = 0
    private static let defaultClock = CGRect(x: 0.28, y: 0.05, width: 0.44, height: 0.28)   // top center, time + date

    // Mouse pointer: hidden during the effect and replaced by a copy that fades out ("Fade the pointer").
    private var pointerWindow: NSWindow?                 // the copy, while it's in use
    private lazy var pointerCopy: NSWindow = {
        let copy = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
        copy.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        copy.isOpaque = false
        copy.backgroundColor = .clear
        copy.hasShadow = false
        copy.ignoresMouseEvents = true
        copy.isReleasedWhenClosed = false
        copy.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        view.autoresizingMask = [.width, .height]
        copy.contentView = view
        return copy
    }()
    private var pointerHidden = false
    private var pointerHotSpot = CGPoint.zero

    init?(screen: NSScreen, curves: Curves) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.screen = screen
        self.curves = curves
        self.device = device
        self.queue = queue
        let scale = screen.backingScaleFactor
        pixelSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            let particles = MTLRenderPipelineDescriptor()
            particles.vertexFunction = library.makeFunction(name: "pvertex")
            particles.fragmentFunction = library.makeFunction(name: "pfragment")
            let target = particles.colorAttachments[0]!
            target.pixelFormat = .bgra8Unorm
            target.isBlendingEnabled = true                        // premultiplied: a particle covers, its glow adds light
            target.rgbBlendOperation = .add
            target.sourceRGBBlendFactor = .one
            target.destinationRGBBlendFactor = .oneMinusSourceAlpha
            target.sourceAlphaBlendFactor = .one                   // coverage too: over the real screen at the snap
            target.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            particlePipeline = try? device.makeRenderPipelineState(descriptor: particles)
            particles.vertexFunction = library.makeFunction(name: "svertex")
            snapParticlePipeline = try? device.makeRenderPipelineState(descriptor: particles)
        } catch {
            logger.error("Shader compilation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToZero; sd.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = sampler
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])

        // Highest window level: covers the menu bar and full-screen apps; ignores the mouse.
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        lockScreenEnabled = Settings.lockScreen
        super.init()

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = pixelSize
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = true    // image and window alpha land in the same transaction
        metalLayer.colorspace = screen.colorSpace?.cgColorSpace
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = metalLayer
        view.wantsLayer = true
        window.contentView = view

        if lockScreenEnabled { window.canBecomeVisibleWithoutLogin = true }   // moved above the lock screen when shown
        openingAllowedUntil = CACurrentMediaTime() + 8    // the display may have just appeared: the lid is opening
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // The display alone sleeps and wakes too (the Mac kept awake with the lid closed, or idle).
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        // A menu bar app is almost never frontmost: ask for these right away rather than on activation.
        distributed.addObserver(self, selector: #selector(lockChanged), name: LockScreen.lockedNotification, object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(lockChanged), name: LockScreen.unlockedNotification, object: nil,
                                suspensionBehavior: .deliverImmediately)
        if lockScreenEnabled && locked { LockScreenLight.setLocked(true) }   // created while locked (the display came back)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Sensor input

    /// Called with every sensor reading (degrees). Decides when to snapshot; the display link does the rest.
    func update(angle: CGFloat) {
        let now = CACurrentMediaTime()
        smoother.push(angle, at: now)
        lastReadingAt = now
        refreshLock(at: now)
        if locked && !lockScreenEnabled { return }       // the window would stay hidden behind the lock screen
        if locked { lightLockScreen(angle: angle, now: now) }
        if let refreshAt, now >= refreshAt { refreshKept(now: now) }
        // The clock veil fades into the real clock before the snap: one capture from this minute, taken as the lid
        // comes back up toward the start angle — not all along: each capture costs the animation a few frames.
        if veilOn, locked, isVisible, !capturing, refreshAt == nil, now - lastVeilRefresh > 5,
           smoother.velocity > 1, reference(angle) > Settings.startAngle - 30,
           let current, !current.showsCurrentMinute {
            lastVeilRefresh = now
            refreshAt = now                          // captured as soon as the display is on (refreshKept)
        }
        let start = Settings.startAngle, mapped = reference(angle)
        if let resting = restingAngle {
            guard abs(angle - resting) > 2 || mapped > start + 1 else { return }
            restingAngle = nil
        }
        if !isArmed && !capturing {
            // Snapshot only while closing, `captureLead` seconds before reaching startAngle at the current speed (a
            // slow close captures right at startAngle).
            let closing = -smoother.velocity
            let lead = max(0, closing) * Settings.captureLead
            if closing > 0.25, mapped < start + min(25, lead) {
                trace("decision: closing at \(Int(angle))° — get a picture", every: 1, key: "closing")
                armForClosing(now: now)
            } else if now < openingAllowedUntil, smoother.velocity > 1, mapped < start - 2, !isVisible {
                trace("decision: opening at \(Int(angle))°", every: 1, key: "opening")
                beginOpening()                       // opening from sleep or from a closed lid
            } else if locked, now - wokeDisplayAt < 3, mapped < start - 1, now - smoother.lastChangeAt < 1.5, !isVisible, !covering {
                trace("decision: lid moved while its display turned on, at \(Int(angle))°", every: 1, key: "woke")
                armForClosing(now: now)              // the lid stopped below the start while its display turned on
            }
        } else if isArmed && !isVisible && !covering, mapped > start + 20 || now - armedAt > 1.5 {
            disarm()                                 // stale: the next close takes a fresh snapshot
        }
        if (isArmed || capturing || covering) && displayLink == nil { startLink(now: now) }
    }

    /// Full stop (effect disabled, display change): hide and drop everything.
    func stop() {
        keepForReopening()                                   // the display is going away with the lid closed
        generation += 1
        if isVisible { finishHide("stopped (display change or effect off)") }
        if covering { uncover("stopped (display change or effect off)") }
        capturing = false
        disarm()
        restingAngle = nil
        stopLink()
        LockScreenLight.release()
    }

    // MARK: Snapshot

    /// Takes the snapshot and its blur set.
    private func arm() {
        let now = CACurrentMediaTime()
        guard !capturing, now - lastFailure > 3 else { return }
        guard CGDisplayIsAsleep(screen.displayID) == 0 else {          // can't be captured: tried again on a later reading
            trace("capture: not yet, the display is asleep", every: 1)
            return
        }
        let refreshing = isArmed                     // a kept snapshot is already up
        capturing = true
        if !refreshing {
            armedAt = now
            if !isVisible && !covering { onStateChange?(.capturing) }
        }
        let gen = generation, lockedAtStart = LockScreen.isLocked, underCover = covering || isVisible
        trace("capture: start — \(lockedAtStart ? "the lock screen" : underCover ? "under the window" : "the desktop")\(refreshing ? ", to replace the picture up" : "")")
        Task { [weak self] in
            guard let self else { return }
            do {
                // No display is listed while it sleeps (locked or not): the capture then fails and is retried.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == self.screen.displayID }) else {
                    throw CaptureError.displayNotListed
                }
                // Ours and the system's recording indicator ("StatusIndicator"), which the capture itself switches on
                // and would otherwise be frozen into the snapshot.
                let isOurs = { (w: SCWindow) in w.owningApplication?.processID == getpid() || w.title == "StatusIndicator" }
                let filter: SCContentFilter
                if lockedAtStart {
                    // The lock screen as it shows: every window but ours and the pointer, composited.
                    guard content.windows.contains(where: {
                        $0.owningApplication?.bundleIdentifier == "com.apple.loginwindow" && $0.windowLayer > 2000
                            && $0.frame.contains(display.frame)
                    }) else { throw CaptureError.displayNotListed }
                    filter = SCContentFilter(display: display, including: content.windows.filter { !isOurs($0) && $0.title != "Cursor" })
                } else if underCover {
                    // Our window is up (the black cover, or the effect itself): capture everything else by name,
                    // which works even if our window isn't listed.
                    filter = SCContentFilter(display: display, including: content.windows.filter { !isOurs($0) })
                } else {
                    filter = SCContentFilter(display: display, excludingWindows: content.windows.filter(isOurs))
                }
                let config = SCStreamConfiguration()
                config.width = Int(self.pixelSize.width)
                config.height = Int(self.pixelSize.height)
                config.showsCursor = false
                config.captureResolution = .best
                let t0 = CACurrentMediaTime()
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Just awake, the display may not have drawn the lock screen yet: a mostly dark capture is taken
                // again 0.2 s later, eight times at most (a truly dark lock screen is then accepted).
                let lit = lockedAtStart ? FoldOverlay.litFraction(image) : 1
                if lit < 0.15 {
                    let (tries, pictureUp) = await MainActor.run { () -> (Int, Bool) in
                        self.blackCaptures += 1
                        self.lockScreenLitInARow = 0
                        return (self.blackCaptures, self.isArmed)
                    }
                    trace("capture: the lock screen isn't drawn yet (\(Int(lit * 100)) % lit), try \(tries)")
                    // Tried again 0.2 s later, eight times.
                    if tries <= 8 { throw CaptureError.displayNotListed }
                    if pictureUp { throw CaptureError.stillDark }
                }
                let t1 = CACurrentMediaTime()
                trace("capture: taken in \(Int((t1 - t0) * 1000)) ms\(lockedAtStart ? ", \(Int(lit * 100)) % lit" : "")")
                let texture = try await MTKTextureLoader(device: self.device).newTexture(cgImage: image, options: [
                    .SRGB: false,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.private.rawValue])
                let blurs = self.makeBlurSet(CIImage(cgImage: image))
                logger.debug("capture \(Int((t1 - t0) * 1000)) ms, blurs \(Int((CACurrentMediaTime() - t1) * 1000)) ms")
                let snapshot = blurs.map { Snapshot(sharp: texture, blurs: $0, locked: lockedAtStart, takenAt: CACurrentMediaTime(),
                                                    signature: FoldOverlay.signature(of: self.screen)) }
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.capturing = false
                    guard let snapshot else { trace("capture: its blurs failed"); self.onStateChange?(.captureFailed); return }
                    // Locked or unlocked during the capture: the picture belongs to the other side. Drop it.
                    guard lockedAtStart == LockScreen.isLocked else { trace("capture: dropped, taken on the other side of the lock"); return }
                    if lockedAtStart { self.lockScreenLitInARow += 1 }
                    if lockedAtStart { SnapshotCache.store(snapshot) }
                    self.use(snapshot)
                }
                // Where the lock screen shows the time, for the clock veil — after the snapshot is in use (≈ 100 ms).
                if let snapshot, lockedAtStart, Settings.blurClock {
                    let clock = FoldOverlay.findClock(in: image)
                    await MainActor.run { snapshot.clock = clock }
                }
            } catch {
                // A display that's just turning on isn't listed yet: try again shortly. Anything else waits 3 s.
                let notListed = (error as? CaptureError) == .displayNotListed
                if notListed { trace("capture: no picture yet, again in 0.2 s") }
                else if (error as? CaptureError) == .stillDark { trace("capture: still dark — the picture up stays, again in 3 s") }
                else { logger.error("Capture failed: \(String(describing: error), privacy: .public)") }
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.capturing = false
                    self.lastFailure = CACurrentMediaTime() - (notListed ? 2.85 : 0)
                    if notListed, self.isArmed || self.covering { self.refreshAt = CACurrentMediaTime() + 0.2 }
                    if !refreshing { self.onStateChange?(CGPreflightScreenCaptureAccess() ? .captureFailed : .needsPermission) }
                }
            }
        }
    }

    /// The wallpaper matte, for colors set to the wallpaper's (Wallpaper.swift); read as an effect gets ready.
    private var wallpaper: MTLTexture?
    private var wallpaperMatte: CGImage?
    /// A white pixel, bound when no color uses the wallpaper.
    private lazy var fallbackTexture: MTLTexture = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let texture = device.makeTexture(descriptor: descriptor)!
        var white: UInt32 = 0xFFFF_FFFF
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        return texture
    }()

    /// Makes `snapshot` the one the effect draws (a fresh capture, or one kept for an opening).
    private func use(_ snapshot: Snapshot) {
        trace("picture: \(snapshot.locked ? "the lock screen" : "the desktop"), \(Int((CACurrentMediaTime() - snapshot.takenAt) * 1000)) ms old")
        blackCaptures = 0
        if Settings.wallpaperMask != 0, let matte = Wallpaper.matte {
            if matte !== wallpaperMatte { wallpaperMatte = matte; wallpaper = Wallpaper.texture(device: device) }
        } else {
            wallpaper = nil; wallpaperMatte = nil
        }
        current = snapshot
        sharpTexture = snapshot.sharp
        blurSet = snapshot.blurs
        snapshotLocked = snapshot.locked
        if !isArmed {
            isArmed = true
            if !isVisible && !covering { onStateChange?(.ready) }
        }
    }

    /// Arms for a close.
    private func armForClosing(now: CFTimeInterval) {
        guard locked, let kept = SnapshotCache.take(locked: true, signature: Self.signature(of: screen), now: now) else {
            trace("closing: \(locked ? "no lock screen kept" : "unlocked") — capture", every: 1, key: "armForClosing")
            arm()
            return
        }
        trace("closing: the kept lock screen")
        armedAt = now
        use(kept)                        // not captured again mid-fold: that costs the animation frames (the clock
                                         // is veiled if old; update() takes one capture near the end for its fade)
    }

    /// Captures the screen again for a kept snapshot (or an opening's black cover), once the display is on.
    private func refreshKept(now: CFTimeInterval) {
        guard isArmed || covering else { refreshAt = nil; return }
        guard !capturing else { return }
        if CGDisplayIsAsleep(screen.displayID) != 0 {
            trace("capture: waiting for the display to wake", every: 1)
            refreshAt = now + 0.25
            return
        }
        refreshAt = nil
        arm()
    }

    /// The lid is (nearly) closed and the Mac is going to sleep, or the built-in display is going away: keep the
    /// snapshot, so the opening can draw from its first frame.
    private func keepForReopening() {
        // The lid's own angle too: on a fast close the played angle, smoothed, is still behind.
        guard isVisible, min(playedAngle, reference(smoother.latest)) < Settings.minAngle + 10, let current else { return }
        SnapshotCache.store(current)
    }

    private func disarm() {
        guard !isVisible, isArmed else { return }
        isArmed = false
        sharpTexture = nil; blurSet = nil; current = nil; refreshAt = nil
        onStateChange?(.idle)
    }

    private func makeBlurSet(_ image: CIImage) -> BlurSet? {
        let heightPoints = screen.frame.height
        let scale = image.extent.height / heightPoints
        let maxBlur = Settings.maxBlur * heightPoints
        let radii: [CGFloat] = [0.125, 0.3, 0.6, 1.0].map { $0 * maxBlur }
        let downsample: [CGFloat] = [0.5, 0.5, 0.25, 0.25]            // blurred levels don't need full resolution
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let commands = queue.makeCommandBuffer() else { return nil }
        var textures: [MTLTexture] = [], margins: [CGFloat] = []
        for (radius, down) in zip(radii, downsample) {
            let margin = 3 * radius                                    // ~3σ: the bleed is complete
            let scaled = image.samplingLinear().transformed(by: CGAffineTransform(scaleX: down, y: down))
            let extent = scaled.extent.insetBy(dx: -margin * scale * down, dy: -margin * scale * down).integral
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = scaled                                   // not clamped: edges spread into black
            blur.radius = Float(radius * scale * down)
            guard let output = blur.outputImage else { return nil }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(extent.width),
                                                                height: Int(extent.height), mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            guard let texture = device.makeTexture(descriptor: desc) else { return nil }
            ciContext.render(output, to: texture, commandBuffer: commands, bounds: extent, colorSpace: colorSpace)
            textures.append(texture); margins.append(margin)
        }
        commands.commit()
        commands.waitUntilCompleted()
        return BlurSet(textures: textures, radii: radii, margins: margins)
    }

    // MARK: Display

    private func startLink(now: CFTimeInterval) {
        lastTick = now
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLink() { displayLink?.invalidate(); displayLink = nil }

    private func show(angle: CGFloat) {
        let now = CACurrentMediaTime()
        // 0.3 s anti-flicker after a hide (a lid hovering at the start angle) — not for a lid closing fast on purpose.
        guard isArmed, sharpTexture != nil, covering || now - hiddenAt > 0.3 || smoother.velocity < -15 else {
            trace("show: not now (armed \(isArmed), just hidden \(now - hiddenAt < 0.3))", every: 1, key: "show")
            return
        }
        // An opening is already on screen (the black cover): it starts at the lid's angle, without fading in.
        let opening = covering
        covering = false
        openedAt = opening ? now : nil
        revealAt = opening ? now : -.infinity                  // an opening fades in from its black cover
        isVisible = true
        frameStats = (0, 0, 0, 0)
        worstSteps = [:]
        lateElsewhere = 0
        shownAt = opening ? now - 1 : now
        hiding = nil
        deepestAngle = opening ? angle : Settings.startAngle
        entryOffset = opening ? 0 : max(0, Settings.startAngle - angle)
        if !opening { window.alphaValue = 0 }
        timed("first frame") { render(angle: opening ? angle : Settings.startAngle) }   // ready before the window appears
        guard timed("order in", { orderIn() }) else { finishHide("couldn't be placed on the built-in display"); return }
        logger.notice("Fold shown at \(Int(angle))°\(opening ? " (opening)" : "", privacy: .public)")
        if !locked { timed("pointer fade start") { beginPointerFade() } }   // the lock screen keeps its pointer
        timed("state change") { onStateChange?(.active) }
    }

    /// The lid is opening from sleep, or the built-in display just came back (a closed lid with an external display):
    /// cover the screen in black at once, capture what's under the cover, then unfold.
    private func beginOpening() {
        let now = CACurrentMediaTime()
        guard !isVisible, !covering, !capturing, now - lastFailure > 3, now >= placementRetryAt else {
            trace("opening: not now (visible \(isVisible), covering \(covering), capturing \(capturing), after a failure \(now - lastFailure <= 3))",
                  every: 1, key: "beginOpening")
            return
        }
        let allowedUntil = openingAllowedUntil
        covering = true
        openingAllowedUntil = 0                                // once per wake
        armedAt = now
        // A kept snapshot draws from the next frame (a fresh capture then replaces it); otherwise the cover stays
        // black until the capture arrives, as soon as the display is on.
        if let kept = SnapshotCache.take(locked: locked, signature: Self.signature(of: screen), now: now) {
            use(kept)
        }
        renderBlack()
        window.alphaValue = 1
        guard orderIn() else {
            // The built-in display may still be settling (it just came back): try again shortly.
            if let current { SnapshotCache.store(current) }
            uncover("the opening couldn't be placed yet")
            openingAllowedUntil = allowedUntil
            placementRetryAt = now + 0.25
            return
        }
        refreshAt = now
        refreshKept(now: now)
        logger.notice("Opening: black cover up, lid at \(Int(self.smoother.latest))°, \(self.current != nil ? "kept picture" : "waiting for a capture", privacy: .public)")
    }

    /// Locked by the lid closing, the fold at its black end: the window stays up, black, as the cover of the opening
    /// to come — the display then wakes to black, never to a flash of the lock screen — and the desktop picture is
    /// dropped.
    private func becomeCover(at now: CFTimeInterval) {
        trace("cover: the fold becomes the black cover of the coming opening (last frame black \(blackShown))")
        isVisible = false
        covering = true
        openedAt = nil; hiding = nil; snapFX = nil; lastNotch = nil
        isArmed = false; sharpTexture = nil; blurSet = nil; current = nil
        veilOn = false; veilRect = nil
        seeThrough(false)
        window.alphaValue = 1
        if !blackShown { renderBlack() }                       // black already, as a rule: render() near a shut lid
        armedAt = now
        refreshAt = now                                        // the lock screen, as soon as the display is on
        if let kept = SnapshotCache.take(locked: true, signature: Self.signature(of: screen), now: now) { use(kept) }
        logger.notice("Locked with the lid closed: the black cover stays up for the opening")
    }

    /// Orders the window in — above the lock screen if enabled — and makes sure it's exactly on the built-in display:
    /// moving it above the lock screen can shift it, and the effect must never show on another display.
    private func orderIn() -> Bool {
        window.orderFrontRegardless()
        raiseAboveLockScreen()                                 // ordering in can put it back in the user's space
        if isOnBuiltInDisplay() {
            trace("window: in, above the lock screen \(!lockScreenEnabled || LockScreen.isRaised(window))")
            return true
        }
        window.setFrame(screen.frame, display: false)
        raiseAboveLockScreen()
        if isOnBuiltInDisplay() { return true }
        logger.error("""
            The effect window couldn't be placed on the built-in display: not showing it (window \
            \(String(describing: self.windowBounds()), privacy: .public), display \
            \(String(describing: CGDisplayBounds(self.screen.displayID)), privacy: .public), screen \
            \(String(describing: self.screen.frame), privacy: .public))
            """)
        window.orderOut(nil)
        return false
    }

    /// Into the lock-screen space, top-left corner on the built-in display's.
    private func raiseAboveLockScreen() {
        guard lockScreenEnabled else { return }
        if !LockScreen.raise(window, at: CGDisplayBounds(screen.displayID).origin) {
            logger.info("The effect window didn't go above the lock screen yet; retrying while it shows")
        }
    }

    /// Where the window server has the window (global display coordinates, top-left origin).
    private func windowBounds() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              let dictionary = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    /// The window's bounds compared with the built-in display's: exactly on it — or, while the lock screen zooms in
    /// as it wakes (the window server then reports the windows above it about 2 % smaller, centered: seen on macOS
    /// 26.5), scaled around its center and inside it.
    private func isOnBuiltInDisplay() -> Bool {
        guard let bounds = windowBounds() else { return true }   // unknown: trust the frame
        let display = CGDisplayBounds(screen.displayID)
        if display.contains(bounds), bounds.width >= 0.9 * display.width,
           abs(bounds.midX - display.midX) < 1, abs(bounds.midY - display.midY) < 1 { return true }
        return abs(bounds.minX - display.minX) < 1 && abs(bounds.minY - display.minY) < 1
            && abs(bounds.width - display.width) < 1 && abs(bounds.height - display.height) < 1
    }

    /// Takes the cover of an opening down (the capture failed, or the lid is already open).
    private func uncover(_ reason: String) {
        trace("cover down: \(reason)")
        covering = false
        window.orderOut(nil)
        window.alphaValue = 0
        isArmed = false; sharpTexture = nil; blurSet = nil; current = nil
        veilOn = false; veilRect = nil; refreshAt = nil
        onStateChange?(.idle)
    }

    /// The snap: the real screen comes back — the window turns see-through (tick()) — and the snap animation plays on
    /// top of it, then the window goes.
    private func startSnapAnimation(_ kind: SnapAnimation, at now: CFTimeInterval) {
        trace("snap: \(kind.name)")
        snapFX = (kind, now)
        endPointerFade()                                       // the real pointer, over the real screen
    }

    /// Just after a wake on the lock screen, macOS takes a second or two to draw its wallpaper — black, then
    /// flickering between black and the picture (filmed on macOS 26.5).
    private func waitingForLockScreen(at now: CFTimeInterval) -> Bool {
        guard locked, lockScreenLitInARow < 3, now - displayWokeAt < 6 else { return false }
        if snapHeldSince == nil {
            snapHeldSince = now
            trace("snap: on our picture until the lock screen is drawn and steady")
        }
        guard now - snapHeldSince! < 3 else {
            trace("snap: the lock screen still isn't steady after 3 s — going on", every: 5, key: "steady")
            return false
        }
        if !capturing, refreshAt == nil { refreshAt = now + (lockScreenLitInARow > 0 ? 0.15 : 0) }
        return true
    }

    private func seeThrough(_ on: Bool) {
        if window.isOpaque == on { trace("window: \(on ? "see-through" : "opaque")") }
        if on, window.isOpaque { seeThroughAt = CACurrentMediaTime() }
        window.isOpaque = !on
        window.backgroundColor = on ? .clear : .black
        metalLayer.isOpaque = !on
    }

    /// Fades out before removing the window: ordering out a maximum-level window at once flashes black.
    private func beginHide(angle: CGFloat, duration: CFTimeInterval, _ reason: String) {
        trace("hiding over \(Int(duration * 1000)) ms: \(reason)")
        hiding = (CACurrentMediaTime(), duration, angle, window.alphaValue)
    }

    private func finishHide(_ reason: String) {
        trace("hidden: \(reason)\(isVisible ? "" : " (wasn't showing)")")
        if isVisible {
            let s = frameStats
            let steps = worstSteps.sorted { $0.value > $1.value }.prefix(6)
                .map { "\($0.key) \(String(format: "%.1f", $0.value * 1000))" }.joined(separator: ", ")
            logger.notice("""
                Fold hidden: \(s.frames) frames, \(s.late) late (over 12.5 ms; \(self.lateElsewhere) of them with little \
                work of NUEM's own), worst gap \(Int(s.worstGap * 1000)) ms, slowest frame work \
                \(String(format: "%.1f", s.worstWork * 1000), privacy: .public) ms — slowest steps (ms): \(steps, privacy: .public)
                """)
            if Settings.wallpaperMask != 0, !locked { Wallpaper.capture() }   // for the next effect, now it's over
        }
        hiding = nil
        snapFX = nil
        snapHeldSince = nil
        window.alphaValue = 0
        window.orderOut(nil)
        seeThrough(false)
        endPointerFade()
        isVisible = false
        covering = false
        openedAt = nil
        lastNotch = nil
        hiddenAt = CACurrentMediaTime()
        isArmed = false; sharpTexture = nil; blurSet = nil; current = nil
        veilOn = false; veilRect = nil; refreshAt = nil
        onStateChange?(.idle)
    }

    // Every frame of the fold (written by TGTools123).
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // Nothing to draw on a sleeping display (the lid closed, the Mac kept awake): asking for a drawable there
        // blocks up to a second, and the main thread with it — the sensor, the lock check, everything.
        guard CGDisplayIsAsleep(screen.displayID) == 0 else { lastTick = now; return }
        if isVisible, now - shownAt > 0.05 {                   // smoothness, logged when the fold hides
            let gap = now - lastTick
            frameStats.frames += 1
            if gap > 0.0125 {
                frameStats.late += 1
                if lastWork < 0.005 { lateElsewhere += 1 }
            }
            frameStats.worstGap = max(frameStats.worstGap, gap)
        }
        defer {
            lastWork = CACurrentMediaTime() - now
            if isVisible { frameStats.worstWork = max(frameStats.worstWork, lastWork) }
        }
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        let closing = Settings.motion(opening: false), opening = Settings.motion(opening: true)
        smoother.amount = closing.smoothing; smoother.lookAhead = closing.lookAhead; smoother.ahead = closing.ahead
        smoother.openAmount = opening.smoothing; smoother.openLookAhead = opening.lookAhead; smoother.openAhead = opening.ahead
        let lid = smoother.step(at: now, dt: dt)
        lastLid = lid
        let angle = reference(lid)
        let start = Settings.startAngle
        timed("lock check") { refreshLock(at: now) }

        if !isVisible {
            if isArmed, min(angle, reference(smoother.latest)) < start - 0.1 {
                timed("show") { show(angle: angle) }
            } else if covering, (isArmed && angle >= start) || (!isArmed && !capturing && refreshAt == nil) || now - armedAt > 3 {
                uncover(isArmed && angle >= start ? "the lid is already open"         // the lid is already open,
                        : now - armedAt > 3 ? "no picture within 3 s" : "no picture (capture failed)")   // or no picture
            }
            guard isVisible else {
                if !isArmed && !capturing && !covering { stopLink() }
                return
            }
        }
        // A snapshot from the other side of the lock (the desktop, taken before the Mac locked) is never shown: a
        // kept one from this side takes over, or render() draws black; the screen is captured again.
        if locked != snapshotLocked {
            trace("picture from the other side of the lock: black until one from this side", every: 1, key: "otherSide")
            if let kept = SnapshotCache.take(locked: locked, signature: Self.signature(of: screen), now: now) { use(kept) }
            if !capturing { arm() }
        }
        if snapFX != nil, angle < start - 2 {
            // The lid closing again during the animation: straight back to the fold, from the picture still up —
            // leaving it to the end showed the real screen while the lid went down.
            trace("snap animation cut short: the lid is closing again")
            snapFX = nil
            seeThrough(false)
            window.alphaValue = 1
            deepestAngle = start
            shownAt = now - 1                                  // on screen already: no fade-in, no catching up
            entryOffset = 0
            openedAt = nil
        }
        if let fx = snapFX {
            // The animation over our flat picture while the real lock screen isn't steady yet, then over the real
            // screen — the window turns see-through (for good: the real screen doesn't go back to our picture).
            let waiting = window.isOpaque && waitingForLockScreen(at: now)
            if !waiting, window.isOpaque { seeThrough(true) }
            let fade = 0.08, fadeFrom = max(fx.since + fx.kind.duration, seeThroughAt + 0.04)
            render(angle: start)
            window.alphaValue = waiting || now < fadeFrom ? 1 : max(0, 1 - (now - fadeFrom) / fade)
            movePointer(alpha: 1)
            if !waiting, now >= fadeFrom + fade { finishHide("snap animation over") }
            return
        }
        if let h = hiding {
            let k = 1 - smoothstep((now - h.since) / h.duration)
            render(angle: h.angle)
            window.alphaValue = h.alpha * k
            movePointer(alpha: 1)                          // the pointer comes back with the desktop
            if k <= 0 { finishHide("faded out") }
            return
        }
        if angle < start { snapHeldSince = nil }
        if angle >= start + 0.3, now - shownAt > 0.3 {
            // The screen is back to normal: this is the snap.
            let realFold = start - deepestAngle >= Settings.snapMinDepth
            if snapHeldSince == nil, realFold { onSnap?(max(0, smoother.velocity)) }
            let kind = Settings.snapAnimationKind
            if kind != .none, realFold {
                startSnapAnimation(kind, at: now)                      // with the click, whatever the lock screen does
            } else if waitingForLockScreen(at: now) {
                render(angle: start)                                   // the flat picture, just like the screen
                window.alphaValue = 1
            } else {
                beginHide(angle: start, duration: 0.05, "snap, no animation")   // back to identity: the swap is invisible
            }
            return
        }
        // Never keep the lock screen covered without sensor readings to follow.
        if locked, now - lastReadingAt > 3 {
            beginHide(angle: playedAngle, duration: 0.25, "no sensor reading for 3 s on the lock screen")
            return
        }
        // An opening that stops below the start angle gives the real screen back after 3 s.
        if let openedAt, !isTuning(), now - max(openedAt, smoother.lastChangeAt) > 3 {
            restingAngle = smoother.latest
            beginHide(angle: playedAngle, duration: 0.25, "an opening stopped below the start angle for 3 s")
            return
        }
        // Lid parked just below startAngle (someone working at that angle): give the desktop back.
        let restTimeout = Settings.adaptiveAngle ? 0 : Settings.restTimeout     // Adaptive angle handles a resting lid
        if restTimeout > 0, !isTuning(), playedAngle > start - 15, now - max(shownAt, smoother.lastChangeAt) > restTimeout {
            restingAngle = smoother.latest
            beginHide(angle: playedAngle, duration: 0.25, "the lid rested near the start angle")
            return
        }

        // Played angle = measured angle.
        let entry = entryOffset > 1 ? smoothstep((now - shownAt) / Settings.entryTime) : 1
        playedAngle = min(start, angle + (start - angle) * (1 - entry))
        deepestAngle = min(deepestAngle, playedAngle)
        timed("notches") { feelNotches() }
        timed("render") { render(angle: playedAngle) }         // fades to black by itself (edge-on, below minAngle)
        let fadeIn = smoothstep((now - shownAt) / 0.06)        // fade while the geometry is still identity
        // A see-through window shows the real desktop, which lights the screen up again over the keyboard: below 30°
        // the window stays opaque, whatever the overall-opacity curve says.
        let opacity = lid < 30 ? 1 : curves.overlay.value(at: playedAngle)
        timed("window alpha") {
            let alpha = fadeIn * opacity
            if window.alphaValue != alpha { window.alphaValue = alpha }   // a window server call: only when it changes
        }
        timed("pointer") {
            if pointerWindow == nil, !locked, screen.frame.contains(NSEvent.mouseLocation) { beginPointerFade() }   // back on it
            movePointer(alpha: curves.cursor.value(at: playedAngle))
        }
    }

    /// Hinge notches: a click each time the played angle — what's on screen — crosses a multiple of `detentStep`.
    private func feelNotches() {
        guard Settings.detents, let onNotch else { lastNotch = nil; return }
        let step = Settings.detentStep
        let index = (playedAngle / step).rounded(.down)
        guard let last = lastNotch else { lastNotch = index; return }
        guard index != last, abs(playedAngle - max(index, last) * step) > 0.3 else { return }
        lastNotch = index
        onNotch()
    }

    // MARK: Lock screen and sleep

    private func refreshLock(at now: CFTimeInterval) {
        guard now - lockCheckedAt > 0.2 else { return }
        lockCheckedAt = now
        setLocked(LockScreen.isLocked)
        // Self-repair: if the window server put the window back in the user's space (behind the lock screen), move it
        // again — within 0.2 s.
        if lockScreenEnabled, locked, isVisible || covering, !LockScreen.isRaised(window) { raiseAboveLockScreen() }
    }

    /// The lock screen turns the display off 5 s after the last input.
    private func lightLockScreen(angle: CGFloat, now: CFTimeInterval) {
        let moved = abs(angle - (wakeAnchor ?? angle)) > 2
        if moved || smoother.velocity == 0 { wakeAnchor = angle }      // movement counts from where the lid stood
        if moved {
            if CGDisplayIsAsleep(screen.displayID) != 0 {
                wokeDisplayAt = now
                LockScreenLight.wake()
            }
            LockScreenLight.keepOn(for: max(5, Settings.lockScreenAwake))
        }
        if isVisible || covering || isArmed { LockScreenLight.keepOn(for: 5) }
    }

    private func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        trace("""
            \(value ? "locked" : "unlocked") — showing \(isVisible), covering \(covering), picture \(isArmed), \
            lid \(Int(smoother.latest))°, display asleep \(CGDisplayIsAsleep(screen.displayID) != 0)
            """)
        if lockScreenEnabled, UserDefaults.standard.bool(forKey: "effectEnabled") {
            LockScreenLight.setLocked(locked)
            if locked { LockScreenLight.keepOn(for: Settings.lockScreenAwake) }   // on long enough to try the fold
        }
        if locked { endPointerFade() }                         // never hide the pointer on the lock screen
        // Locked by the lid closing, the fold already black: the window stays up as the cover of the opening to come.
        if locked, isVisible, min(playedAngle, reference(smoother.latest)) < Settings.minAngle + 10 {
            becomeCover(at: CACurrentMediaTime())
            return
        }
        if locked, lockScreenEnabled, isVisible || covering, !LockScreen.isRaised(window) { raiseAboveLockScreen() }
        // Until a snapshot from this side of the lock — not in a snap animation just unlocked: render() goes on there
        // with the lock screen's picture, as black would flash over the desktop (filmed).
        if isVisible || covering, locked || snapFX == nil { renderBlack() }
    }

    @objc private func lockChanged() {
        trace("lock notification")
        lockCheckedAt = CACurrentMediaTime()
        setLocked(LockScreen.isLocked)
        guard locked else { return }
        // Take the lock screen just after it appears, while the display is on: an opening on the lock screen can then
        // draw from its first frame, even after sleep (a display that sleeps can't be captured).
        guard lockScreenEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.locked, !self.isVisible, !self.covering, !self.isArmed, !self.capturing,
                  CGDisplayIsAsleep(self.screen.displayID) == 0 else { return }
            self.arm()
        }
    }

    /// Before sleep the snapshot is kept for the opening and the screen goes black: whatever happens while asleep (a
    /// lock), the first frame on waking can't be a stale picture.
    @objc private func willSleep(_ note: Notification) {
        trace("\(note.name == NSWorkspace.willSleepNotification ? "Mac going to sleep" : "display asleep") — showing \(isVisible), covering \(covering)")
        keepForReopening()
        if isVisible || covering { renderBlack() }
    }

    @objc private func didWake(_ note: Notification) {
        trace("\(note.name == NSWorkspace.didWakeNotification ? "Mac awake" : "display awake") — showing \(isVisible), covering \(covering), lid \(Int(smoother.latest))°")
        let now = CACurrentMediaTime()
        lockCheckedAt = 0
        refreshLock(at: now)
        lastReadingAt = now
        openingAllowedUntil = now + 8
        // Shown when the lid closed: this is an opening now (not when NUEM turned the display on mid-close).
        if isVisible, now - wokeDisplayAt > 3 { openedAt = now }
        if covering {                                          // the cover left up at a lock: its opening starts now
            armedAt = now
            if refreshAt == nil { refreshAt = now }
        }
        if locked {                                            // its lock screen may take a moment to be drawn
            displayWokeAt = now
            lockScreenLitInARow = 0
        }
        logger.notice("Display awake, lid at \(Int(self.smoother.latest))°")
        if displayLink != nil { stopLink(); startLink(now: now) }   // the link may not survive sleep
    }

    /// The clock veil for this frame: where, as (x0, y0, x1, y1) of the snapshot (all zero when off), and how much of
    /// it shows.
    private func clockVeil(angle: CGFloat) -> (rect: SIMD4<Float>, amount: Float) {
        guard Settings.blurClock, let current, current.locked else { return (.zero, 0) }
        if !veilOn, Settings.forceClockBlur || !current.showsCurrentMinute { veilOn = true }
        guard veilOn else { return (.zero, 0) }
        if let clock = current.clock { veilRect = veilRect.map { $0.union(clock) } ?? clock }
        let rect = veilRect ?? Self.defaultClock
        let amount = current.showsCurrentMinute ? clamp01((Settings.startAngle - angle) / 5) : 1
        return (SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY)), Float(amount))
    }

    /// Where the lock screen shows the time — and the date next to it — normalized with a top-left origin; nil if
    /// Vision reads no time in the upper half.
    static func findClock(in image: CGImage) -> CGRect? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let boxes: [(text: String, rect: CGRect)] = (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox                     // bottom-left origin
            return (text, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        guard let time = boxes.first(where: {
            $0.rect.minY < 0.5 && $0.text.range(of: #"^\d{1,2}[:.]\d{2}"#, options: .regularExpression) != nil
        })?.rect else { return nil }
        var clock = time
        for box in boxes where abs(box.rect.midX - time.midX) < 0.15
            && (abs(box.rect.maxY - time.minY) < time.height || abs(box.rect.minY - time.maxY) < time.height) {
            clock = clock.union(box.rect)                       // the date, just above or below the time
        }
        return clock.insetBy(dx: -0.02, dy: -0.02)
    }

    /// Clears the screen to black; needs no snapshot.
    private func renderBlack() {
        guard CGDisplayIsAsleep(screen.displayID) == 0,                  // see tick()
              let drawable = metalLayer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
        blackShown = true
        renderNote("black (cleared)")
    }

    /// A lock screen the display hadn't finished drawing (just awake): the clock and the account already lit, the
    /// wallpaper still black — fewer than 15 % of 32 × 32 samples above a dim level.
    private static func litFraction(_ image: CGImage) -> Double {
        let size = 32
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return 1 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return 1 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var lit = 0
        for i in 0..<(size * size) where max(bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2]) > 28 { lit += 1 }
        return Double(lit) / Double(size * size)
    }

    // MARK: Mouse pointer

    /// The real pointer is drawn above every window, so it would stay sharp on top of the fold.
    private func beginPointerFade() {
        guard Settings.cursorFade, pointerWindow == nil, !locked, screen.frame.contains(NSEvent.mouseLocation) else { return }
        let cursor = NSCursor.currentSystem ?? .arrow
        pointerHotSpot = cursor.hotSpot
        let copy = pointerCopy                                 // made once: making a window costs a fold's first frames
        copy.setContentSize(cursor.image.size)
        (copy.contentView as? NSImageView)?.image = cursor.image
        pointerHidden = PointerVisibility.hide(on: screen.displayID)
        if pointerHidden {
            pointerWindow = copy
            movePointer(alpha: 1)
        } else {
            logger.info("The pointer can't be hidden from the background here; it stays visible")
        }
    }

    private func movePointer(alpha: CGFloat) {
        guard let copy = pointerWindow else { return }
        guard screen.frame.contains(NSEvent.mouseLocation) else { endPointerFade(); return }   // left the built-in display
        if alpha <= 0.001 {
            if copy.isVisible { copy.orderOut(nil) }
            return
        }
        let mouse = NSEvent.mouseLocation
        copy.setFrameOrigin(NSPoint(x: mouse.x - pointerHotSpot.x, y: mouse.y - (copy.frame.height - pointerHotSpot.y)))
        copy.alphaValue = alpha
        if !copy.isVisible {
            copy.orderFrontRegardless()
            if lockScreenEnabled {                             // same space as the effect window, or it'd be under it
                let top = NSScreen.screens.first?.frame.maxY ?? copy.frame.maxY
                LockScreen.raise(copy, at: CGPoint(x: copy.frame.minX, y: top - copy.frame.maxY))
            }
        }
    }

    private func endPointerFade() {
        pointerWindow?.orderOut(nil)
        pointerWindow = nil
        if pointerHidden {
            PointerVisibility.show(on: screen.displayID)
            pointerHidden = false
        }
    }

    // MARK: Rendering

    /// Draws one frame for the given played angle.
    // TGTools123 · the picture for one frame.
    private func render(angle: CGFloat) {
        guard CGDisplayIsAsleep(screen.displayID) == 0 else { renderNote("none: the display is asleep"); return }   // see tick()
        onAngle?(angle)
        // Privacy (see tick()) — except the lock screen's own picture during a snap animation just unlocked: black
        // over the desktop flashed there (filmed); a desktop picture replaces it within 0.1 s.
        guard snapshotLocked == locked || (snapFX != nil && snapshotLocked) else {
            renderNote("black: the picture is from the other side of the lock")
            renderBlack()
            return
        }
        let size = screen.frame.size
        let p = Formula.progress(angle)
        // Exact perspective: the picture stays exactly where the screen was when the fold began, seen from a fixed
        // eye — turned by just the lid's own rotation since then, with no crop or stretch.
        let exact = Settings.exactPerspective
        // Keyframes mode (Keyframes.swift): the picture's shape from the keyframes, and nothing else: no perspective,
        // crop, stretch, blur, vignette, darkening or style.
        let keyframing = KeyframeStore.shared.isOn
        var kf = [SIMD4<Float>](repeating: .zero, count: 3)
        if keyframing {
            let m = KeyframeStore.shared.quad(at: Double(lastLid), start: Double(lidStart())).screenToPicture(size: size)
            for r in 0..<3 { kf[r] = SIMD4(Float(m[0][r]), Float(m[1][r]), Float(m[2][r]), r == 0 ? 1 : 0) }
        }
        var phi = exact ? max(0, lidRotation(angle)) * .pi / 180 : p * .pi / 2 * curves.strength.value(at: angle)
        if Settings.flipPerspective { phi = -phi }
        var D = max(0.5, curves.eyeDistance.value(at: angle)) * size.height
        var ey = curves.eyeHeight.value(at: angle) * size.height
        var hinge = SIMD4<Float>(repeating: 0)
        let lift = exact ? 0 : curves.lift.value(at: angle)      // Lift, cm below the screen's bottom edge (< 0: above)
        if exact {
            // Your eye stays put in the room, not with the lid: Eye height is taken straight up from the hinge axis
            // and Eye distance in front of it, along the keyboard.
            let s = lidStart() * .pi / 180, h = Settings.eyeHeight * size.height, d = Settings.eyeDistance * size.height
            let b = Self.hingeCM.along * pointsPerCM, c = Self.hingeCM.out * pointsPerCM
            ey = d * cos(s) + h * sin(s)
            D = max(0.5 * size.height, d * sin(s) - h * cos(s) - c)
            hinge = SIMD4(Float(b), Float(c), Float(ey), 1)
        } else if lift != 0 {
            // Lift: the classic fold turns about a point this far below the screen's bottom edge, as the real hinge
            // does (2.3 cm below it, 0.7 cm behind the glass), so the picture rises as the lid folds; negative, the
            // point is up the screen and the picture sinks.
            let b = lift * pointsPerCM, c = Self.hingeCM.out * min(1, max(0, lift / Self.hingeCM.along)) * pointsPerCM
            hinge = SIMD4(Float(b), Float(c), Float(ey + b), 0)
        }
        let A = D * cos(phi) - ey * sin(phi)
        let degenerate = A <= 0.05 * D || abs(phi) > 80 * .pi / 180
        let edgeOn: CGFloat = degenerate ? 0 : clamp01((A / D - 0.05) / 0.25)
        // Black below minAngle, edge-on — and whatever the played angle, once the lid itself is almost shut: the last
        // frame before the display turns off is black, so a lock then can't leave the desktop on it for the wake.
        let reveal = smoothstep((CACurrentMediaTime() - revealAt) / 0.35)   // an opening: from black, not at once
        let brightness = smoother.latest < 6 ? 0 : (keyframing ? 1 : edgeOn) * smoothstep((angle - Settings.minAngle) / 5) * reveal
        // Black again with the last frame already black: draw nothing.
        if snapFX == nil, brightness <= 0, blackShown { renderNote("none: black already"); return }
        // Fold style, driven by the same progress as everything else: glass fades in over the first 60 %; the others
        // run from the start angle to minAngle, where the screen goes black as they end (the last particles, the CRT
        // dot, the last of the hologram).
        let style = keyframing ? 0 : Settings.foldStyle
        let blackAt = max(0.2, 1 - Settings.minAngle / Settings.startAngle)
        let styleAmount: CGFloat = style == 0 ? 0 : style == 1 ? smoothstep(p / 0.6) : clamp01(p / blackAt)
        let fx: (kind: SnapAnimation, time: CGFloat) = snapFX.map {
            ($0.kind, clamp01(CGFloat((CACurrentMediaTime() - $0.since) / $0.kind.duration)))
        } ?? (.none, 0)

        guard let sharp = sharpTexture, let blurs = blurSet, let drawable = timed("next drawable", { metalLayer.nextDrawable() }),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        // The snap animation alone, over the real screen — 40 ms after the window turned see-through: until the
        // window server has made it so, a cleared frame would show black (seen over the lock screen).
        let fxOnly = snapFX != nil && !window.isOpaque && CACurrentMediaTime() - seeThroughAt > 0.04
        pass.colorAttachments[0].loadAction = fxOnly ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let veil = clockVeil(angle: angle)
        let nowColors = CACurrentMediaTime()
        if styleColorsCache.map({ nowColors - $0.at > 0.25 }) ?? true {
            styleColorsCache = (nowColors, Settings.color("hologramColor"), Settings.snapAnimationColor, Settings.color("blurTintColor"),
                                Settings.particleColorOn ? SIMD4(Settings.color("particleColor"), 1) : .zero, Int32(Settings.wallpaperMask))
        }
        let colors = styleColorsCache!
        var uniforms = Uniforms(
            radii: SIMD4(blurs.radii.map(Float.init)), margins: SIMD4(blurs.margins.map(Float.init)),
            size: SIMD2(Float(size.width), Float(size.height)), scale: Float(screen.backingScaleFactor), D: Float(D),
            A: Float(A), sinPhi: Float(sin(phi)), s: Float(smoothstep(p)), rMax: Float(blurs.radii.last ?? 1),
            levels: Int32(blurs.textures.count), black: degenerate && !keyframing ? 1 : 0,
            bottom: exact || keyframing ? 0 : Float(min(0.9, max(0, curves.bottom.value(at: angle)))),
            top: exact || keyframing ? 0 : Float(min(0.95, max(0, curves.top.value(at: angle)))),
            crop: exact || keyframing ? 0 : Float(max(-0.5, curves.crop.value(at: angle))),
            vignette: keyframing ? 0 : Float(Settings.vignetteIntensity * curves.vignetteOpacity.value(at: angle)),
            vignetteReach: Float(curves.vignette.value(at: angle)), vignetteEdge: Float(Settings.vignetteEdge),
            blurReach: keyframing ? 0 : Float(curves.blur.value(at: angle)), blurBottom: Float(Settings.blurBottom),
            grainy: Float(curves.grainy.value(at: angle)), blurScale: keyframing ? 0 : Float(curves.blurAmount.value(at: angle)),
            darkScale: keyframing ? 0 : Float(curves.dark.value(at: angle)), brightness: Float(brightness),
            veil: veil.rect,
            style: Int32(style), fx: Int32(fx.kind.rawValue), styleAmount: Float(styleAmount), fxTime: Float(fx.time),
            glassStrength: Float(Settings.glassStrength), particleSize: Float(Settings.particleSize),
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)), corner: Float(Settings.snapCorners.top),
            holoColor: SIMD4(colors.hologram, 1),
            fxColor: SIMD4(colors.snap, Float(Settings.snapOpacity)),
            particleGlow: Float(Settings.particleGlow), crtScan: Float(Settings.crtScanSize),
            crtScanlines: Float(Settings.crtScanlines), crtGlow: Float(Settings.crtGlow),
            crtSaturation: Float(Settings.crtSaturation), crtMask: Float(Settings.crtMask), crtCurve: Float(Settings.crtCurve),
            veilAmount: fxOnly ? 0 : veil.amount,
            tint: SIMD4(colors.tint, Float(Settings.blurTint)),
            particleColor: colors.particle,
            fxOnly: fxOnly ? 1 : 0, wallMask: colors.wallMask, hinge: keyframing ? .zero : hinge, background: SIMD4(backgroundColor(), 1),
            kf0: kf[0], kf1: kf[1], kf2: kf[2], cornerBottom: Float(Settings.snapCorners.bottom))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(sharp, index: 0)
        encoder.setFragmentTextures(blurs.textures, range: 1..<(1 + blurs.textures.count))
        encoder.setFragmentTexture(wallpaper ?? fallbackTexture, index: 5)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if style == 2, styleAmount > 0, !degenerate, let particlePipeline {
            let cell = Settings.particleSize
            let count = Int(ceil(size.width / cell) * ceil(size.height / cell))
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexTexture(blurs.textures[0], index: 0)      // lightly blurred: each cell's color
            encoder.setVertexTexture(wallpaper ?? fallbackTexture, index: 1)
            encoder.setVertexSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        if fx.kind == .particleBurst, !degenerate, let snapParticlePipeline {
            let count = Int((2 * (size.width + size.height) / 5).rounded(.down))   // one every 5 pt of the edge (svertex)
            encoder.setRenderPipelineState(snapParticlePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexTexture(blurs.textures[0], index: 0)
            encoder.setVertexTexture(wallpaper ?? fallbackTexture, index: 1)
            encoder.setVertexSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        encoder.endEncoding()
        commands.addCompletedHandler { buffer in
            if let error = buffer.error { logger.error("Frame failed on the GPU: \(String(describing: error), privacy: .public)") }
        }
        timed("submit") {
            commands.commit()
            commands.waitUntilScheduled()
        }
        timed("present") { drawable.present() }
        blackShown = brightness <= 0 && !fxOnly
        renderNote(fxOnly ? "the snap animation alone, over the screen"
                   : brightness <= 0 ? "black (edge-on or below the minimum angle)"
                   : reveal < 1 ? "the picture, fading in" : "the picture")
    }

    /// Diagnostics: what the frames show, logged when it changes.
    private var renderState = ""
    private func renderNote(_ state: String) {
        guard state != renderState else { return }
        renderState = state
        trace("frames: \(state)")
    }
}
