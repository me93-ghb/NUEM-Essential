// NUEM by TGTools123 · Copyright © 2026 TGTools123, GNU GPL v3.
// Looks: the whole tuning (look settings + every curve) as a small JSON file, `.nuemlook`, to share. {"format":
// "nuem-look", "version": 1, "name": "Subtle", "settings": {"strength": 0.45, "maxBlur": 0.009}, "curves": {"blur":
// [[46.8, 1.3], [90.4, 0]], "vignette": []}}       // [] = use the formula Applying a look first resets every look
// setting and curve to its built-in value, then applies what the file lists — so a look may list only what differs
// from the default (an empty look = the default).

import Cocoa
import UniformTypeIdentifiers

extension UTType {
    static let nuemLook = UTType(exportedAs: "io.github.tgtools123.nuem.look", conformingTo: .json)
}

struct Look: Codable {
    var format = "nuem-look"
    var version = 1
    var name: String
    var settings: [String: Double]?
    var curves: [String: [[Double]]]?            // curve id → [[angle, value], …]
}

enum LookError: LocalizedError {
    case invalid
    var errorDescription: String? { "This file isn't a NUEM look." }
}

enum LookLibrary {
    static let fileExtension = "nuemlook"

    /// Looks shipped inside the app, "Default" first.
    static var presets: [URL] {
        let urls = Bundle.main.urls(forResourcesWithExtension: fileExtension, subdirectory: "Looks") ?? []
        func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
        return urls.sorted { name($0) == "Default" || (name($1) != "Default" && name($0).localizedStandardCompare(name($1)) == .orderedAscending) }
    }

    /// The user's looks: ~/Library/Application Support/NUEM/Looks.
    static var userFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("NUEM/Looks", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static var saved: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func load(_ url: URL) throws -> Look {
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000, var look = try? JSONDecoder().decode(Look.self, from: data),
              look.format == "nuem-look", look.version <= 1 else { throw LookError.invalid }
        if look.name.trimmingCharacters(in: .whitespaces).isEmpty { look.name = url.deletingPathExtension().lastPathComponent }
        return look
    }

    static func save(_ look: Look, to url: URL) throws { try encode(look).write(to: url, options: .atomic) }

    /// Copies a look into the user folder (unless it's already there) and returns the copy.
    static func importCopy(of url: URL) throws -> URL {
        _ = try load(url)
        let folder = userFolder
        if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return url }
        let data = try Data(contentsOf: url), base = url.deletingPathExtension().lastPathComponent
        for n in 1...99 {
            let candidate = folder.appendingPathComponent(n == 1 ? base : "\(base) \(n)").appendingPathExtension(fileExtension)
            if let existing = try? Data(contentsOf: candidate) {
                if existing == data { return candidate }
                continue
            }
            try data.write(to: candidate, options: .atomic)
            return candidate
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// The current tuning, complete.
    static func current(named name: String, curves: Curves) -> Look {
        var settings: [String: Double] = [:]
        for key in Settings.lookKeys { settings[key] = rounded(UserDefaults.standard.double(forKey: key)) }
        var map: [String: [[Double]]] = [:]
        for curve in curves.all { map[curve.id] = curve.points.map { [rounded($0.angle), rounded($0.value)] } }
        return Look(name: name, settings: settings, curves: map)
    }

    static func apply(_ look: Look, to curves: Curves) {
        let defaults = UserDefaults.standard
        for key in Settings.lookKeys {
            if let value = setting(key, of: look) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for curve in curves.all {                   // after the settings: curves are sampled up to startAngle
            if let pairs = look.curves?[curve.id] { curve.set(points(pairs, for: curve)) } else { curve.resetToDefault() }
        }
    }

    /// True if the current tuning is what applying `look` gives.
    static func matches(_ look: Look, curves: Curves) -> Bool {
        for key in Settings.lookKeys {
            let expected = setting(key, of: look) ?? (Settings.defaults[key] as? Double ?? 0)
            if !close(expected, UserDefaults.standard.double(forKey: key)) { return false }
        }
        for curve in curves.all {
            let expected = look.curves?[curve.id].map { points($0, for: curve) } ?? curve.builtIn
            guard expected.count == curve.points.count else { return false }
            for (a, b) in zip(expected, curve.points) where !close(a.angle, b.angle) || !close(a.value, b.value) { return false }
        }
        return true
    }

    /// Readable JSON: one setting per line, one curve per line.
    static func encode(_ look: Look) -> Data {
        func number(_ x: Double) -> String { x == x.rounded() && abs(x) < 1e15 ? String(Int64(x)) : String(x) }
        func string(_ s: String) -> String { (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\"" }
        func pair(_ p: [Double]) -> String { "[" + p.map(number).joined(separator: ", ") + "]" }
        var sections: [String] = ["  \"format\": \(string(look.format))", "  \"version\": \(look.version)", "  \"name\": \(string(look.name))"]
        if let settings = look.settings, !settings.isEmpty {
            let lines: [String] = settings.keys.sorted().map { key in "    \(string(key)): \(number(settings[key]!))" }
            sections.append("  \"settings\": {\n" + lines.joined(separator: ",\n") + "\n  }")
        }
        if let curves = look.curves, !curves.isEmpty {
            let lines: [String] = curves.keys.sorted().map { id in
                let points: String = curves[id]!.map(pair).joined(separator: ", ")
                return "    \(string(id)): [\(points)]"
            }
            sections.append("  \"curves\": {\n" + lines.joined(separator: ",\n") + "\n  }")
        }
        return Data(("{\n" + sections.joined(separator: ",\n") + "\n}\n").utf8)
    }

    /// A look setting from a file, clamped to its range; nil if absent or not a number.
    private static func setting(_ key: String, of look: Look) -> Double? {
        guard let value = look.settings?[key], value.isFinite, let range = Settings.lookRanges[key] else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// Points from a file, sanitized: at most 64, finite, angle 0…180°, value within the curve's range.
    private static func points(_ pairs: [[Double]], for curve: ParamCurve) -> [CurvePoint] {
        pairs.prefix(64).compactMap { pair -> CurvePoint? in
            guard pair.count == 2, pair[0].isFinite, pair[1].isFinite else { return nil }
            return CurvePoint(angle: min(180, max(0, pair[0])), value: min(Double(curve.maxValue), max(Double(curve.minValue), pair[1])))
        }.sorted { $0.angle < $1.angle }
    }
    private static func rounded(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
    private static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.0005 * max(1, abs(a)) }
}
