// Copyright © 2026 TGTools123. Part of NUEM (GNU GPL v3).
// The corner outline (Settings → Snap-Back → Show the outline): a thin line around the built-in screen with the
// corner radii set by hand, to match them to the screen's own curve.

import Cocoa

final class CornerGuide {
    static let shared = CornerGuide()
    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    func show(_ on: Bool) {
        guard on else {
            window?.orderOut(nil)
            window = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            return
        }
        guard window == nil, let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver                          // over the menu bar: the top corners are up there
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = GuideView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.window?.contentView?.needsDisplay = true
        }
    }
}

// The outline, by TGTools123.
private final class GuideView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let (top, bottom) = Settings.snapCorners
        let b = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX + bottom, y: b.minY))
        path.line(to: NSPoint(x: b.maxX - bottom, y: b.minY))
        path.appendArc(withCenter: NSPoint(x: b.maxX - bottom, y: b.minY + bottom), radius: bottom, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: b.maxX, y: b.maxY - top))
        path.appendArc(withCenter: NSPoint(x: b.maxX - top, y: b.maxY - top), radius: top, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: b.minX + top, y: b.maxY))
        path.appendArc(withCenter: NSPoint(x: b.minX + top, y: b.maxY - top), radius: top, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: b.minX, y: b.minY + bottom))
        path.appendArc(withCenter: NSPoint(x: b.minX + bottom, y: b.minY + bottom), radius: bottom, startAngle: 180, endAngle: 270)
        path.close()
        path.lineWidth = 2
        NSColor.systemGreen.setStroke()
        path.stroke()
    }
}
