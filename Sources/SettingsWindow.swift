// Copyright © 2026 TGTools123. NUEM, GNU General Public License v3.
// Settings window: a sidebar of panes over grouped forms, in the style of System Settings.

import SwiftUI
import AppKit
import ServiceManagement

enum Links {
    static let repository = URL(string: "https://github.com/tgtools123/NUEM")!
    static let sponsor = URL(string: "https://ko-fi.com/tgtools123")!
    static let githubSponsors = URL(string: "https://github.com/sponsors/tgtools123")!
    static let profile = URL(string: "https://github.com/tgtools123")!
    static let author = "TGTools123"                      // NUEM is made by TGTools123
    static let authorGitHubID = 272741180                 // the author's GitHub account, whatever its name (see NOTICE)
    static let authorAccount = URL(string: "https://api.github.com/user/\(authorGitHubID)")!
    static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
}

/// What the window asks the app to do.
struct SettingsActions {
    var preview: () -> Void
    var showCurves: () -> Void
    var allowScreenRecording: () -> Void
    var toggleOpenAtLogin: () -> Void
    var playSound: () -> Void
    var tap: (HapticLevel) -> Void
    var applyLook: (URL) -> Void
    var saveLook: () -> Void
    var importLook: () -> Void
    var showLooksFolder: () -> Void
    var resetAll: () -> Void
    var setStayAwake: (Bool) -> Void
    var chooseSound: () -> Void
    var defaultSound: () -> Void
    var notch: () -> Void
}

final class SettingsModel: ObservableObject {
    struct LookEntry: Identifiable {
        let look: Look, url: URL, isPreset: Bool
        var id: URL { url }
    }

    let curves: Curves
    let actions: SettingsActions
    let sensorAvailable: Bool, hapticAvailable: Bool
    private(set) var looks: [LookEntry] = []

    init(curves: Curves, actions: SettingsActions, sensorAvailable: Bool, hapticAvailable: Bool) {
        self.curves = curves
        self.actions = actions
        self.sensorAvailable = sensorAvailable
        self.hapticAvailable = hapticAvailable
        reloadLooks()
    }

    /// Re-renders the window: UserDefaults changed, or the window came forward.
    func changed() { objectWillChange.send() }

    /// Bundled looks, then the user's. Read from disk only when the window opens or a look is added.
    func reloadLooks() {
        let presets = LookLibrary.presets
        looks = (presets + LookLibrary.saved).compactMap { url in
            (try? LookLibrary.load(url)).map { LookEntry(look: $0, url: url, isPreset: presets.contains(url)) }
        }
        changed()
    }
    var currentLookName: String { looks.first { LookLibrary.matches($0.look, curves: curves) }?.look.name ?? "Custom" }

    var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    var customSound: Bool { CustomSound.exists }
    /// The system's "stay awake with the lid closed" setting; read when the window comes forward (runs pmset).
    private(set) var stayAwakeOn = StayAwake.isOn
    func refreshSystemState() {
        stayAwakeOn = StayAwake.isOn
        changed()
        Wallpaper.capture { [weak self] in self?.changed() }     // the wallpaper's pastilles, as it is now
    }
    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// True when every curve that can replace a setting has points (the setting is then ignored).
    func drivenByCurve(_ ids: [String]) -> Bool {
        let drivers = ids.compactMap { id in curves.all.first { $0.id == id } }
        return !drivers.isEmpty && drivers.allSatisfy { !$0.points.isEmpty }
    }

    func number(_ key: String, resolution: Double) -> Binding<Double> {
        Binding(get: { UserDefaults.standard.double(forKey: key) },
                set: { UserDefaults.standard.set(($0 / resolution).rounded() * resolution, forKey: key) })
    }
    func flag(_ key: String, then action: ((Bool) -> Void)? = nil) -> Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: key) },
                set: { UserDefaults.standard.set($0, forKey: key); action?($0) })
    }
    func text(_ key: String) -> Binding<String> {
        Binding(get: { UserDefaults.standard.string(forKey: key) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: key) })
    }
}

/// The live lid angle, published separately so only the General header redraws at 15 Hz.
final class LiveLid: ObservableObject {
    @Published var angle: Double?
    @Published var status = ""
    @Published var start = 95.0                  // where the fold starts now (moves with Adaptive angle)
    @Published var viewingAngle: Double?         // detected by Adaptive angle
}

@MainActor
func makeSettingsWindow(model: SettingsModel, live: LiveLid) -> NSWindow {
    let host = NSHostingController(rootView: SettingsView(model: model, live: live))
    host.sceneBridgingOptions = [.title, .toolbars]
    let window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.isReleasedWhenClosed = false
    window.setContentSize(NSSize(width: 740, height: 600))
    window.center()
    window.setFrameAutosaveName("Settings")
    // Permission and login status change outside the app: refresh when the window comes forward.
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
        model.refreshSystemState()
    }
    return window
}

// MARK: - Rows

/// One numeric setting: a slider, its value, and ± steps (the same steps the menu used to offer).
struct SettingRow: Identifiable {
    let key: String, title: String
    var detail: String? = nil
    let range: ClosedRange<Double>, step: Double, resolution: Double
    let format: String
    var scale: Double = 1
    var zeroText: String? = nil
    var curveIDs: [String] = []                  // curves that replace this setting while they have points
    var id: String { key }

    func text(_ value: Double) -> String {
        if value == 0, let zeroText { return zeroText }
        return String(format: format, value * scale)
    }
}

struct SettingGroup: Identifiable {
    let title: String, rows: [SettingRow]
    var id: String { title }
}

/// The built-in display's height in cm: one "screen height" of the eye position (0 if it isn't online).
private let screenHeightCM: Double = {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    guard let id = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return 0 }
    return CGDisplayScreenSize(id).height / 10
}()

private let effectGroups: [SettingGroup] = [
    SettingGroup(title: "Perspective", rows: (screenHeightCM > 0 ? [
        SettingRow(key: "eyeHeight", title: "Eye height", detail: "Your eyes above the hinge",
                   range: 0.2...3, step: 0.1, resolution: 0.01, format: "%.0f cm", scale: screenHeightCM, curveIDs: ["eyeHeight"]),
        SettingRow(key: "eyeDistance", title: "Eye distance", detail: "Your eyes in front of the hinge",
                   range: 0.5...8, step: 0.15, resolution: 0.01, format: "%.0f cm", scale: screenHeightCM, curveIDs: ["eyeDistance"]),
    ] : [
        SettingRow(key: "eyeHeight", title: "Eye height", detail: "Your eye above the hinge, in screen heights",
                   range: 0.2...3, step: 0.1, resolution: 0.01, format: "%.2f", curveIDs: ["eyeHeight"]),
        SettingRow(key: "eyeDistance", title: "Eye distance", detail: "Your eye to the screen, in screen heights",
                   range: 0.5...8, step: 0.15, resolution: 0.01, format: "%.2f", curveIDs: ["eyeDistance"]),
    ]) + [
        SettingRow(key: "strength", title: "Perspective compensation", detail: "1 = exact geometry, 0 = flat image",
                   range: 0...1.5, step: 0.1, resolution: 0.01, format: "%.2f", curveIDs: ["strength"]),
    ]),
    SettingGroup(title: "Crop and stretch", rows: [
        SettingRow(key: "cropZoom", title: "Crop", detail: "Extra zoom anchored at the hinge",
                   range: 0...4, step: 0.1, resolution: 0.01, format: "%.2f", curveIDs: ["crop"]),
        SettingRow(key: "topStretch", title: "Top stretch", detail: "Magnifies the top, under the black",
                   range: 0...0.9, step: 0.1, resolution: 0.01, format: "%.2f", curveIDs: ["top"]),
        SettingRow(key: "bottomStretch", title: "Bottom stretch", detail: "Magnifies the area near the hinge",
                   range: 0...1, step: 0.1, resolution: 0.01, format: "%.2f", curveIDs: ["bottom"]),
        SettingRow(key: "lift", title: "Lift", detail: "The fold's pivot below the screen (the real hinge: 2.3 cm); negative: above it, the picture sinks",
                   range: -20...20, step: 0.5, resolution: 0.05, format: "%.1f cm", curveIDs: ["lift"]),
    ]),
    SettingGroup(title: "Blur", rows: [
        SettingRow(key: "maxBlur", title: "Maximum blur", detail: "Radius, in screen heights",
                   range: 0...0.05, step: 0.005, resolution: 0.001, format: "%.3f"),
        SettingRow(key: "grainyBlur", title: "Grain", detail: "0 = smooth, 1 = grainy",
                   range: 0...1, step: 0.1, resolution: 0.01, format: "%.2f", curveIDs: ["grainy"]),
        SettingRow(key: "blurStartAngle", title: "Starts at",
                   range: 20...120, step: 3, resolution: 1, format: "%.0f°", curveIDs: ["blur"]),
        SettingRow(key: "blurFullAngle", title: "Covers the screen at",
                   range: 0...90, step: 3, resolution: 1, format: "%.0f°", curveIDs: ["blur"]),
    ]),
    SettingGroup(title: "Black", rows: [
        SettingRow(key: "vignetteStartAngle", title: "Starts at",
                   range: 30...120, step: 3, resolution: 1, format: "%.0f°", curveIDs: ["vignette", "vignetteOpacity"]),
        SettingRow(key: "vignetteTopAngle", title: "Covers the top band at",
                   range: 10...110, step: 5, resolution: 1, format: "%.0f°", curveIDs: ["vignette", "vignetteOpacity"]),
        SettingRow(key: "vignetteTopReach", title: "Top band", detail: "Its height, in screen heights",
                   range: 0...1, step: 0.05, resolution: 0.01, format: "%.2f", curveIDs: ["vignette"]),
        SettingRow(key: "vignetteFullAngle", title: "Covers the screen at",
                   range: 0...90, step: 5, resolution: 1, format: "%.0f°", curveIDs: ["vignette"]),
        SettingRow(key: "vignetteIntensity", title: "Intensity",
                   range: 0...1, step: 0.05, resolution: 0.01, format: "%.0f%%", scale: 100),
        SettingRow(key: "keyboardFadeAngle", title: "Keyboard light off at", detail: "With Fade the keyboard light on",
                   range: 0...90, step: 5, resolution: 1, format: "%.0f°"),
    ]),
]

private let glassRow = SettingRow(key: "glassStrength", title: "Glass strength",
                                  range: 0.2...1.5, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100)
private let particleRow = SettingRow(key: "particleSize", title: "Particle size", detail: "Smaller means more particles",
                                     range: 5...24, step: 1, resolution: 1, format: "%.0f pt")
private let particleGlowRow = SettingRow(key: "particleGlow", title: "Glow", detail: "The light around each particle",
                                         range: 0...2, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100)
private let crtRows: [SettingRow] = [
    SettingRow(key: "crtScanSize", title: "Scanline size", detail: "From one line to the next",
               range: 2...12, step: 0.5, resolution: 0.5, format: "%.1f pt"),
    SettingRow(key: "crtScanlines", title: "Scanlines", detail: "How dark the gaps between the lines are",
               range: 0...1, step: 0.05, resolution: 0.01, format: "%.0f%%", scale: 100),
    SettingRow(key: "crtMask", title: "Phosphor stripes", detail: "The tube's red, green and blue stripes",
               range: 0...1, step: 0.05, resolution: 0.01, format: "%.0f%%", scale: 100),
    SettingRow(key: "crtGlow", title: "Glow", detail: "Light bleeding around the bright parts",
               range: 0...2, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100),
    SettingRow(key: "crtSaturation", title: "Saturation",
               range: 0...2, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100),
]
private let crtCurveRow = SettingRow(key: "crtCurve", title: "Tube curvature",
                                     range: 0...1.5, step: 0.1, resolution: 0.01, format: "%.2f")
private let blurTintRow = SettingRow(key: "blurTint", title: "Blur tint", detail: "The blurred picture takes on a color",
                                     range: 0...1, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100, zeroText: "Off")

private let pointerFadeRow = SettingRow(key: "cursorFadeSpan", title: "Fades out over", detail: "Degrees below the start angle",
                                        range: 3...60, step: 3, resolution: 1, format: "%.0f°", curveIDs: ["cursor"])

private let motionRows: [SettingRow] = [
    SettingRow(key: "startAngle", title: "Effect starts below", detail: "Lower it if you usually keep the lid below this angle",
               range: 60...140, step: 1, resolution: 1, format: "%.0f°"),
    SettingRow(key: "minAngle", title: "Fully black below",
               range: 0...40, step: 1, resolution: 1, format: "%.0f°"),
    SettingRow(key: "restTimeout", title: "Rest timeout",
               detail: "Near the start angle, the desktop comes back after the lid rests this long",
               range: 0...10, step: 0.5, resolution: 0.5, format: "%.1f s", zeroText: "Never"),
]

private let adaptiveRows: [SettingRow] = [
    SettingRow(key: "adaptiveOffset", title: "Starts below your angle by",
               range: 3...30, step: 1, resolution: 1, format: "%.0f°"),
    SettingRow(key: "adaptiveSettle", title: "Settle time", detail: "How long the lid must stay within 1° to become your angle",
               range: 0.5...5, step: 0.5, resolution: 0.1, format: "%.1f s"),
]

private let volumeRow = SettingRow(key: "snapVolume", title: "Volume",
                                   range: 0...1, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100)
private let cornerTopRow = SettingRow(key: "snapCornerTop", title: "Top corners", detail: "Their radius, in points",
                                      range: 0...40, step: 0.5, resolution: 0.1, format: "%.1f pt")
private let cornerBottomRow = SettingRow(key: "snapCornerBottom", title: "Bottom corners", detail: "Their radius, in points",
                                         range: 0...40, step: 0.5, resolution: 0.1, format: "%.1f pt")
private let snapOpacityRow = SettingRow(key: "snapOpacity", title: "Opacity",
                                        range: 0.1...1, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100)
private let notchRow = SettingRow(key: "detentStep", title: "Every", range: 5...30, step: 1, resolution: 1, format: "%.0f°")
private let notchVolumeRow = SettingRow(key: "detentVolume", title: "Volume",
                                        range: 0...1, step: 0.1, resolution: 0.01, format: "%.0f%%", scale: 100)
private let depthRow = SettingRow(key: "snapMinDepth", title: "Minimum fold",
                                  detail: "How far below the start angle the lid must go before the click and tap play",
                                  range: 0...30, step: 1, resolution: 1, format: "%.0f°")

/// Section footer: small, secondary and left-aligned, like System Settings (a plain Text footer is right-aligned on
/// macOS).
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)        // wrapped lines too (footers default to trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)                   // lines up with the section titles
    }
}

private struct SliderRow: View {
    @ObservedObject var model: SettingsModel
    let row: SettingRow
    var note: String? = nil                      // replaces the detail line (e.g. why the row is disabled)

    var body: some View {
        let value = model.number(row.key, resolution: row.resolution)
        let byCurve = model.drivenByCurve(row.curveIDs)
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: value, in: row.range)
                    .frame(minWidth: 120, maxWidth: 220)
                Text(row.text(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Stepper("", value: value, in: row.range, step: row.step)
                    .labelsHidden()
            }
            .disabled(byCurve)
        } label: {
            Text(row.title)
            if byCurve {
                Text("Set by its tuning curve")
            } else if let note {
                Text(note)
            } else if let detail = row.detail {
                Text(detail)
            }
        }
    }
}

/// A color setting, chosen in two steps.
private struct ColorRow: View {
    @ObservedObject var model: SettingsModel
    let key: String, title: String
    var note: String? = nil
    var pictureChoice = false

    private enum Source: Hashable { case picture, accent, wallpaper, custom }

    static let presets: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Red", "#FF3B30"), ("Orange", "#FF9500"), ("Yellow", "#FFCC00"), ("Green", "#34C759"),
        ("Mint", "#00C7BE"), ("Cyan", "#4DD9FF"), ("Blue", "#007AFF"), ("Purple", "#AF52DE"), ("Pink", "#FF2D55"),
    ]

    @ViewBuilder var body: some View {
        let defaults = UserDefaults.standard
        let value = defaults.string(forKey: key) ?? ""
        let source: Source = value == "picture" ? .picture : value == "system" ? .accent
            : value.hasPrefix("wallpaper") ? .wallpaper : .custom
        // Each source remembers its last choice, so switching back and forth doesn't lose it.
        let choose = { (choice: String) in
            defaults.set(choice, forKey: key)
            if choice.hasPrefix("wallpaper") { defaults.set(choice, forKey: key + "Wallpaper") }
            if choice.hasPrefix("#") { defaults.set(choice, forKey: key + "Custom") }
        }
        let sourceBinding = Binding<Source>(get: { source }, set: { new in
            switch new {
            case .picture: choose("picture")
            case .accent: choose("system")
            case .wallpaper: choose(defaults.string(forKey: key + "Wallpaper") ?? "wallpaper")
            case .custom:
                let builtIn = Settings.defaults[key] as? String ?? ""
                choose(defaults.string(forKey: key + "Custom") ?? (builtIn.hasPrefix("#") ? builtIn : "#007AFF"))
            }
        })
        Picker(selection: sourceBinding) {
            if pictureChoice { Text("Picture colors").tag(Source.picture) }
            Text("Accent color").tag(Source.accent)
            Text("Wallpaper").tag(Source.wallpaper)
            Text("Custom").tag(Source.custom)
        } label: {
            Text(title)
            if let note { Text(note) }
        }
        .pickerStyle(.menu)
        switch source {
        case .wallpaper:
            let main = Wallpaper.mainColors
            HStack(spacing: 6) {
                Swatch(fill: Color.secondary.opacity(0.15), selected: value == "wallpaper",
                       symbol: Wallpaper.swatch == nil ? "photo.on.rectangle" : nil, image: Wallpaper.swatch) { choose("wallpaper") }
                    .help("The blurred wallpaper: each effect takes the colors of the wallpaper where it is")
                ForEach(main.indices, id: \.self) { index in
                    Swatch(fill: Color(nsColor: main[index]), selected: value == "wallpaper:\(index)") { choose("wallpaper:\(index)") }
                        .help("One of your wallpaper's main colors")
                }
                Spacer()
                Text(value == "wallpaper" ? "Blurred wallpaper" : "Main color").foregroundStyle(.secondary)
            }
        case .custom:
            let preset = Self.presets.first { $0.hex.caseInsensitiveCompare(value) == .orderedSame }
            let wheel = Binding<Color>(get: { Color(nsColor: NSColor(hex: value) ?? .white) }, set: { choose(NSColor($0).hex) })
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.hex) { color in
                    Swatch(fill: Color(nsColor: NSColor(hex: color.hex) ?? .white), selected: preset?.hex == color.hex) { choose(color.hex) }
                        .help(color.name)
                }
                ColorPicker("", selection: wheel, supportsOpacity: false)
                    .labelsHidden()
                    .help("Any color")
                Spacer()
                Text(preset?.name ?? "Custom").foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

/// One round color to click; a ring in the accent color marks the chosen one.
private struct Swatch<Fill: ShapeStyle>: View {
    let fill: Fill
    let selected: Bool
    var symbol: String? = nil
    var image: NSImage? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 20, height: 20)
                .overlay {
                    if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(Circle()) }
                }
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                .overlay { if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) } }
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Window

enum Pane: String, CaseIterable, Identifiable {
    case general = "General", effect = "Effect Console", motion = "Motion", snapBack = "Snap-Back", about = "About"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .effect: return "paintpalette.fill"
        case .motion: return "angle"
        case .snapBack: return "hand.tap.fill"
        case .about: return "info"
        }
    }
    var tint: Color {
        switch self {
        case .general: return .gray
        case .effect: return .purple
        case .motion: return .blue
        case .snapBack: return .orange
        case .about: return .gray
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let live: LiveLid
    @State private var pane: Pane?

    init(model: SettingsModel, live: LiveLid, pane: Pane = .general) {
        _model = ObservedObject(wrappedValue: model)
        self.live = live
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .frame(minWidth: 215)                    // room for "Effect Console" (the column width alone is ignored
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 260)   // in a hosted window)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(pane ?? .general)
                .formStyle(.grouped)
                .navigationTitle((pane ?? .general).rawValue)
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    @ViewBuilder private func detail(_ pane: Pane) -> some View {
        switch pane {
        case .general: GeneralPane(model: model, live: live)
        case .effect: EffectPane(model: model)
        case .motion: MotionPane(model: model)
        case .snapBack: SnapBackPane(model: model)
        case .about: AboutPane()
        }
    }
}

// MARK: - General

/// Side view of the MacBook: the deck, the lid at its live angle, and the zone where the effect runs.
private struct HingeView: View {
    let angle: Double?
    let startAngle: Double

    var body: some View {
        Canvas { context, size in
            let hinge = CGPoint(x: size.width / 2, y: size.height - 6)
            let length = min(size.width / 2 - 6, size.height - 22)
            func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
                let a = CGFloat(degrees * .pi / 180)
                return CGPoint(x: hinge.x - cos(a) * radius, y: hinge.y - sin(a) * radius)
            }
            func segment(to end: CGPoint) -> Path {
                var path = Path()
                path.move(to: hinge)
                path.addLine(to: end)
                return path
            }
            var zone = Path()
            zone.move(to: hinge)
            for degrees in stride(from: 0, through: startAngle, by: 1) { zone.addLine(to: point(degrees, length)) }
            zone.closeSubpath()
            context.fill(zone, with: .color(.accentColor.opacity(0.16)))
            context.stroke(segment(to: point(startAngle, length)), with: .color(.accentColor.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.draw(Text(String(format: "%.0f°", startAngle)).font(.caption2).foregroundColor(.accentColor),
                         at: point(startAngle, length + 11))
            context.stroke(segment(to: point(0, length)), with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round))
            if let angle {
                context.stroke(segment(to: point(min(180, max(0, angle)), length * 0.96)),
                               with: .color(angle < startAngle ? .accentColor : .primary),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: hinge.x - 4, y: hinge.y - 4, width: 8, height: 8)), with: .color(.primary))
        }
        .accessibilityLabel(angle.map { String(format: "Lid open at %.0f degrees", $0) } ?? "Lid angle unavailable")
    }
}

private struct LidHeader: View {
    @ObservedObject var live: LiveLid
    let model: SettingsModel

    var body: some View {
        let start = live.start
        let range = live.viewingAngle.map { String(format: "Your angle %.0f°, the effect runs below %.0f°", $0, start) }
            ?? String(format: "The effect runs below %.0f°", start)
        HStack(spacing: 20) {
            HingeView(angle: live.angle, startAngle: start)
                .frame(width: 190, height: 108)
            VStack(alignment: .leading, spacing: 3) {
                Text(live.angle.map { String(format: "%.1f°", $0) } ?? "—")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(live.status)
                    .foregroundStyle(.secondary)
                Text(model.sensorAvailable ? range : "This Mac has no lid angle sensor")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Button("Preview Effect", action: model.actions.preview)
                    .disabled(!model.sensorAvailable)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    let live: LiveLid
    @State private var confirmingReset = false
    @State private var confirmingStayAwake = false

    var body: some View {
        Form {
            Section { LidHeader(live: live, model: model) }
            if !model.screenRecordingGranted {
                Section {
                    LabeledContent {
                        Button("Allow…", action: model.actions.allowScreenRecording)
                    } label: {
                        Text("Screen Recording is off")
                        Text("NUEM takes one snapshot of the screen as the lid starts closing. It stays in memory and is never saved or sent.")
                    }
                }
            }
            Section {
                Toggle(isOn: model.flag("effectEnabled")) {
                    Text("Enable effect")
                    Text("Plays the fold when you close the lid, and when you open it again")
                }
                Toggle(isOn: model.flag("lockScreen")) {
                    Text("Lock screen")
                    if Settings.lockScreen, !Settings.externalOffWhenClosed, !ExternalDisplays.connected.isEmpty {
                        Text("Also plays when your Mac is locked. With an external display connected, also turn on Turn off external displays with the lid below: without it the fold starts late when you open the lid.")
                    } else {
                        Text("Also plays when your Mac is locked, over the lock screen")
                    }
                }
                Toggle(isOn: model.flag("blurClock")) {
                    Text("Blur the clock of an early capture")
                    Text("When the fold starts from a lock screen captured in an earlier minute, its clock is blurred, then fades into the real clock just before the screen snaps back")
                }
                .disabled(!Settings.lockScreen)
                Picker(selection: model.number("lockScreenAwake", resolution: 1)) {
                    Text("While the lid moves").tag(0.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                } label: {
                    Text("Keep the lock screen on")
                    Text("After you lock your Mac or move the lid (macOS alone turns it off after 5 seconds). Moving the lid also turns a dark screen back on.")
                }
                .disabled(!Settings.lockScreen)
                Toggle(isOn: Binding(get: { model.stayAwakeOn }, set: { on in
                    // Turning it on asks first: the Mac then stays awake with the lid closed, in a bag too.
                    if on && !model.stayAwakeOn { confirmingStayAwake = true; return }
                    model.actions.setStayAwake(on)
                    model.refreshSystemState()
                })) {
                    Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundStyle(.red) + Text(" Stay awake with the lid closed")
                    Text("Opening the lid then only waits for the display, not for the Mac to wake. Uses the battery with the lid closed and stays on if you quit NUEM. Don't carry the Mac in a bag with it on: it stays awake and can get hot. Needs an administrator password.")
                }
                .alert("Keep your Mac awake with the lid closed?", isPresented: $confirmingStayAwake) {
                    Button("Turn On", role: .destructive) {
                        model.actions.setStayAwake(true)
                        model.refreshSystemState()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your Mac won't go to sleep when you close the lid. It keeps using the battery, and in a bag it can overheat. The setting stays on even if you quit NUEM: turn it off here. macOS will ask for an administrator password.")
                }
                Toggle(isOn: model.flag("externalOffWhenClosed")) {
                    Text("Turn off external displays with the lid")
                    Text("Close to essential for the lock screen fold with an external display. When the lid closes, external displays switch off, so your built-in display stays the main one and the fold starts as soon as you open the lid. They come back on at the snap, together with your screen. The Mac then sleeps a few seconds after closing: with Stay awake above, opening doesn't wait for it to wake. Leave it off if you use your Mac with the lid closed.")
                }
                .disabled(!ExternalDisplays.available)
            }
            Section("Angle display") {
                Picker("Menu bar shows", selection: model.text("menuBarStyle")) {
                    Text("Icon").tag("icon")
                    Text("Lid angle").tag("angle")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: model.flag("showHUD")) {
                    Text("Floating angle HUD")
                    Text("Click it to preview, right-click it for the menu, drag it to move it")
                }
            }
            Section {
                Picker("Appearance", selection: model.text("appearance")) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                LabeledContent {
                    HStack {
                        Button("Accent Color") { Settings.colorKeys.forEach { UserDefaults.standard.set("system", forKey: $0) } }
                        Button("Wallpaper") { Settings.colorKeys.forEach { UserDefaults.standard.set("wallpaper", forKey: $0) } }
                    }
                } label: {
                    Text("Effect colors")
                    Text("Sets every effect color at once — the hologram, the particles, the snap animation and the blur tint — to your Mac's accent color or your wallpaper's colors. You can still change each one.")
                }
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin },
                                                      set: { _ in model.actions.toggleOpenAtLogin(); model.changed() }))
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmingReset = true }
                }
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive, action: model.actions.resetAll)
        } message: {
            Text("Every setting and tuning curve returns to its built-in value. Your saved looks are kept.")
        }
    }
}

// MARK: - Appearance

private struct EffectPane: View {
    @ObservedObject var model: SettingsModel
    /// The rows Exact perspective sets aside while it's on (their values stay as they are).
    private static let exactReplaces: Set<String> = ["strength", "cropZoom", "topStretch", "bottomStretch", "lift"]

    var body: some View {
        Form {
            Section {
                LabeledContent("Look") {
                    Menu(model.currentLookName) {
                        ForEach(model.looks.filter(\.isPreset)) { entry in
                            Button(entry.look.name) { model.actions.applyLook(entry.url) }
                        }
                        let saved = model.looks.filter { !$0.isPreset }
                        if !saved.isEmpty {
                            Divider()
                            ForEach(saved) { entry in
                                Button(entry.look.name) { model.actions.applyLook(entry.url) }
                            }
                        }
                    }
                    .fixedSize()
                }
                HStack {
                    Button("Save Current Look…") { model.actions.saveLook(); model.reloadLooks() }
                    Button("Import Look…") { model.actions.importLook(); model.reloadLooks() }
                    Spacer()
                    Button("Show Looks Folder", action: model.actions.showLooksFolder)
                }
            } footer: {
                Footnote("A look is the whole tuning in one small file. Send it to share it.")
            }
            Section {
                let style = Settings.foldStyle
                Picker("Fold style", selection: Binding(get: { Settings.foldStyle },
                                                        set: { UserDefaults.standard.set(Double($0), forKey: "foldStyle") })) {
                    Text("Classic").tag(0)
                    Text("Frosted glass").tag(1)
                    Text("Particles").tag(2)
                    Text("CRT TV").tag(3)
                    Text("CRT filter").tag(6)
                    Text("Black & white").tag(4)
                    Text("Hologram").tag(5)
                }
                .pickerStyle(.menu)
                if style == 1 { SliderRow(model: model, row: glassRow) }
                if style == 0 || style == 1 {
                    SliderRow(model: model, row: blurTintRow)
                    ColorRow(model: model, key: "blurTintColor", title: "Tint color")
                        .disabled(Settings.blurTint == 0)
                }
                if style == 2 {
                    SliderRow(model: model, row: particleRow)
                    SliderRow(model: model, row: particleGlowRow)
                    ColorRow(model: model, key: "particleColor", title: "Color", pictureChoice: true)
                }
                if style == 3 || style == 6 {
                    ForEach(crtRows) { SliderRow(model: model, row: $0) }
                    if style == 3 { SliderRow(model: model, row: crtCurveRow) }
                }
                if style == 5 { ColorRow(model: model, key: "hologramColor", title: "Color") }
            } footer: {
                Footnote(["The fold alone.",
                          "A frosted glass layer fades in on the picture as the lid closes. It moves with the picture, under the grain and the black.",
                          "The picture breaks into glowing particles — its own colors, or the color you pick — as the lid closes, and they come back together as it opens.",
                          "The picture becomes an old tube TV — curved, with scanlines — and switches off into a line, then a dot. Opening turns it back on.",
                          "The colors drain out as the lid closes, into grainy black and white, and come back as it opens.",
                          "The picture turns into a flickering hologram that fades away as the lid closes, and appears then turns solid as it opens.",
                          "A CRT look fades in on the picture — scanlines, phosphor stripes and a soft glow — while the fold goes on underneath."][Settings.foldStyle])
            }
            ForEach(effectGroups) { group in
                Section(group.title) {
                    if group.title == "Perspective" {
                        Toggle(isOn: model.flag("exactPerspective")) {
                            Text("Exact perspective")
                            Text("The picture stays exactly where the screen was when the fold began, as seen from your eye (height and distance below): turned by the lid's own rotation, nothing cropped or stretched. Off, your tuning shapes it.")
                        }
                    }
                    if group.title == "Black" {
                        Toggle(isOn: model.flag("keyboardFade")) {
                            Text("Fade the keyboard light")
                            Text("The keyboard backlight dims with the fold, off by the angle below, and comes back to its level when the fold ends.")
                        }
                    }
                    ForEach(group.rows) { row in
                        let replaced = Settings.exactPerspective && Self.exactReplaces.contains(row.key)
                        SliderRow(model: model, row: row, note: replaced ? "Set by Exact perspective" : nil)
                            .disabled(replaced || (row.key == "keyboardFadeAngle" && !Settings.keyboardFade))
                    }
                    if group.title == "Crop and stretch" {
                        ColorRow(model: model, key: "backgroundColor", title: "Background color",
                                 note: "Where the picture doesn't reach, and the vignette's color, instead of black")
                    }
                }
            }
            Section("Mouse pointer") {
                Toggle(isOn: model.flag("cursorFade")) {
                    Text("Fade the pointer")
                    Text("Hides the pointer during the effect and fades out a copy of it")
                }
                SliderRow(model: model, row: pointerFadeRow)
                    .disabled(!Settings.cursorFade)
            }
            Section {
                LabeledContent {
                    Button("Open Tuning Curves…", action: model.actions.showCurves)
                } label: {
                    Text("Tuning curves")
                    Text("Shape any parameter against the lid angle. A curve with points overrides its slider.")
                }
            }
        }
    }
}

// MARK: - Motion

// TGTools123 (NUEM): the Motion pane.
private struct MotionPane: View {
    @ObservedObject var model: SettingsModel
    private static let percents: [Double] = [0, 25, 50, 75, 100, 125, 150, 200, 300, 400]
    @State private var tab = 0                           // 0 = Closing, 1 = Opening

    /// The key a Motion slider writes: closing's, or opening's on the Opening tab when the two aren't linked.
    private func key(_ closing: String) -> String {
        guard tab == 1, !Settings.motionSynced else { return closing }
        return ["smoothing": "openingSmoothing", "lookAhead": "openingLookAhead", "closingAhead": "openingAhead"][closing]!
    }

    /// Linking applies the tab on screen to both ways; unlinking starts opening from closing's settings.
    private func setSynced(_ on: Bool) {
        let source = Settings.motion(opening: on && tab == 1)
        let keys = on ? ["smoothing", "lookAhead", "closingAhead"] : ["openingSmoothing", "openingLookAhead", "openingAhead"]
        for (key, value) in zip(keys, [source.smoothing, source.lookAhead, source.ahead]) {
            UserDefaults.standard.set(Double(value), forKey: key)
        }
        UserDefaults.standard.set(on, forKey: "motionSynced")
    }

    var body: some View {
        let synced = Settings.motionSynced
        let m = Settings.motion(opening: tab == 1)
        let percent = Double(m.smoothing) * 100
        let index = Binding<Double>(
            get: { Double(Self.percents.indices.min { abs(Self.percents[$0] - percent) < abs(Self.percents[$1] - percent) } ?? 4) },
            set: { UserDefaults.standard.set(Self.percents[Int($0.rounded())] / 100, forKey: key("smoothing")) })
        let look = Double(m.lookAhead), ahead = Double(m.ahead)
        let adaptive = Settings.adaptiveAngle
        Form {
            Section("When the effect runs") {
                ForEach(motionRows) { row in
                    // Adaptive angle decides where the fold starts and replaces the rest timeout.
                    let replaced = adaptive && row.key != "minAngle"
                    SliderRow(model: model, row: row, note: replaced ? "Set by Adaptive angle" : nil)
                        .disabled(replaced)
                }
            }
            Section {
                Toggle(isOn: model.flag("adaptiveAngle")) {
                    Text("Adaptive angle")
                    Text("Follows the angle you work at. Hold the lid still mid-fold and that becomes your new angle: the fold plays back and snaps there.")
                }
                ForEach(adaptiveRows) { SliderRow(model: model, row: $0).disabled(!adaptive) }
            } footer: {
                Footnote("Your tuning isn't changed: lid angles are mapped onto it, so the blur and the black still finish just before the lid closes.")
            }
            Section {
                Picker("Lid", selection: $tab) {
                    Text("Closing").tag(0)
                    Text("Opening").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle(isOn: Binding(get: { synced }, set: { setSynced($0) })) {
                    Label("Same for closing and opening", systemImage: "link")
                }
            } header: {
                Text("Following the lid")
            } footer: {
                Footnote(synced ? "Both ways use the same settings below. Turn this off to set closing and opening apart."
                         : "Closing and opening are set apart. Turning this back on applies the tab you're on to both.")
            }
            Section {
                LabeledContent {
                    Slider(value: index, in: 0...Double(Self.percents.count - 1), step: 1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Responsive").font(.caption)
                    } maximumValueLabel: {
                        Text("Smooth").font(.caption)
                    }
                    .frame(maxWidth: 320)
                } label: {
                    Text("Motion smoothing")
                    Text(percent == 0 ? "0%: the raw sensor, 10 steps per second"
                         : String(format: "%.0f%%", percent) + (percent == 100 ? " (default)" : ""))
                }
            } footer: {
                Footnote("The sensor reports the angle 10 times per second. Lower smoothing follows it more directly; higher glides but lags behind the lid.")
            }
            Section {
                LabeledContent {
                    Slider(value: Binding(get: { look }, set: { UserDefaults.standard.set($0, forKey: key("lookAhead")) }),
                           in: 0...1, step: 0.25) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Off").font(.caption)
                    } maximumValueLabel: {
                        Text("Full").font(.caption)
                    }
                    .frame(maxWidth: 320)
                } label: {
                    Text("Prediction")
                    Text(look == 0 ? "Off (default)" : String(format: "%.0f%%", look * 100))
                }
            } footer: {
                Footnote("Guesses where the lid is from its speed, so the picture keeps up with it instead of trailing about a tenth of a second behind. It eases off as the lid slows down; a lid stopped dead can overshoot slightly.")
            }
            Section {
                LabeledContent {
                    Slider(value: Binding(get: { ahead }, set: { UserDefaults.standard.set($0, forKey: key("closingAhead")) }),
                           in: 0...1, step: 0.25) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Off").font(.caption)
                    } maximumValueLabel: {
                        Text("Full").font(.caption)
                    }
                    .frame(maxWidth: 320)
                } label: {
                    Text("Ahead")
                    Text(ahead == 0 ? "Off (default)" : String(format: "%.0f%%", ahead * 100))
                }
            } footer: {
                Footnote(synced || tab == 1
                         ? "The picture runs slightly ahead of the lid instead of behind, even with Prediction off. When an opening stops, the picture settles from slightly squashed into place, like when closing, instead of shrinking back from stretched."
                         : "The picture runs slightly ahead of the lid while it closes, even with Prediction off. Closing already settles naturally, from slightly squashed into place; running ahead, it settles from stretched instead.")
            }
        }
    }
}

// MARK: - Snap-back

private struct SnapBackPane: View {
    @ObservedObject var model: SettingsModel
    @State private var showingCorners = false               // the corner outline on the screen (CornerGuide)

    var body: some View {
        let tapOn = model.hapticAvailable && Settings.snapHaptic
        let animation = Settings.snapAnimationKind
        let matching = Settings.snapAnimation == SnapAnimation.matchStyle
        let level = Binding<HapticLevel>(
            get: { .current },
            set: { UserDefaults.standard.set($0.rawValue, forKey: "snapHapticLevel"); model.actions.tap($0) })   // plays once
        Form {
            Section {
                Toggle(isOn: model.flag("snapSound") { if $0 { model.actions.playSound() } }) {
                    Text("Click sound")
                    Text("Plays the moment the screen snaps back after you reopen the lid")
                }
                SliderRow(model: model, row: volumeRow)
                    .disabled(!Settings.snapSound)
                LabeledContent {
                    HStack {
                        Button("Choose…", action: model.actions.chooseSound)
                        if model.customSound { Button("Use Default", action: model.actions.defaultSound) }
                    }
                } label: {
                    Text("Sound")
                    Text(model.customSound ? "Your sound, cut to where it starts" : "The NUEM click")
                }
                .disabled(!Settings.snapSound)
                HStack {
                    Spacer()
                    Button("Play Sound", action: model.actions.playSound)
                        .disabled(!Settings.snapSound)
                }
            }
            Section {
                Toggle(isOn: model.flag("snapHaptic")) {
                    Text("Trackpad tap")
                    Text(model.hapticAvailable ? "A tap from the Force Touch trackpad at the same moment" : "Not available on this Mac")
                }
                .disabled(!model.hapticAvailable)
                Picker(selection: level) {
                    ForEach(HapticLevel.allCases, id: \.self) { Text($0.name).tag($0) }
                } label: {
                    Text("Strength")
                    Text(HapticLevel.current.detail)
                }
                .pickerStyle(.segmented)
                .disabled(!tapOn)
                HStack {
                    Spacer()
                    Button("Test Tap") { model.actions.tap(.current) }
                        .disabled(!tapOn)
                }
            } footer: {
                Footnote("You feel it best with a hand on the trackpad or the palm rest.")
            }
            Section {
                Picker("Snap animation", selection: Binding(get: { Settings.snapAnimation },
                                                            set: { UserDefaults.standard.set($0, forKey: "snapAnimation") })) {
                    Text("None").tag(0)
                    Text("Match the fold style").tag(SnapAnimation.matchStyle)
                    Divider()
                    ForEach([SnapAnimation.edgeGlow, .frostedGlow, .particleBurst, .crtGlow, .invertedGlow, .hologramGlow], id: \.self) {
                        Text($0.name).tag($0.rawValue)
                    }
                }
                .pickerStyle(.menu)
                if animation != .none {
                    SliderRow(model: model, row: snapOpacityRow)
                    if matching && Settings.foldStyleHasColor {
                        ColorRow(model: model, key: "snapColor", title: "Color", note: "The fold style's color")
                            .disabled(true)
                    } else if animation.usesSnapColor {
                        ColorRow(model: model, key: "snapColor", title: "Color")
                    }
                    Toggle(isOn: model.flag("snapCornersManual")) {
                        Text("Set the corners by hand")
                        Text("macOS doesn't say how round the screen's corners are, so the glow uses 10 points. Match yours here.")
                    }
                    if Settings.snapCornersManual {
                        SliderRow(model: model, row: cornerTopRow)
                        SliderRow(model: model, row: cornerBottomRow)
                        Toggle(isOn: $showingCorners) {
                            Text("Show the outline")
                            Text("Draws the corners on the screen while you adjust them: the line should just follow the screen's own curve.")
                        }
                        .onChange(of: showingCorners) { _, on in CornerGuide.shared.show(on) }
                        .onAppear { if showingCorners { CornerGuide.shared.show(true) } }
                        .onDisappear { CornerGuide.shared.show(false) }
                    }
                }
            } footer: {
                Footnote((matching ? "With this fold style: \(animation.name). " : "") + animation.detail
                         + " Preview Effect in the menu shows it.")
            }
            Section("Hinge notches") {
                let notches = Settings.detents
                let trackpad = Binding<Int>(
                    get: { !Settings.detentHaptic ? 0 : Settings.detentStrong ? 2 : 1 },
                    set: {
                        UserDefaults.standard.set($0 > 0, forKey: "detentHaptic")
                        if $0 > 0 { UserDefaults.standard.set($0 == 2, forKey: "detentStrong") }
                        model.actions.notch()
                    })
                Toggle(isOn: model.flag("detents") { if $0 { model.actions.notch() } }) {
                    Text("Hinge notches")
                    Text("A notch every few degrees while the fold plays, like a hinge: a click you hear, and feel on the trackpad")
                }
                SliderRow(model: model, row: notchRow)
                    .disabled(!notches)
                Toggle(isOn: model.flag("detentSound") { if $0 { model.actions.notch() } }) {
                    Text("Sound")
                    Text("The hinge click, a little quieter than the snap click")
                }
                .disabled(!notches)
                SliderRow(model: model, row: notchVolumeRow)
                    .disabled(!notches || !Settings.detentSound)
                Picker(selection: trackpad) {
                    Text("Off").tag(0)
                    Text("Light").tag(1)
                    Text("Strong").tag(2)
                } label: {
                    Text("Trackpad")
                    if !model.hapticAvailable { Text("Not available on this Mac") }
                }
                .pickerStyle(.segmented)
                .disabled(!notches || !model.hapticAvailable)
            }
            Section {
                SliderRow(model: model, row: depthRow)
            }
        }
    }
}

// MARK: - About

private struct Credit: Identifiable {
    let what: String, who: String, url: String
    var id: String { what }
}

/// Code NUEM is based on (its license notice is in THIRD_PARTY_NOTICES.md).
private let basedOn = [
    Credit(what: "Content darkening, fixed-eye idea", who: "chuspeeism/iphone-duo", url: "https://github.com/chuspeeism/iphone-duo"),
]

/// Research NUEM relies on. None of their code is included.
private let thanks = [
    Credit(what: "Lid sensor protocol", who: "samhenrigold/LidAngleSensor", url: "https://github.com/samhenrigold/LidAngleSensor"),
    Credit(what: "Trackpad actuator calls", who: "niw/HapticKey", url: "https://github.com/niw/HapticKey"),
    Credit(what: "Single-use actuator handles", who: "MatMercer/mactic", url: "https://github.com/MatMercer/mactic"),
]

// About NUEM, by TGTools123.
private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    private func rows(_ credits: [Credit]) -> some View {
        ForEach(credits) { credit in
            LabeledContent(credit.what) {
                Link(credit.who, destination: URL(string: credit.url)!)
            }
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("NUEM")
                        .font(.title.weight(.semibold))
                        .overlay(Text(Links.author).font(.system(size: 1)).opacity(0).accessibilityHidden(true))
                    Text("A fold animation for your MacBook, inspired by the iPhone Duo.")
                        .foregroundStyle(.secondary)
                    Text("By \(Links.author)")
                        .font(.callout.weight(.medium))
                        .help("\(Links.author), GitHub account \(Links.authorGitHubID)")
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent {
                    Button { NSWorkspace.shared.open(Links.sponsor) } label: {
                        Label("Support on Ko-fi", systemImage: "heart.fill")
                    }
                    .prominentButtonStyle()
                    .tint(.pink)
                } label: {
                    Text("Support NUEM")
                    Text("NUEM is free and open source. A tip on Ko-fi keeps it that way.")
                }
                LabeledContent {
                    HStack {
                        Button("GitHub Sponsors") { NSWorkspace.shared.open(Links.githubSponsors) }
                        Button("Profile") { NSWorkspace.shared.open(Links.profile) }
                    }
                } label: {
                    Text("Sponsor on GitHub")
                    Text("(GitHub may not have approved Sponsors for this account yet. Visit the profile in the meantime.)")
                }
                LabeledContent {
                    Button("Open on GitHub") { NSWorkspace.shared.open(Links.repository) }
                } label: {
                    Text("Source code")
                    Text("GNU General Public License v3.0")
                }
                LabeledContent {
                    Button("View License") { NSWorkspace.shared.open(Links.license) }
                } label: {
                    Text("License")
                    Text("Copyright © 2026 \(Links.author). NUEM comes with absolutely no warranty. It's free software: you can redistribute it under the GNU General Public License v3, keeping the attribution in NOTICE.")
                }
            }
            Section {
                rows(basedOn)
            } header: {
                Text("Based on")
            } footer: {
                Footnote("The darkening is translated from its shader, under the MIT License.")
            }
            Section {
                rows(thanks)
            } header: {
                Text("Thanks to")
            } footer: {
                Footnote("Their research made NUEM possible. None of their code is included.")
            }
            Section {
                Text("iPhone, iPhone Duo, MacBook and MacBook Pro are trademarks of Apple Inc. NUEM is an independent project, not affiliated with or endorsed by Apple.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26 (when built with its SDK), the classic prominent button before.
    @ViewBuilder func prominentButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
        #else
        buttonStyle(.borderedProminent)
        #endif
    }
}
