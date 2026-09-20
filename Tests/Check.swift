import Cocoa
import Metal

@main
struct Check {
    @MainActor static func main() throws {
        // Argument-domain defaults do not alter the user's saved preferences.
        UserDefaults.standard.setVolatileDomain(["effectEnabled": true, "adaptiveAngle": true, "cursorFade": true], forName: UserDefaults.argumentDomain)
        Settings.register()
        let curves = Curves()
        precondition(abs(curves.crop.value(at: 53.5) - 0.253) < 1e-9)
        precondition(abs(curves.lift.value(at: 95) - 0.173) < 1e-9)
        for angle in stride(from: CGFloat(0), through: 180, by: 0.1) {
            for curve in [curves.crop, curves.top, curves.bottom, curves.lift, curves.blur, curves.grainy, curves.vignette] {
                precondition(curve.value(at: angle).isFinite)
            }
        }
        let adaptive = AdaptiveAngle()
        adaptive.observe(118, at: 1, effectVisible: false, paused: false)
        adaptive.observe(118, at: 2.1, effectVisible: false, paused: false)
        precondition(adaptive.start(at: 2.1) == 115)
        precondition(adaptive.reference(115, at: 2.1) == 95)
        for hz in [60.0, 120.0] {
            let smoother = AngleSmoother()
            smoother.push(100, at: 1)
            for frame in 1...Int(hz * 3) {
                let time = 1 + Double(frame) / hz
                smoother.push(80, at: time)
                let value = smoother.step(at: time, dt: 1 / hz)
                precondition(value.isFinite && value >= 79.99 && value <= 100.01)
            }
            precondition(abs(smoother.value - 80) < 0.01)
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vmain")
        descriptor.fragmentFunction = library.makeFunction(name: "fmain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        let source = device.makeTexture(descriptor: textureDescriptor)!, output = device.makeTexture(descriptor: textureDescriptor)!
        let pixels = [UInt8](repeating: 255, count: 32 * 32 * 4)
        source.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 128)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear
        let sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        var u = Uniforms(radii: SIMD4(1,2,3,4), margins: .zero, size: SIMD2(32,32), scale: 1, D: 64,
                         A: 64, sinPhi: 0, s: 0, rMax: 4, levels: 4, black: 0, bottom: 0, top: 0,
                         crop: 0, vignette: 0, vignetteReach: 0, vignetteEdge: 0.25,
                         blurReach: 0, blurBottom: 0.1, grainy: 0, blurScale: 1,
                         darkScale: 1, brightness: 1, hinge: .zero)
        func draw() -> [UInt8] {
            let commands = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            for index in 0...4 { encoder.setFragmentTexture(source, index: index) }
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commands.commit(); commands.waitUntilCompleted()
            precondition(commands.status == .completed)
            var result = [UInt8](repeating: 0, count: pixels.count)
            output.getBytes(&result, bytesPerRow: 128, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
            return result
        }
        precondition(draw().allSatisfy { $0 == 255 }, "Open fold must preserve the snapshot")
        u.brightness = 0
        let dark = draw()
        precondition(dark.enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 }, "Closed fold must be opaque black")
        u.brightness = 1; u.black = 1
        precondition(draw() == dark, "Degenerate projection must be opaque black")
        print("PASS: fixed curves, adaptive angle, 60/120 Hz smoothing, Metal layout and open/closed rendering")
    }
}
