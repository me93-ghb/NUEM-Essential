// Part of NUEM, made by TGTools123. Copyright © 2026 TGTools123, GNU GPL v3.
// Wallpaper colors (a color setting set to "wallpaper" or "wallpaper:N"): what's drawn at the desktop's level on the
// built-in display — macOS's wallpaper, or a live wallpaper app's window above it — captured small, without the
// desktop icons or any window.

import Cocoa
import CoreImage
import MetalKit
import ScreenCaptureKit

enum Wallpaper {
    private static var storedMatte: CGImage?
    private static var storedAverage: NSColor?
    private static var storedMain: [NSColor] = []
    private static var loaded = false
    private static var capturing = false
    private static var lastCapture: CFTimeInterval = -.infinity

    /// The wallpaper, 64 × 40 pixels and blurred: a matte of its colors, not a picture.
    static var matte: CGImage? { load(); return storedMatte }
    /// Its average color.
    static var average: NSColor? { load(); return storedAverage }
    /// Its main colors, the most present first (up to 6).
    static var mainColors: [NSColor] { load(); return storedMain }
    /// A small picture of it for the settings' swatch.
    static var swatch: NSImage? { matte.map { NSImage(cgImage: $0, size: NSSize(width: 32, height: 20)) } }

    static func texture(device: MTLDevice) -> MTLTexture? {
        guard let matte else { return nil }
        return try? MTKTextureLoader(device: device).newTexture(cgImage: matte, options: [.SRGB: false])
    }

    /// First use: the desktop picture's file as a first guess, and a capture of what really shows.
    private static func load() {
        guard !loaded else { return }
        loaded = true
        if let url = NSScreen.screens.first(where: \.isBuiltin).flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 256,
               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            process(image).map(apply)
        }
        capture()
    }

    /// Captures the wallpaper again, at most every 10 s.
    static func capture(then done: (() -> Void)? = nil) {
        if let done { pending.append(done) }
        load()                                                 // the first use starts a capture itself
        guard !capturing else { return }                       // the capture under way calls `pending`
        let now = CACurrentMediaTime()
        guard now - lastCapture > 10, CGPreflightScreenCaptureAccess(),
              let displayID = NSScreen.screens.first(where: \.isBuiltin)?.displayID else { flush(); return }
        capturing = true
        lastCapture = now
        Task.detached(priority: .utility) {
            let image = await captureImage(of: displayID)
            let result = image.flatMap(process)                // the blur and the main colors, off the main thread
            await MainActor.run {
                capturing = false
                if let result { apply(result) }
                flush()
            }
        }
    }

    private static var pending: [() -> Void] = []
    private static func flush() {
        let callbacks = pending
        pending = []
        callbacks.forEach { $0() }
    }

    /// Only the windows at the desktop's level or below on that display: the system wallpaper and a live wallpaper
    /// app's window (the desktop icons are one level up), 256 pixels wide.
    private static func captureImage(of displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
            let windows = content.windows.filter { $0.windowLayer <= desktopLevel && $0.frame.intersects(display.frame) }
            guard !windows.isEmpty else { return nil }
            let config = SCStreamConfiguration()
            config.width = 256
            config.height = max(1, Int(256 * display.frame.height / max(1, display.frame.width)))
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: windows),
                                                              configuration: config)
        } catch {
            logger.info("Wallpaper capture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private struct Processed { let matte: CGImage, average: NSColor, main: [NSColor] }

    /// Matte, average and main colors of a capture; nil for a black one (the display was off). Any thread.
    private static func process(_ image: CGImage) -> Processed? {
        guard let matte = makeMatte(image), let average = averageColor(matte), average.brightnessComponent > 0.01 else { return nil }
        return Processed(matte: matte, average: average, main: mainColors(of: image))
    }

    private static func apply(_ result: Processed) {
        storedMatte = result.matte
        storedAverage = result.average
        storedMain = result.main
    }

    private static let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ciContext = CIContext(options: [.workingColorSpace: rgb])    // made once: making one is slow

    /// Aspect fill into `width` × `height`, as the desktop shows it.
    private static func pixels(of image: CGImage, width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        return context
    }

    private static func makeMatte(_ image: CGImage) -> CGImage? {
        guard let small = pixels(of: image, width: 64, height: 40)?.makeImage() else { return nil }
        let blurred = CIImage(cgImage: small).clampedToExtent().applyingGaussianBlur(sigma: 4)
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 40))
        return ciContext.createCGImage(blurred, from: blurred.extent, format: .RGBA8, colorSpace: rgb)
    }

    private static func samples(of image: CGImage, width: Int, height: Int) -> [SIMD3<Float>] {
        guard let context = pixels(of: image, width: width, height: height), let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).map { SIMD3(Float(bytes[$0 * 4]), Float(bytes[$0 * 4 + 1]), Float(bytes[$0 * 4 + 2])) / 255 }
    }

    private static func averageColor(_ image: CGImage) -> NSColor? {
        let all = samples(of: image, width: image.width, height: image.height)
        guard !all.isEmpty else { return nil }
        let mean = all.reduce(SIMD3<Float>.zero, +) / Float(all.count)
        return NSColor(srgbRed: CGFloat(mean.x), green: CGFloat(mean.y), blue: CGFloat(mean.z), alpha: 1)
    }

    /// k-means on 48 × 30 pixels (8 clusters seeded along the brightness, 10 rounds); the clusters are kept by size,
    /// dropping the tiny ones and those too close to one already kept.
    private static func mainColors(of image: CGImage) -> [NSColor] {
        let points = samples(of: image, width: 48, height: 30)
        guard points.count > 8 else { return [] }
        func luma(_ p: SIMD3<Float>) -> Float { 0.299 * p.x + 0.587 * p.y + 0.114 * p.z }
        let sorted = points.sorted { luma($0) < luma($1) }
        var centers = (0..<8).map { sorted[(sorted.count - 1) * $0 / 7] }
        var counts = [Int](repeating: 0, count: 8)
        for _ in 0..<10 {
            var sums = [SIMD3<Float>](repeating: .zero, count: 8)
            counts = [Int](repeating: 0, count: 8)
            for p in points {
                let i = centers.indices.min { simd_distance_squared(p, centers[$0]) < simd_distance_squared(p, centers[$1]) }!
                sums[i] += p
                counts[i] += 1
            }
            for i in centers.indices where counts[i] > 0 { centers[i] = sums[i] / Float(counts[i]) }
        }
        var kept: [SIMD3<Float>] = []
        for i in centers.indices.sorted(by: { counts[$0] > counts[$1] })
        where counts[i] >= points.count / 50 && kept.allSatisfy({ simd_distance(centers[i], $0) > 0.12 }) {
            kept.append(centers[i])
        }
        return kept.prefix(6).map { NSColor(srgbRed: CGFloat($0.x), green: CGFloat($0.y), blue: CGFloat($0.z), alpha: 1) }
    }
}
