// Copyright © 2026 TGTools123, author of NUEM. GNU GPL v3.
// "Tuning Curves" window: pick a parameter and shape its value as a function of the lid angle.

import Cocoa

/// A color that resolves to `light` or `dark` with the appearance it's drawn in.
private func adaptive(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}

final class CurveView: NSView {
    var curve: ParamCurve? { didSet { selected = nil; needsDisplay = true } }
    var liveAngle: CGFloat = 0 { didSet { if abs(liveAngle - oldValue) > 0.05 { needsDisplay = true } } }
    private var selected: Int?
    private var isDragging = false
    private let inset = NSEdgeInsets(top: 20, left: 48, bottom: 32, right: 20)
    override var acceptsFirstResponder: Bool { true }

    // The graph's palette, in its light and dark versions (it follows the app's appearance).
    private let background = adaptive(light: NSColor(white: 0.95, alpha: 1), dark: NSColor(white: 0.12, alpha: 1))
    private let plotFill = adaptive(light: .white, dark: NSColor(white: 0.18, alpha: 1))
    private let grid = adaptive(light: NSColor(white: 0.84, alpha: 1), dark: NSColor(white: 0.3, alpha: 1))
    private let label = adaptive(light: NSColor(white: 0.4, alpha: 1), dark: NSColor(white: 0.7, alpha: 1))
    private let formulaLine = adaptive(light: NSColor(white: 0.55, alpha: 0.8), dark: NSColor(white: 0.5, alpha: 0.8))
    private let message = adaptive(light: NSColor(white: 0.2, alpha: 1), dark: NSColor(white: 0.85, alpha: 1))
    private let amber = adaptive(light: NSColor(red: 0.88, green: 0.52, blue: 0, alpha: 1), dark: NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1))
    private let green = adaptive(light: NSColor(red: 0.15, green: 0.6, blue: 0.3, alpha: 1), dark: NSColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 1))
    private let blue = adaptive(light: NSColor(red: 0, green: 0.45, blue: 0.9, alpha: 1), dark: NSColor(red: 0.3, green: 0.8, blue: 1, alpha: 1))

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var plot: NSRect {
        NSRect(x: inset.left, y: inset.bottom, width: bounds.width - inset.left - inset.right,
               height: bounds.height - inset.top - inset.bottom)
    }
    private func point(angle: CGFloat, value: CGFloat) -> NSPoint {
        let p = plot, maxV = curve?.maxValue ?? 1, minV = curve?.minValue ?? 0
        return NSPoint(x: p.minX + (1 - angle / Settings.startAngle) * p.width, y: p.minY + (value - minV) / (maxV - minV) * p.height)
    }
    private func sample(at pt: NSPoint) -> (angle: CGFloat, value: CGFloat) {
        let p = plot, maxV = curve?.maxValue ?? 1, minV = curve?.minValue ?? 0
        let angle = (1 - (pt.x - p.minX) / p.width) * Settings.startAngle
        return (min(Settings.startAngle, max(0, angle)), min(maxV, max(minV, minV + (pt.y - p.minY) / p.height * (maxV - minV))))
    }
    private func text(_ s: String, at pt: NSPoint, color: NSColor, weight: NSFont.Weight = .regular) {
        (s as NSString).draw(at: pt, withAttributes: [.foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: weight)])
    }
    private func line(from a: NSPoint, to b: NSPoint, color: NSColor, width: CGFloat = 0.5, dashed: Bool = false) {
        let path = NSBezierPath()
        path.move(to: a); path.line(to: b); path.lineWidth = width
        if dashed { path.setLineDash([4, 4], count: 2, phase: 0) }
        color.setStroke(); path.stroke()
    }
    private func polyline(_ f: (CGFloat) -> CGFloat, color: NSColor, width: CGFloat) {
        guard let c = curve else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        for i in 0...190 {
            let a = Settings.startAngle * (1 - CGFloat(i) / 190)
            let pt = point(angle: a, value: min(c.maxValue, max(c.minValue, f(a))))
            i == 0 ? path.move(to: pt) : path.line(to: pt)
        }
        color.setStroke(); path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        let p = plot
        plotFill.setFill(); p.fill()
        for a in stride(from: 0, through: Int(Settings.startAngle), by: 10) {
            let x = point(angle: CGFloat(a), value: 0).x
            line(from: NSPoint(x: x, y: p.minY), to: NSPoint(x: x, y: p.maxY), color: grid)
            text("\(a)°", at: NSPoint(x: x - 8, y: p.minY - 16), color: label)
        }
        if let c = curve {
            for k in 0...4 {
                let v = c.minValue + (c.maxValue - c.minValue) * CGFloat(k) / 4, y = point(angle: 0, value: v).y
                line(from: NSPoint(x: p.minX, y: y), to: NSPoint(x: p.maxX, y: y), color: grid)
                text(String(format: "%.2f", v), at: NSPoint(x: 6, y: y - 6), color: label)
            }
            for mark in c.landmarks where mark.value <= c.maxValue && mark.value >= c.minValue {
                let y = point(angle: 0, value: mark.value).y
                line(from: NSPoint(x: p.minX, y: y), to: NSPoint(x: p.maxX, y: y), color: green.withAlphaComponent(0.8), width: 1, dashed: true)
                text(mark.label, at: NSPoint(x: p.maxX - 6 - CGFloat(mark.label.count) * 6, y: y + 3), color: green)
            }
            polyline(c.formula, color: formulaLine, width: 1)
            if c.points.isEmpty {
                text("No points: the gray formula applies. Double-click to add a point.", at: NSPoint(x: p.minX + 10, y: p.maxY - 18), color: message)
            } else {
                polyline(c.value(at:), color: amber, width: 2)
                for (i, pt) in c.points.enumerated() {
                    let v = point(angle: CGFloat(pt.angle), value: CGFloat(pt.value))
                    let r: CGFloat = selected == i ? 7 : 5
                    let dot = NSBezierPath(ovalIn: NSRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
                    amber.setFill(); dot.fill()
                    NSColor.black.setStroke(); dot.lineWidth = 1; dot.stroke()
                }
            }
        }
        let x = point(angle: liveAngle, value: 0).x
        line(from: NSPoint(x: x, y: p.minY), to: NSPoint(x: x, y: p.maxY), color: blue.withAlphaComponent(0.9), width: 1.5)
        text(String(format: "%.1f°", liveAngle), at: NSPoint(x: min(x + 4, p.maxX - 44), y: p.maxY - 14), color: blue, weight: .semibold)
    }

    private func nearest(_ pt: NSPoint) -> Int? {
        guard let c = curve else { return nil }
        let hits = c.points.enumerated().map { ($0.offset, hypot(point(angle: CGFloat($0.element.angle), value: CGFloat($0.element.value)).x - pt.x,
                                                                   point(angle: CGFloat($0.element.angle), value: CGFloat($0.element.value)).y - pt.y)) }
        return hits.filter { $0.1 < 12 }.min { $0.1 < $1.1 }?.0
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = curve else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            let (a, v) = sample(at: pt)
            c.set(c.points.filter { abs($0.angle - Double(a)) > 1 } + [CurvePoint(angle: Double(a), value: Double(v))])
            selected = c.points.firstIndex { abs($0.angle - Double(a)) < 1e-6 }
        } else {
            selected = nearest(pt)
            isDragging = selected != nil
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let i = selected, let c = curve else { return }
        let (a, v) = sample(at: convert(event.locationInWindow, from: nil))
        var pts = c.points
        pts[i] = CurvePoint(angle: Double(a), value: Double(v))
        c.set(pts)
        selected = c.points.firstIndex { abs($0.angle - Double(a)) < 1e-6 && abs($0.value - Double(v)) < 1e-6 }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { isDragging = false }
    override func rightMouseDown(with event: NSEvent) {
        guard let i = nearest(convert(event.locationInWindow, from: nil)) else { return }
        delete(i)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let i = selected { delete(i) } else { super.keyDown(with: event) }
    }
    private func delete(_ i: Int) {
        guard let c = curve, c.points.indices.contains(i) else { return }
        var pts = c.points
        pts.remove(at: i)
        c.set(pts)
        selected = nil
        needsDisplay = true
    }
}

final class CurveWindowController: NSObject {
    let window: NSWindow
    let view = CurveView(frame: .zero)
    private let curves: Curves
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    init(curves: Curves) {
        self.curves = curves
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NUEM — Tuning Curves"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        super.init()

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        popup.addItems(withTitles: curves.all.map(\.title))
        popup.target = self
        popup.action = #selector(changeCurve)
        popup.frame = NSRect(x: 12, y: content.bounds.height - 34, width: 380, height: 26)
        popup.autoresizingMask = [.minYMargin]
        let reset = NSButton(title: "Reset This Curve", target: self, action: #selector(resetCurve))
        reset.frame = NSRect(x: content.bounds.width - 172, y: content.bounds.height - 34, width: 160, height: 26)
        reset.autoresizingMask = [.minXMargin, .minYMargin]
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.maximumNumberOfLines = 3
        hintLabel.frame = NSRect(x: 12, y: content.bounds.height - 86, width: content.bounds.width - 24, height: 48)
        hintLabel.autoresizingMask = [.width, .minYMargin]
        let help = NSTextField(labelWithString: "Double-click: add · drag: move · right-click or ⌫: delete · gray = formula · amber = curve · blue = lid angle · Preview from the menu to see it move")
        help.font = NSFont.systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 12, y: 6, width: content.bounds.width - 24, height: 16)
        help.autoresizingMask = [.width]
        view.frame = NSRect(x: 8, y: 26, width: content.bounds.width - 16, height: content.bounds.height - 120)
        view.autoresizingMask = [.width, .height]
        [popup, reset, hintLabel, help, view].forEach(content.addSubview)
        window.contentView = content
        changeCurve()
        window.center()
    }

    func show() {
        view.needsDisplay = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changeCurve() {
        let curve = curves.all[max(0, popup.indexOfSelectedItem)]
        view.curve = curve
        hintLabel.stringValue = curve.hint
    }
    @objc private func resetCurve() { view.curve?.resetToDefault(); view.needsDisplay = true }
}
