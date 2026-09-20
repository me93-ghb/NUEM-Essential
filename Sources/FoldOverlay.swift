// Copyright © 2026 TGTools123. NUEM, GNU GPL v3.
// Modified 2026-09-20 for NUEM-Essential: desktop-only classic fold, no snapshot cache.
import Cocoa
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import ScreenCaptureKit
import os

let logger = Logger(subsystem: "io.github.me93-ghb.nuem-essential", category: "effect")

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0 }
    var isBuiltin: Bool { CGDisplayIsBuiltin(displayID) != 0 }
}

enum Session {
    static var isUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }
}

private struct BlurSet {
    let textures: [MTLTexture]
    let radii: [CGFloat]
    let margins: [CGFloat]
}

struct Uniforms {
    var radii: SIMD4<Float>, margins: SIMD4<Float>
    var size: SIMD2<Float>, scale: Float, D: Float
    var A: Float, sinPhi: Float, s: Float, rMax: Float
    var levels: Int32, black: Int32, bottom: Float, top: Float
    var crop: Float, vignette: Float, vignetteReach: Float, vignetteEdge: Float
    var blurReach: Float, blurBottom: Float, grainy: Float, blurScale: Float
    var darkScale: Float, brightness: Float
    var hinge: SIMD4<Float>
}

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

@MainActor
final class FoldOverlay: NSObject {
    let screen: NSScreen
    let smoother = AngleSmoother()
    private let curves = Curves()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let ciContext: CIContext
    private let window: NSWindow
    private let metalLayer = CAMetalLayer()
    private let pixelSize: CGSize
    private var displayLink: CADisplayLink?
    private var sharpTexture: MTLTexture?
    private var blurSet: BlurSet?
    private var capturing = false
    private var generation = 0
    private var capturedAt: CFTimeInterval = 0
    private var lastFailure: CFTimeInterval = -.infinity
    private var shownAt: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var lastReading: CFTimeInterval = 0
    private var entryOffset: CGFloat = 0
    private var openedAt: CFTimeInterval?
    private var restingAngle: CGFloat?
    private var isVisible = false
    var reference: (CGFloat) -> CGFloat = { $0 }
    var onStateChange: (String) -> Void = { _ in }
    var isBusy: Bool { isVisible || capturing }

    private var pointerWindow: NSWindow?
    private var pointerHidden = false
    private var pointerHotSpot = CGPoint.zero
    private lazy var pointerCopy: NSWindow = {
        let copy = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
        copy.level = window.level
        copy.isOpaque = false
        copy.backgroundColor = .clear
        copy.hasShadow = false
        copy.ignoresMouseEvents = true
        copy.isReleasedWhenClosed = false
        copy.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSImageView(frame: copy.frame)
        view.autoresizingMask = [.width, .height]
        copy.contentView = view
        return copy
    }()

    init?(screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.screen = screen
        self.device = device
        self.queue = queue
        pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vmain")
            descriptor.fragmentFunction = library.makeFunction(name: "fmain")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            logger.error("Shader compilation failed: \(error.localizedDescription)")
            return nil
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToZero; descriptor.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { return nil }
        self.sampler = sampler
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.drawableSize = pixelSize
        metalLayer.displaySyncEnabled = true
        metalLayer.presentsWithTransaction = true
        metalLayer.colorspace = screen.colorSpace?.cgColorSpace
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = metalLayer
        view.wantsLayer = true
        window.contentView = view
        super.init()
    }

    func update(angle: CGFloat) {
        let now = CACurrentMediaTime()
        smoother.push(angle, at: now)
        lastReading = now
        guard Session.isUnlocked, CGDisplayIsAsleep(screen.displayID) == 0 else { stop(); return }
        if let resting = restingAngle {
            guard abs(angle - resting) > 2 || reference(angle) > Settings.startAngle + 1 else { return }
            restingAngle = nil
        }
        if sharpTexture != nil, !isVisible, now - capturedAt > 1.5 { stop() }
        let mapped = reference(angle)
        let lead = min(25, max(0, -smoother.velocity) * 0.12)
        if sharpTexture == nil, !capturing, now - lastFailure > 3,
           abs(smoother.velocity) > 0.25, mapped < Settings.startAngle + lead {
            capture()
        }
    }

    func stop() {
        guard capturing || isVisible || sharpTexture != nil || displayLink != nil || pointerHidden else { return }
        generation += 1
        displayLink?.invalidate(); displayLink = nil
        window.orderOut(nil)
        window.alphaValue = 0
        endPointerFade()
        sharpTexture = nil; blurSet = nil
        capturing = false; isVisible = false; openedAt = nil
        onStateChange("Idle")
    }

    private func capture() {
        guard CGPreflightScreenCaptureAccess() else {
            lastFailure = CACurrentMediaTime()
            onStateChange("Needs Screen Recording permission")
            return
        }
        capturing = true
        let token = generation
        onStateChange("Capturing…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard token == generation, Session.isUnlocked,
                      let display = content.displays.first(where: { $0.displayID == self.screen.displayID }) else {
                    if token == generation { stop() }
                    return
                }
                let excluded = content.windows.filter { $0.owningApplication?.processID == getpid() || $0.title == "StatusIndicator" }
                let config = SCStreamConfiguration()
                config.width = Int(pixelSize.width); config.height = Int(pixelSize.height)
                config.showsCursor = false
                config.capturesAudio = false
                config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config)
                guard token == generation, Session.isUnlocked else {
                    if token == generation { stop() }
                    return
                }
                let texture = try await MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue])
                guard token == generation else { return }
                guard let blurs = makeBlurSet(CIImage(cgImage: image)), Session.isUnlocked else { stop(); return }
                sharpTexture = texture; blurSet = blurs
                capturing = false
                capturedAt = CACurrentMediaTime()
                lastTick = capturedAt
                let link = screen.displayLink(target: self, selector: #selector(tick))
                let rate = Float(max(1, screen.maximumFramesPerSecond))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
                link.add(to: .main, forMode: .common)
                displayLink = link
                onStateChange("Ready")
            } catch {
                guard token == generation else { return }
                stop()
                lastFailure = CACurrentMediaTime()
                onStateChange("Capture failed")
                logger.error("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard Session.isUnlocked, CGDisplayIsAsleep(screen.displayID) == 0, now - lastReading < 1 else { stop(); return }
        let lid = smoother.step(at: now, dt: min(now - lastTick, 0.1))
        lastTick = now
        let angle = reference(lid), start = Settings.startAngle
        if !isVisible {
            guard angle < start - 0.1 else {
                if now - capturedAt > 1.5 { stop() }
                return
            }
            isVisible = true
            shownAt = now
            openedAt = smoother.velocity > 0 ? now : nil
            entryOffset = max(0, start - angle)
            window.alphaValue = 0
            render(angle: start)
            window.orderFrontRegardless()
            beginPointerFade()
            onStateChange("Active")
        }
        if angle >= start + 0.3, now - shownAt > 0.3 { stop(); return }
        let stalledOpening = openedAt.map { now - max($0, smoother.lastChangeAt) > 3 } ?? false
        if stalledOpening || (!Settings.adaptiveAngle && angle > start - 15 && now - max(shownAt, smoother.lastChangeAt) > 3) {
            restingAngle = smoother.latest
            stop()
            return
        }
        let entry = entryOffset > 1 ? smoothstep((now - shownAt) / 0.2) : 1
        let played = min(start, angle + (start - angle) * (1 - entry))
        render(angle: played)
        window.alphaValue = smoothstep((now - shownAt) / 0.06)
        if Settings.cursorFade {
            beginPointerFade()
            movePointer(alpha: Formula.cursorOpacity(played))
        } else { endPointerFade() }
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

    // MARK: Mouse pointer

    /// The real pointer is drawn above every window, so it would stay sharp on top of the fold.
    private func beginPointerFade() {
        guard Settings.cursorFade, pointerWindow == nil, Session.isUnlocked, screen.frame.contains(NSEvent.mouseLocation) else { return }
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

    private func render(angle: CGFloat) {
        guard Session.isUnlocked else { stop(); return }
        guard let sharp = sharpTexture, let blurs = blurSet, let drawable = metalLayer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let size = screen.frame.size
        let p = Formula.progress(angle), phi = p * .pi / 2 * 0.53
        let distance = 1.9 * size.height, eye = 1.36 * size.height
        let a = distance * cos(phi) - eye * sin(phi)
        let degenerate = a <= 0.05 * distance || abs(phi) > 80 * .pi / 180
        let edgeOn: CGFloat = degenerate ? 0 : clamp01((a / distance - 0.05) / 0.25)
        let brightness = smoother.latest < 6 ? 0 : edgeOn * smoothstep((angle - Settings.minAngle) / 5)
        let mm = CGDisplayScreenSize(screen.displayID).height
        let pointsPerCM = size.height / (mm > 0 ? mm / 10 : 22.3)
        let lift = curves.lift.value(at: angle)
        let b = lift * pointsPerCM, c = -0.68 * min(1, max(0, lift / 2.33)) * pointsPerCM
        var uniforms = Uniforms(
            radii: SIMD4(blurs.radii.map(Float.init)), margins: SIMD4(blurs.margins.map(Float.init)),
            size: SIMD2(Float(size.width), Float(size.height)), scale: Float(screen.backingScaleFactor), D: Float(distance),
            A: Float(a), sinPhi: Float(sin(phi)), s: Float(smoothstep(p)), rMax: Float(blurs.radii.last ?? 1),
            levels: Int32(blurs.textures.count), black: degenerate ? 1 : 0,
            bottom: Float(min(0.9, max(0, curves.bottom.value(at: angle)))), top: Float(min(0.95, max(0, curves.top.value(at: angle)))),
            crop: Float(max(-0.5, curves.crop.value(at: angle))), vignette: Float(0.8 * Formula.vignetteOpacity(angle)),
            vignetteReach: Float(curves.vignette.value(at: angle)), vignetteEdge: 0.25,
            blurReach: Float(curves.blur.value(at: angle)), blurBottom: 0.1, grainy: Float(curves.grainy.value(at: angle)), blurScale: 1,
            darkScale: 1, brightness: Float(brightness), hinge: SIMD4(Float(b), Float(c), Float(eye + b), 0))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(sharp, index: 0)
        encoder.setFragmentTextures(blurs.textures, range: 1..<(1 + blurs.textures.count))
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commands.addCompletedHandler { buffer in
            if let error = buffer.error { logger.error("Frame failed: \(error.localizedDescription)") }
        }
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    }
}
