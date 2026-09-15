// NUEM by TGTools123 (GitHub account 272741180). Copyright © 2026 TGTools123, licensed under the GNU GPL v3 (see LICENSE
// and NOTICE).

import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sensor = LidSensor()
    private let curves = Curves()
    private let feedback = SnapFeedback()
    private let adaptive = AdaptiveAngle()
    private var overlay: FoldOverlay?
    private var overlaySignature = ""
    private var effectState: EffectState = .idle
    private var curveWindow: CurveWindowController?
    private var keyframesWindow: KeyframesWindowController?
    private let keyboard = KeyboardBacklight()
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private let live = LiveLid()

    private var statusItem: NSStatusItem!
    private let angleItem = NSMenuItem(title: "Lid angle: —", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Allow Screen Recording…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enable Effect", action: #selector(toggleEffect), keyEquivalent: "e")
    private let lookMenu = NSMenu(title: "Look")

    /// Template image: macOS draws it in the menu bar's own color (dark on a light menu bar, light on a dark one,
    /// inverted when selected), like the system's menu bar icons.
    private lazy var menuBarIcon: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuBarIconTemplate") ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "NUEM"
        return image
    }()
    private var showsAngleInMenuBar: Bool { UserDefaults.standard.string(forKey: "menuBarStyle") == "angle" }
    /// Fixed width for the angle, so the menu bar doesn't re-layout every time a digit changes.
    private lazy var angleWidth: CGFloat = {
        let font = statusItem.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        return ceil(("188°" as NSString).size(withAttributes: [.font: font]).width) + 10
    }()

    // Floating angle display: also a way to reach the menu when the notch hides the menu bar icon.
    private var hud: NSPanel?
    private let hudAngle = NSTextField(labelWithString: "—")
    private let hudInfo = NSTextField(labelWithString: "")

    private var timer: Timer?
    private var pollHz: Double = 0
    private var lastAngle: Double?
    private var lastTime = CACurrentMediaTime()
    private var speed = 0.0                      // °/s, smoothed, negative while closing
    private var lastUIUpdate: CFTimeInterval = 0
    private var simulating = false
    private var lastTuning: [Double] = []        // look settings at the last UserDefaults change
    private var lastEffectEnabled = true
    private var lastLockScreen = Settings.lockScreen
    private var lastExternalSwitch: CFTimeInterval = 0

    private var effectEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "effectEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "effectEnabled") }
    }
    private var hudEnabled: Bool { UserDefaults.standard.bool(forKey: "showHUD") }
    private var tuning: [Double] { Settings.lookKeys.map { UserDefaults.standard.double(forKey: $0) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.menu = makeMenu()
        installMainMenu()
        applyAppearance()
        updateStatusButton()

        ExternalDisplays.restore(force: true)      // switched off by a NUEM that couldn't switch them back on
        screensChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        lastTuning = tuning
        lastEffectEnabled = effectEnabled
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        // First launch: macOS shows its Screen Recording prompt (needed for the snapshot).
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if hudEnabled { showHUD() }
        refreshMenu()
        if sensor.isAvailable { setPolling(hz: 15) }
    }

    /// Opening the app again while it runs shows Settings (the notch can hide the menu bar icon).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// A double-clicked .nuemlook file: add it to the user's looks and apply it.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(importLook(from:))
    }

    /// Every change to a setting — from the Settings window, the menu or `defaults write` — lands here.
    @objc private func defaultsChanged() {
        let tuning = self.tuning
        if tuning != lastTuning {
            lastTuning = tuning
            curves.reloadAll()                   // curve anchors and formulas depend on the look settings
            curveWindow?.view.needsDisplay = true
        }
        if effectEnabled != lastEffectEnabled {
            lastEffectEnabled = effectEnabled
            if !effectEnabled { overlay?.stop() }
        }
        if Settings.lockScreen != lastLockScreen {
            lastLockScreen = Settings.lockScreen
            overlaySignature = ""                  // the window goes above the lock screen when it's created
            screensChanged()
        }
        if hudEnabled {
            if hud?.isVisible != true { showHUD() }
        } else {
            hud?.orderOut(nil)
        }
        applyAppearance()
        updateStatusButton()
        refreshMenu()
        settingsModel?.changed()
    }

    // MARK: Menu bar

    /// System, Light or Dark for NUEM's own windows, menu, HUD and alerts.
    private func applyAppearance() {
        let name: NSAppearance.Name?
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": name = .aqua
        case "dark": name = .darkAqua
        default: name = nil
        }
        guard NSApp.appearance?.name != name else { return }
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
    }

    /// The icon, or the live lid angle as plain button text. Both follow the menu bar's appearance.
    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        if showsAngleInMenuBar, sensor.isAvailable {
            button.image = nil
            button.title = lastAngle.map { String(format: "%.0f°", $0) } ?? "—°"
            statusItem.length = angleWidth
        } else {
            button.title = ""
            button.image = sensor.isAvailable ? menuBarIcon
                : NSImage(systemSymbolName: "laptopcomputer.trianglebadge.exclamationmark", accessibilityDescription: "Lid angle sensor not found")
            statusItem.length = NSStatusItem.variableLength
        }
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        angleItem.isEnabled = false
        stateItem.isEnabled = false
        let lookItem = NSMenuItem(title: "Look", action: nil, keyEquivalent: "")
        lookItem.submenu = lookMenu
        lookMenu.delegate = self
        let items: [NSMenuItem] = [
            angleItem, stateItem, permissionItem, .separator(),
            enabledItem,
            NSMenuItem(title: "Preview Effect", action: #selector(preview), keyEquivalent: "p"),
            lookItem,
            NSMenuItem(title: "Tuning Curves…", action: #selector(showCurves), keyEquivalent: "t"),
            NSMenuItem(title: "Keyframes…", action: #selector(showKeyframes), keyEquivalent: "k"),
            .separator(),
            NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","),
            NSMenuItem(title: "Support NUEM…", action: #selector(openSponsorPage), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit NUEM", action: #selector(quit), keyEquivalent: "q"),
        ]
        for item in items {
            if item.action != nil { item.target = self }
            menu.addItem(item)
        }
        return menu
    }

    /// A menu bar app has no visible main menu, but its shortcuts still work while a window is key: ⌘, opens
    /// Settings, ⌘W closes the window, ⌘Q quits.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit NUEM", action: #selector(quit), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === lookMenu { rebuildLookMenu() }
    }

    private var statusText: String {
        guard sensor.isAvailable else { return "Lid angle sensor not found" }
        return "Effect: " + (effectEnabled ? effectState.rawValue : "Off")
    }

    private func refreshMenu() {
        stateItem.title = sensor.isAvailable ? statusText : "Lid angle sensor not found — this Mac isn't supported"
        permissionItem.isHidden = CGPreflightScreenCaptureAccess()
        enabledItem.state = effectEnabled ? .on : .off
        live.status = statusText
    }

    /// Bundled looks, then the user's; a check mark on the one matching the current tuning.
    private func rebuildLookMenu() {
        lookMenu.removeAllItems()
        var items: [NSMenuItem] = [], anyMatch = false
        let presets = LookLibrary.presets, saved = LookLibrary.saved
        for url in presets + saved {
            guard let look = try? LookLibrary.load(url) else { continue }
            if url == saved.first, !items.isEmpty { items.append(.separator()) }
            let item = NSMenuItem(title: look.name, action: #selector(chooseLook(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            if !anyMatch, LookLibrary.matches(look, curves: curves) { item.state = .on; anyMatch = true }
            items.append(item)
        }
        if !anyMatch {
            let custom = NSMenuItem(title: "Custom (not saved)", action: nil, keyEquivalent: "")
            custom.state = .on
            items.insert(contentsOf: [custom, .separator()], at: 0)
        }
        items += [.separator(),
                  NSMenuItem(title: "Save Current Look…", action: #selector(saveLook), keyEquivalent: ""),
                  NSMenuItem(title: "Import Look…", action: #selector(importLookPanel), keyEquivalent: ""),
                  NSMenuItem(title: "Show Looks Folder", action: #selector(showLooksFolder), keyEquivalent: "")]
        for item in items {
            if item.action != nil { item.target = self }
            lookMenu.addItem(item)
        }
    }

    // MARK: Sensor

    /// 15 Hz with the lid wide open, 120 Hz while moving or near the effect zone, 30 Hz otherwise.
    private func setPolling(hz: Double) {
        guard hz != pollHz else { return }
        pollHz = hz
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // Each sensor reading. NUEM by TGTools123.
    private func tick() {
        guard let angle = sensor.read() else { return }
        let now = CACurrentMediaTime()
        if let last = lastAngle, now > lastTime { speed = 0.25 * (angle - last) / (now - lastTime) + 0.75 * speed }
        lastAngle = angle
        lastTime = now
        adaptive.observe(CGFloat(angle), at: now, effectVisible: overlay?.isVisible == true,
                         paused: simulating || curveWindow?.window.isVisible == true || keyframesWindow?.window?.isVisible == true)
        if effectEnabled, !simulating { overlay?.update(angle: CGFloat(angle)) }
        if !simulating { externalDisplays(angle: angle, now: now) }
        let start = Double(adaptive.start(at: now))
        keyboard.update(angle: CGFloat(angle), start: CGFloat(start), active: effectEnabled && !simulating && overlay?.isBusy == true)
        setPolling(hz: angle > start + 20 ? 15 : (abs(speed) > 3 || angle < start + 3) ? 120 : 30)
        // The audio output, kept running while a fold may come (SnapFeedback.warm) — waking from sleep included.
        if effectEnabled, !simulating, angle < start + 25, abs(speed) > 3 { feedback.warm() }

        // Text updates at 15 Hz only: AppKit text layout at 120 Hz would load the main thread mid-effect.
        guard now - lastUIUpdate > 1.0 / 15 else { return }
        lastUIUpdate = now
        angleItem.title = String(format: "Lid angle: %.1f°", angle)
        if showsAngleInMenuBar, let button = statusItem.button {
            let title = String(format: "%.0f°", angle)
            if button.title != title { button.title = title }
        }
        if hud?.isVisible == true {
            hudAngle.stringValue = String(format: "%.1f°", angle)
            hudInfo.stringValue = String(format: "%+.0f°/s · %@", speed, effectEnabled ? effectState.rawValue : "Off")
        }
        if settingsWindow?.isVisible == true {
            live.angle = angle
            live.start = Double(adaptive.start(at: now))
            live.viewingAngle = adaptive.viewingAngle.map(Double.init)
        }
        if keyframesWindow?.window?.isVisible == true {
            KeyframeStore.shared.liveAngle = angle
            KeyframeStore.shared.start = start
        }
        if overlay?.isVisible != true {
            curveWindow?.view.liveAngle = min(Settings.startAngle, adaptive.reference(CGFloat(angle), at: now))
        }
    }

    // MARK: Overlay

    /// (Re)creates the overlay when the built-in display appears, disappears or changes resolution.
    @objc private func screensChanged() {
        // Mirrored, the built-in display shows exactly what another display shows: the effect would be on both, so it
        // stays off until mirroring stops.
        let mirrored = Self.builtinDisplayID().map { CGDisplayIsInMirrorSet($0) != 0 } ?? false
        let builtin = mirrored ? nil : NSScreen.screens.first(where: \.isBuiltin)
        let signature = mirrored ? "mirrored" : builtin.map(FoldOverlay.signature(of:)) ?? ""
        guard signature != overlaySignature || (overlay == nil && builtin != nil) else { return }
        overlay?.stop()
        overlay = nil
        overlaySignature = signature
        if let builtin, let overlay = FoldOverlay(screen: builtin, curves: curves) {
            overlay.onStateChange = { [weak self] state in
                guard let self else { return }
                self.effectState = state
                self.refreshMenu()
                if state == .capturing || state == .ready { self.feedback.prepare() }    // before the fold shows
                if state == .active {
                    self.feedback.prepare()                                        // ready for the snap (done already, mostly)
                    if self.hudEnabled { self.hud?.orderFrontRegardless() }        // stay above the overlay
                }
            }
            overlay.onAngle = { [weak self] angle in self?.curveWindow?.view.liveAngle = angle }
            overlay.onSnap = { [weak self] _ in self?.feedback.snap() }
            overlay.onNotch = { [weak self] in self?.feedback.notch() }
            overlay.isTuning = { [weak self] in self?.curveWindow?.window.isVisible == true || self?.keyframesWindow?.window?.isVisible == true }
            overlay.reference = { [weak self] angle in
                guard let self, !self.simulating else { return angle }            // the preview plays tuning angles
                return self.adaptive.reference(angle, at: CACurrentMediaTime())
            }
            overlay.lidStart = { [weak self] in
                guard let self, !self.simulating else { return Settings.startAngle }
                return self.adaptive.start(at: CACurrentMediaTime())
            }
            overlay.lidRotation = { [weak self] angle in
                guard let self, !self.simulating else { return Settings.startAngle - angle }
                return self.adaptive.lidRotation(angle, at: CACurrentMediaTime())
            }
            self.overlay = overlay
        }
        effectState = overlay != nil ? .idle : mirrored ? .mirrored : .noDisplay
        refreshMenu()
    }

    /// The built-in display among the online ones (a mirrored display isn't always in NSScreen.screens).
    private static func builtinDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: Actions

    /// Plays startAngle → 0° → startAngle over 6 s, without touching the lid.
    @objc private func preview() {
        guard let overlay, !simulating else { return }
        simulating = true
        let start = Settings.startAngle, began = CACurrentMediaTime()
        overlay.update(angle: start + 2)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let u = (CACurrentMediaTime() - began) / 6
            if u >= 1.2 {
                timer.invalidate()
                self.simulating = false
                return
            }
            let angle = u >= 1 ? start + 2 : start * CGFloat(0.5 * (1 + cos(u * 2 * .pi)))
            self.overlay?.update(angle: angle)
        }
    }

    @objc private func toggleEffect() { effectEnabled.toggle() }          // defaultsChanged does the rest

    @objc private func showCurves() {
        if curveWindow == nil { curveWindow = CurveWindowController(curves: curves) }
        curveWindow?.show()
    }

    @objc private func showKeyframes() {
        if keyframesWindow == nil { keyframesWindow = KeyframesWindowController() }
        keyframesWindow?.show()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                preview: { [weak self] in self?.preview() },
                showCurves: { [weak self] in self?.showCurves() },
                allowScreenRecording: { [weak self] in self?.openScreenRecordingSettings() },
                toggleOpenAtLogin: { [weak self] in self?.toggleLogin() },
                playSound: { [weak self] in self?.feedback.playSound() },
                tap: { [weak self] level in self?.feedback.tap(level) },
                applyLook: { [weak self] url in self?.applyLook(from: url) },
                saveLook: { [weak self] in self?.saveLook() },
                importLook: { [weak self] in self?.importLookPanel() },
                showLooksFolder: { [weak self] in self?.showLooksFolder() },
                resetAll: { [weak self] in self?.resetSettings() },
                setStayAwake: { [weak self] on in self?.setStayAwake(on) },
                chooseSound: { [weak self] in self?.chooseSound() },
                defaultSound: { [weak self] in self?.useDefaultSound() },
                notch: { [weak self] in self?.feedback.notch() })
            let model = SettingsModel(curves: curves, actions: actions,
                                      sensorAvailable: sensor.isAvailable, hapticAvailable: feedback.hapticAvailable)
            settingsModel = model
            settingsWindow = MainActor.assumeIsolated { makeSettingsWindow(model: model, live: live) }   // AppKit calls this on the main thread
        }
        live.angle = lastAngle
        live.start = Double(adaptive.start(at: CACurrentMediaTime()))
        live.viewingAngle = adaptive.viewingAngle.map(Double.init)
        settingsModel?.reloadLooks()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSponsorPage() { NSWorkspace.shared.open(Links.sponsor) }

    /// Imports an audio file as the snap sound (cut to where it starts) and plays it once.
    private func chooseSound() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a sound for the snap-back. It's cut to where the sound starts, 2 seconds at most."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CustomSound.importSound(from: url)
            feedback.reloadSound()
            feedback.playSound()
        } catch {
            showError(error)
        }
        settingsModel?.changed()
    }

    private func useDefaultSound() {
        CustomSound.remove()
        feedback.reloadSound()
        feedback.playSound()
        settingsModel?.changed()
    }

    /// Turning it on is confirmed first: it's a system setting with real consequences (StayAwake.swift).
    private func setStayAwake(_ on: Bool) {
        if on {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Keep your Mac awake with the lid closed?"
            alert.informativeText = "Closing the lid won't put your Mac to sleep anymore, so opening it only waits for the display. It uses the battery while the lid is closed, and your Mac stays awake in a bag, where it can get warm. It's a system setting: it stays on if you quit NUEM, until you turn it off here. macOS asks for an administrator password."
            alert.addButton(withTitle: "Keep Awake")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        StayAwake.set(on)
    }

    private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            logger.error("Login item: \(String(describing: error), privacy: .public)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func resetSettings() {
        Settings.reset()
        curves.reloadAll()                       // the curves' points are reset too, even if no setting moved
        curveWindow?.view.needsDisplay = true
        defaultsChanged()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        ExternalDisplays.restore(force: true)      // never leave a display switched off behind
    }

    /// Settings → General → Turn off external displays with the lid: switched off just before the lid closes (the
    /// fold is black by then), back on once the lid is open again and the fold is done (ExternalDisplays.swift).
    private func externalDisplays(angle: Double, now: CFTimeInterval) {
        if ExternalDisplays.areOff {
            // Back on at the snap, with the real screen — one change, not a second one after the animation.
            if !Settings.externalOffWhenClosed || !effectEnabled || (angle > 20 && overlay?.isFolding != true) {
                ExternalDisplays.restore()
            }
        } else if Settings.externalOffWhenClosed, effectEnabled, overlay != nil, angle < 12, speed < -2,
                  now - lastExternalSwitch > 3, !ExternalDisplays.connected.isEmpty {
            lastExternalSwitch = now
            ExternalDisplays.switchOff()
        }
    }

    // MARK: Looks

    @objc private func chooseLook(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        applyLook(from: url)
    }

    private func applyLook(from url: URL) {
        do {
            let look = try LookLibrary.load(url)
            guard confirmReplacingTuning(with: look.name) else { return }
            LookLibrary.apply(look, to: curves)
            curveWindow?.view.needsDisplay = true
            settingsModel?.changed()
        } catch {
            showError(error)
        }
    }

    /// Asks before overwriting a tuning that isn't saved as any look.
    private func confirmReplacingTuning(with name: String) -> Bool {
        let known = (LookLibrary.presets + LookLibrary.saved).compactMap { try? LookLibrary.load($0) }
        guard !known.contains(where: { LookLibrary.matches($0, curves: curves) }) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Apply “\(name)”?"
        alert.informativeText = "Your current tuning isn't saved as a look and will be replaced. To keep it, choose Save Current Look… first."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func saveLook() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.nuemLook]
        panel.directoryURL = LookLibrary.userFolder
        panel.nameFieldStringValue = "My Look.\(LookLibrary.fileExtension)"
        panel.message = "Looks saved in this folder appear in the Look menu. Send the file to share the look."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LookLibrary.save(LookLibrary.current(named: url.deletingPathExtension().lastPathComponent, curves: curves), to: url)
        } catch {
            showError(error)
        }
    }

    @objc private func importLookPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.nuemLook, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLook(from: url)
    }

    private func importLook(from url: URL) {
        do {
            applyLook(from: try LookLibrary.importCopy(of: url))
            settingsModel?.reloadLooks()
        } catch {
            showError(error)
        }
    }

    @objc private func showLooksFolder() { NSWorkspace.shared.open(LookLibrary.userFolder) }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }

    // MARK: HUD

    private func showHUD() {
        if hud == nil { hud = makeHUD() }
        hud?.orderFrontRegardless()
    }

    private func makeHUD() -> NSPanel {
        let size = NSSize(width: 220, height: 84)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let (background, box) = hudBackground(size: size)
        panel.contentView = background

        hudAngle.font = NSFont.monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        hudAngle.alignment = .center
        hudAngle.frame = NSRect(x: 0, y: 30, width: size.width, height: 46)
        hudInfo.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hudInfo.alignment = .center
        hudInfo.textColor = .secondaryLabelColor
        hudInfo.frame = NSRect(x: 0, y: 10, width: size.width, height: 16)
        box.addSubview(hudAngle)
        box.addSubview(hudInfo)
        background.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(preview)))   // click = preview
        background.menu = statusItem.menu                                                                    // right-click = menu
        background.toolTip = "Click to preview the effect · right-click for the menu · drag to move"

        if let screen = NSScreen.screens.first(where: \.isBuiltin) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16))
        }
        return panel
    }

    /// Liquid Glass on macOS 26 (when built with its SDK), the HUD material before.
    private func hudBackground(size: NSSize) -> (NSView, NSView) {
        let frame = NSRect(origin: .zero, size: size)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = 16
            let content = NSView(frame: frame)
            glass.contentView = content
            return (glass, content)
        }
        #endif
        let box = NSVisualEffectView(frame: frame)
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.masksToBounds = true
        return (box, box)
    }
}

Settings.register()                     // before anything reads a setting
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
app.run()
