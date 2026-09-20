// Copyright © 2026 TGTools123. NUEM, GNU GPL v3.
// Modified 2026-09-20 for NUEM-Essential: minimal controls and optional menu bar icon.
import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sensor = LidSensor()
    private let adaptive = AdaptiveAngle()
    private var overlay: FoldOverlay?
    private var signature = ""
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var controls: [String: NSButton] = [:]
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var status = "Idle" { didSet { if status != oldValue { refreshControls() } } }
    private var timer: Timer?
    private var previewTimer: Timer?
    private var pollHz: Double = 0
    private var lastAngle: Double?
    private var enabled: Bool { Settings.effectEnabled }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = Bundle.main.image(forResource: "MenuBarIconTemplate") ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "NUEM Essential")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("NUEM Essential")
        statusItem.menu = makeMenu()
        statusItem.isVisible = UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit NUEM Essential", action: #selector(quit), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu
        let mainMenu = NSMenu(); mainMenu.addItem(item); NSApp.mainMenu = mainMenu
        screensChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(suspend), name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        if sensor.isAvailable { setPolling(15) }
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { suspend() }
    func menuWillOpen(_ menu: NSMenu) { refreshControls() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        for (title, action, key) in [("Settings…", #selector(showSettings), ","), ("Preview Effect", #selector(preview), "p"), ("About NUEM Essential", #selector(about), ""), ("Quit NUEM Essential", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        return menu
    }

    @objc private func screensChanged() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let mirrored = ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsInMirrorSet($0) != 0 }
        let screen = mirrored ? nil : NSScreen.screens.first(where: \.isBuiltin)
        let next = screen.map { "\($0.displayID) \($0.frame) \($0.backingScaleFactor)" } ?? ""
        guard next != signature || overlay == nil else { return }
        suspend()
        signature = next
        overlay = screen.flatMap(FoldOverlay.init)
        overlay?.reference = { [weak self] angle in
            guard let self, previewTimer == nil else { return angle }
            return adaptive.reference(angle, at: CACurrentMediaTime())
        }
        overlay?.onStateChange = { [weak self] in self?.status = $0 }
        status = mirrored ? "Unavailable while mirroring" : overlay == nil ? "Built-in display or Metal unavailable" : "Idle"
    }

    @objc private func suspend() {
        previewTimer?.invalidate(); previewTimer = nil
        overlay?.stop()
    }

    private func setPolling(_ hz: Double) {
        guard hz != pollHz else { return }
        pollHz = hz
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / hz, target: self, selector: #selector(readSensor), userInfo: nil, repeats: true)
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func readSensor() {
        guard let angle = sensor.read(), angle.isFinite, (0...360).contains(angle) else { return }
        lastAngle = angle
        let now = CACurrentMediaTime()
        adaptive.observe(CGFloat(angle), at: now, effectVisible: overlay?.isBusy == true, paused: previewTimer != nil)
        if enabled, previewTimer == nil { overlay?.update(angle: CGFloat(angle)) }
        let start = Double(adaptive.start(at: now))
        setPolling(!enabled || angle > start + 20 ? 15 : Double(min(120, max(30, overlay?.screen.maximumFramesPerSecond ?? 60))))
    }

    @objc private func preview() {
        guard let overlay, previewTimer == nil else { return }
        overlay.stop()
        let began = CACurrentMediaTime(), start = Settings.startAngle
        overlay.update(angle: start + 2)
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = (CACurrentMediaTime() - began) / 6
                guard progress < 1.2 else { self.suspend(); return }
                let angle = progress >= 1 ? start + 2 : start * CGFloat(0.5 * (1 + cos(progress * 2 * .pi)))
                self.overlay?.update(angle: angle)
            }
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 335), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "NUEM Essential"
            window.isReleasedWhenClosed = false
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
            for (key, title) in [("effectEnabled", "Enable fold effect"), ("adaptiveAngle", "Adjust to my resting lid angle"), ("cursorFade", "Fade the pointer during the fold"), ("showMenuBarIcon", "Show menu bar icon"), ("openAtLogin", "Open at login")] {
                let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggle(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(key)
                controls[key] = button; stack.addArrangedSubview(button)
            }
            let hint = NSTextField(wrappingLabelWithString: "Icon hidden? Open NUEM Essential again from Spotlight or Applications to return here.")
            hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(hint)
            stack.addArrangedSubview(statusLabel)
            let actions = NSStackView(); actions.spacing = 12
            actions.addArrangedSubview(NSButton(title: "Preview Effect", target: self, action: #selector(preview)))
            actions.addArrangedSubview(NSButton(title: "Screen Recording…", target: self, action: #selector(allowCapture)))
            stack.addArrangedSubview(actions)
            let legal = NSTextField(labelWithString: "By TGTools123 · Essential fork · GNU GPL v3")
            legal.font = .systemFont(ofSize: 11); legal.textColor = .secondaryLabelColor
            stack.addArrangedSubview(legal)
            settingsWindow = window
            window.center()
        }
        refreshControls()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if key == "openAtLogin" {
            do {
                if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch { NSAlert(error: error).runModal() }
        } else {
            UserDefaults.standard.set(sender.state == .on, forKey: key)
        }
        applySettings()
    }

    private func applySettings() {
        let visible = UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        if statusItem?.isVisible != visible { statusItem?.isVisible = visible }
        if !enabled { suspend() }
        refreshControls()
    }

    private func refreshControls() {
        for (key, button) in controls {
            let on = key == "openAtLogin" ? SMAppService.mainApp.status == .enabled : UserDefaults.standard.bool(forKey: key)
            button.state = on ? .on : .off
        }
        statusLabel.stringValue = !CGPreflightScreenCaptureAccess() ? "Screen Recording permission needed." : !sensor.isAvailable ? "No lid angle sensor. Preview is available." : !enabled ? "Effect disabled." : status
    }

    @objc private func allowCapture() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NUEM Essential", .credits: NSAttributedString(string: "By TGTools123\nEssential fork of tgtools123/NUEM.\nGNU GPL v3. License and notices are included in the app bundle.")])
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

#if !TESTING
@main
struct EssentialApp {
    @MainActor static func main() {
        Settings.register()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
