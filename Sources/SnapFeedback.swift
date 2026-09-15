// Copyright © 2026 TGTools123. NUEM is free software under the GNU GPL v3.
// Feedback when the screen snaps back to normal after the lid reopens: a click sound and a trackpad tap.

import AVFoundation
import IOKit

/// Trackpad tap strength, from a single medium tap to a burst of the strongest built-in waveform.
enum HapticLevel: Int, CaseIterable {
    case light = 1, strong, double, triple, maximum

    static var current: HapticLevel { HapticLevel(rawValue: UserDefaults.standard.integer(forKey: "snapHapticLevel")) ?? .strong }

    var name: String {
        switch self {
        case .light: return "Light"
        case .strong: return "Strong"
        case .double: return "Double"
        case .triple: return "Triple"
        case .maximum: return "Maximum"
        }
    }

    var detail: String {
        switch self {
        case .light: return "One medium tap"
        case .strong: return "One strong tap (default)"
        case .double: return "Two strong taps"
        case .triple: return "Three strong taps"
        case .maximum: return "A burst of six strong taps"
        }
    }

    /// Waveform and start time (seconds) of each pulse.
    var pulses: [(waveform: Int32, at: Double)] {
        switch self {
        case .light: return [(4, 0)]
        case .strong: return [(6, 0)]
        case .double: return [(6, 0), (6, 0.045)]
        case .triple: return [(6, 0), (6, 0.035), (6, 0.070)]
        case .maximum: return (0..<6).map { (6, Double($0) * 0.025) }
        }
    }
}

final class SnapFeedback {
    private let trackpad = TrackpadActuator()
    var hapticAvailable: Bool { trackpad.isAvailable }
    /// Every sound plays through one engine, loaded in advance and mixed by a render block (`Voices`): the snap
    /// click, and the hinge click (Hinge notches), which can overlap.
    private let engine = AVAudioEngine()
    private let voices: Voices
    /// Engine work on its own queue: starting the audio output can block for tens of milliseconds (90 ms measured
    /// when it wakes up), which on the main thread stalled the fold.
    private let audio = DispatchQueue(label: "nuem-sounds", qos: .userInteractive)
    private var warmUntil: CFTimeInterval = 0                   // main thread
    private var running = false                                 // main thread: the engine is known to be running
    private var lastStart: CFTimeInterval = -.infinity          // main thread

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let voices = Voices(sampleRate: rate > 0 ? rate : 48000)
        self.voices = voices
        let source = AVAudioSourceNode(format: voices.format) { _, _, frames, list in voices.render(frames, list) }
        audio.async { [self] in
            voices.set(Voices.snap, url: Self.snapURL)
            voices.set(Voices.hinge, url: Bundle.main.url(forResource: "hinge", withExtension: "wav"))
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: voices.format)
            engine.prepare()
        }
        // The output changed or came back (a sleep, headphones): the engine stopped; the next `warm` starts it again.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.running = false
        }
    }

    /// The user's sound if they chose one (CustomSound), otherwise the bundled click.
    private static var snapURL: URL? {
        CustomSound.exists ? CustomSound.url : Bundle.main.url(forResource: "snap", withExtension: "wav")
    }

    func reloadSound() {
        audio.async { [self] in voices.set(Voices.snap, url: Self.snapURL) }
    }

    /// Keeps the audio output running for the next 3 s.
    func warm() {
        let now = CACurrentMediaTime()
        warmUntil = now + 3
        guard !running, now - lastStart > 0.25 else { return }
        lastStart = now
        audio.async { [self] in
            let started = startEngine()
            DispatchQueue.main.async { [self] in
                running = started
                if started { coolDownLater() }
            }
        }
    }

    private func coolDownLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, running else { return }
            guard CACurrentMediaTime() >= warmUntil else { coolDownLater(); return }
            running = false
            audio.async { self.engine.stop() }
        }
    }

    /// Audio queue.
    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            trace("sound: the audio output didn't start — \(error.localizedDescription)")
            return false
        }
    }

    /// Called as an effect gets ready: wakes the audio output (`warm`) and opens the actuator handles the burst will
    /// need, so at the snap both only have to fire.
    func prepare() {
        warm()
        let taps = (Settings.snapHaptic ? HapticLevel.current.pulses.count : 0) + (Settings.detents && Settings.detentHaptic ? 3 : 0)
        if taps > 0 { trackpad.arm(min(6, taps)) }        // up to 6 handles can be open at once
    }

    func snap() {
        if Settings.snapSound { playSound() }
        if Settings.snapHaptic { tap() }
    }

    func playSound() { play(Voices.snap, volume: Float(clamp01(Settings.snapVolume))) }

    private func play(_ sound: Int, volume: Float) {
        warm()
        audio.async { [self] in
            guard startEngine() else { return }
            voices.play(sound, volume: volume)
        }
    }

    func tap(_ level: HapticLevel = .current) { trackpad.play(level.pulses) }

    /// One notch of the hinge (Hinge notches): the hinge click, at its own volume, and a single trackpad pulse —
    /// medium or the strongest waveform.
    func notch() {
        if Settings.detentSound { play(Voices.hinge, volume: Float(Settings.detentVolume)) }
        if Settings.detentHaptic { trackpad.play([(Settings.detentStrong ? 6 : 4, 0)]) }
    }
}

/// The sounds, mixed on the audio thread by one render block: a sound starts at the very next I/O cycle.
private final class Voices {
    static let snap = 0, hinge = 1
    private struct Sound { let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int }
    private struct Voice { var sound = -1, position = 0, volume: Float = 0 }
    let format: AVAudioFormat
    private let lock = NSLock()
    private var sounds: [Sound?] = [nil, nil]                   // under `lock`; never freed: a replaced one may still play
    private var requests: [(sound: Int, volume: Float)] = []    // under `lock`
    private var live: [Sound?] = [nil, nil]                     // audio thread
    private var voices = [Voice](repeating: Voice(), count: 8)  // audio thread: 0 the snap, 1… hinge clicks
    private var nextHinge = 0                                   // audio thread

    init(sampleRate: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        requests.reserveCapacity(16)
    }

    func set(_ index: Int, url: URL?) {
        let sound = url.flatMap(load)
        lock.lock(); sounds[index] = sound; lock.unlock()
    }

    func play(_ index: Int, volume: Float) {
        lock.lock(); if requests.count < 16 { requests.append((index, volume)) }; lock.unlock()
    }

    private func load(_ url: URL) -> Sound? {
        guard let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil, source.frameLength > 0,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        if file.processingFormat.channelCount == 1 { converter.channelMap = [0, 0] }    // mono: on both sides
        let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false, error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return nil }
        let frames = Int(out.frameLength)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames), right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.update(from: data[0], count: frames)
        right.update(from: data[1], count: frames)
        return Sound(left: left, right: right, frames: frames)
    }

    /// Audio thread.
    func render(_ frameCount: AVAudioFrameCount, _ list: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(list), frames = Int(frameCount)
        guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        l.update(repeating: 0, count: frames)
        r.update(repeating: 0, count: frames)
        if lock.try() {                                         // never waits: busy, the requests go next cycle
            live = sounds
            for request in requests {
                let slot = request.sound == Self.snap ? 0 : 1 + nextHinge % (voices.count - 1)
                if request.sound != Self.snap { nextHinge += 1 }
                voices[slot] = Voice(sound: request.sound, position: 0, volume: request.volume)
            }
            requests.removeAll(keepingCapacity: true)
            lock.unlock()
        }
        for i in voices.indices where voices[i].sound >= 0 {
            guard let sound = live[voices[i].sound], voices[i].position < sound.frames else { voices[i].sound = -1; continue }
            let p = voices[i].position, n = min(frames, sound.frames - p), v = voices[i].volume
            for k in 0..<n {
                l[k] += sound.left[p + k] * v
                r[k] += sound.right[p + k] * v
            }
            voices[i].position += n
        }
        return noErr
    }
}

/// The user's own snap sound, if they chose one: ~/Library/Application Support/NUEM/Sounds/snap.caf.
enum CustomSound {
    static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NUEM/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("snap.caf")
    }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Makes an audio file the snap sound, cut to where the sound starts — the first sample above 1 % of its peak, as
    /// the bundled click was — and to 2 s at most (with a 10 ms fade if cut).
    static func importSound(from source: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat                  // float32, one buffer per channel
        let available = AVAudioFrameCount(min(file.length, AVAudioFramePosition(format.sampleRate * 30)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: available) else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer, frameCount: available)
        guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let frames = Int(buffer.frameLength), channels = Int(format.channelCount)
        var peak: Float = 0
        for c in 0..<channels { for i in 0..<frames { peak = max(peak, abs(samples[c][i])) } }
        guard peak > 0 else { throw CocoaError(.fileReadCorruptFile) }          // silence
        var onset = 0
        search: for i in 0..<frames {
            for c in 0..<channels where abs(samples[c][i]) > peak * 0.01 { onset = i; break search }
        }
        let start = max(0, onset - Int(format.sampleRate * 0.0005))
        let length = min(frames - start, Int(format.sampleRate * 2))
        guard let cut = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let out = cut.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        cut.frameLength = AVAudioFrameCount(length)
        let fade = length < frames - start ? min(length, Int(format.sampleRate * 0.01)) : 0
        for c in 0..<channels {
            out[c].update(from: samples[c] + start, count: length)
            for i in 0..<fade { out[c][length - fade + i] *= Float(fade - i) / Float(fade) }
        }
        try? FileManager.default.removeItem(at: url)
        let copy = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: format.isInterleaved)
        try copy.write(from: cut)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

/// An actuator handle fires only once (later calls return success but do nothing), so every pulse needs its own:
/// create, open, actuate, close, release.
final class TrackpadActuator {
    private typealias CreateFn = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias OpenFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias CloseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private var create: CreateFn?, open: OpenFn?, close: CloseFn?, actuate: ActuateFn?
    private var deviceIDs: [UInt64] = []                                 // every Force Touch trackpad
    private let queue = DispatchQueue(label: "trackpad-haptics", qos: .userInteractive)
    private var pool: [(device: UInt64, handle: UnsafeMutableRawPointer)] = []   // opened, not fired yet (queue only)
    private var poolOpenedAt: TimeInterval = 0
    private(set) var isAvailable = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let createSymbol = dlsym(lib, "MTActuatorCreateFromDeviceID"),
              let openSymbol = dlsym(lib, "MTActuatorOpen"),
              let closeSymbol = dlsym(lib, "MTActuatorClose"),
              let actuateSymbol = dlsym(lib, "MTActuatorActuate") else { return }
        create = unsafeBitCast(createSymbol, to: CreateFn.self)
        open = unsafeBitCast(openSymbol, to: OpenFn.self)
        close = unsafeBitCast(closeSymbol, to: CloseFn.self)
        actuate = unsafeBitCast(actuateSymbol, to: ActuateFn.self)
        // Keep the trackpads whose actuator opens (checked without firing).
        deviceIDs = Self.multitouchDeviceIDs().filter { id in
            guard let handle = openHandle(id) else { return false }
            closeHandle(handle)
            return true
        }
        isAvailable = !deviceIDs.isEmpty
    }

    /// Opens `count` handles per trackpad ahead of the snap.
    func arm(_ count: Int) {
        guard isAvailable else { return }
        queue.async { [self] in
            if now - poolOpenedAt > 30 { drainPool() }
            for id in deviceIDs {
                let missing = count - pool.filter { $0.device == id }.count
                for _ in 0..<max(0, missing) {
                    if let handle = openHandle(id) { pool.append((id, handle)) }
                }
            }
            poolOpenedAt = now
        }
    }

    func play(_ pulses: [(waveform: Int32, at: Double)]) {
        guard isAvailable, let actuate else { return }
        queue.async { [self] in
            if now - poolOpenedAt > 30 { drainPool() }
            let start = now
            for pulse in pulses {
                let handles = deviceIDs.compactMap(takeHandle)            // armed ones are instant
                let wait = start + pulse.at - now
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // (0, 0, 2) are the extra waveform arguments used by HapticKey; their meaning is undocumented.
                for handle in handles { _ = actuate(handle, pulse.waveform, 0, 0, 2) }
                handles.forEach(closeHandle)
            }
        }
    }

    // MARK: Handles (queue only, except during init)

    private func takeHandle(_ device: UInt64) -> UnsafeMutableRawPointer? {
        if let index = pool.firstIndex(where: { $0.device == device }) { return pool.remove(at: index).handle }
        return openHandle(device)
    }

    private func openHandle(_ device: UInt64) -> UnsafeMutableRawPointer? {
        guard let create, let open, let handle = create(device) else { return nil }
        guard open(handle) == 0 else {
            Unmanaged<AnyObject>.fromOpaque(handle).release()
            return nil
        }
        return handle
    }

    private func closeHandle(_ handle: UnsafeMutableRawPointer) {
        _ = close?(handle)
        Unmanaged<AnyObject>.fromOpaque(handle).release()
    }

    private func drainPool() {
        pool.forEach { closeHandle($0.handle) }
        pool.removeAll()
    }

    /// Multitouch IDs of the trackpads that support actuation.
    private static func multitouchDeviceIDs() -> [UInt64] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ids: [UInt64] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if property("ActuationSupported") as? Bool == true, let id = (property("Multitouch ID") as? NSNumber)?.uint64Value {
                ids.append(id)
            }
        }
        return ids
    }
}
