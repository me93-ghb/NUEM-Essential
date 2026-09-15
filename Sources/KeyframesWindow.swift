// Copyright © 2026 TGTools123. NUEM, GNU General Public License v3.
// The Keyframes window (menu → Keyframes…), opened on the other display when there is one: the mode switch, the live
// lid angle, the picture's trapezoid at this angle as four sliders with a sketch, the Keyframe button, and the list.

import Cocoa
import SwiftUI

final class KeyframesWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: KeyframesView(store: .shared)))
        window.title = "Keyframes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 700))
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        if !window.isVisible, let other = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) == 0 }) {
            let frame = other.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct KeyframesView: View {
    @ObservedObject var store: KeyframeStore

    var body: some View {
        let folded = store.liveAngle < store.start
        let shown = store.quad(at: store.liveAngle, start: store.start)
        Form {
            Section {
                Toggle(isOn: $store.isOn) {
                    Text("Keyframes mode")
                        .overlay(Text(Links.author).font(.system(size: 1)).opacity(0).accessibilityHidden(true))
                    Text("NUEM draws the fold from your keyframes instead of your settings: the picture's shape only, no perspective, blur or vignette. Off, everything is as before.")
                }
            }
            Section("Lid") {
                Text(String(format: "%.1f°", store.liveAngle))
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(!folded ? String(format: "Above the fold's start (%.0f°): the picture is untouched. Close the lid a little.", store.start)
                     : store.pending != nil ? "Editing: not saved until you press Keyframe."
                     : store.keyframes.isEmpty ? "No keyframes: the picture is untouched." : "From your keyframes.")
                    .foregroundStyle(.secondary)
            }
            Section("The picture at this angle") {
                QuadSketch(quad: shown).frame(height: 170)
                slider("Top edge", "Height from the bottom of the screen", \.topY, -0.2...1.5, shown)
                slider("Top width", "Width of the top edge", \.topWidth, 0.1...2, shown)
                slider("Bottom edge", "Height from the bottom of the screen", \.bottomY, -0.5...1, shown)
                slider("Bottom width", "Width of the bottom edge", \.bottomWidth, 0.1...2, shown)
                slider("Top shift", "The top edge sideways, share of the width (+ right)", \.topShift, -0.5...0.5, shown)
                slider("Bottom shift", "The bottom edge sideways, share of the width (+ right)", \.bottomShift, -0.5...0.5, shown)
                HStack {
                    Button(String(format: "Keyframe at %.0f°", store.liveAngle.rounded())) { store.commit(shown, at: store.liveAngle) }
                        .keyboardShortcut(.return)
                        .disabled(!folded || store.liveAngle.rounded() > store.start - 1)
                    Button("Discard") { store.pending = nil }
                        .disabled(store.pending == nil)
                }
            }
            Section("Keyframes") {
                if store.keyframes.isEmpty {
                    Text("None yet. Hold the lid at an angle, shape the picture, press Keyframe.").foregroundStyle(.secondary)
                }
                ForEach(store.keyframes) { frame in
                    HStack {
                        Text(String(format: "%.0f°", frame.angle)).monospacedDigit().frame(width: 44, alignment: .leading)
                        Text(describe(frame.quad)).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") { store.pending = frame.quad }
                        Button(role: .destructive) { store.remove(frame.id) } label: { Image(systemName: "trash") }
                    }
                }
                if !store.keyframes.isEmpty {
                    Button("Delete all", role: .destructive) { store.removeAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
    }

    private func slider(_ title: String, _ detail: String, _ field: WritableKeyPath<Quad, Double>, _ range: ClosedRange<Double>, _ shown: Quad) -> some View {
        let value = Binding<Double>(get: { shown[keyPath: field] }, set: { newValue in
            var quad = store.pending ?? shown
            quad[keyPath: field] = newValue
            store.pending = quad
        })
        // The value typed in percent; the arrows step 0.1 %.
        let percent = Binding<Double>(get: { value.wrappedValue * 100 },
                                      set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0 / 100)) })
        return LabeledContent {
            HStack {
                Slider(value: value, in: range)
                TextField("", value: percent, format: .number.precision(.fractionLength(1)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text("%").foregroundStyle(.secondary)
                Stepper("", value: value, in: range, step: 0.001).labelsHidden()
            }
            .frame(maxWidth: 380)
        } label: {
            Text(title)
            Text(detail)
        }
    }

    /// One keyframe's values, for the list.
    private func describe(_ quad: Quad) -> String {
        func shift(_ s: Double) -> String { abs(s) < 0.0005 ? "" : String(format: " %+.1f%%", s * 100) }
        return String(format: "top %.1f%% × %.1f%%", quad.topY * 100, quad.topWidth * 100) + shift(quad.topShift)
            + String(format: "   bottom %.1f%% × %.1f%%", quad.bottomY * 100, quad.bottomWidth * 100) + shift(quad.bottomShift)
    }
}

/// The screen (outline) and the picture's trapezoid on it.
// Sketch by TGTools123.
private struct QuadSketch: View {
    let quad: Quad
    var body: some View {
        Canvas { context, size in
            let aspect = 1.547                                            // the built-in screen, 2056 × 1329 points
            let w = min(size.width * 0.8, size.height * 0.8 * aspect), h = w / aspect
            let ox = (size.width - w) / 2, oy = (size.height - h) / 2
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + w * x, y: oy + h * (1 - y)) }
            context.stroke(Path(CGRect(x: ox, y: oy, width: w, height: h)), with: .color(.secondary), lineWidth: 1)
            var shape = Path()
            shape.move(to: point(0.5 + quad.topShift - quad.topWidth / 2, quad.topY))
            shape.addLine(to: point(0.5 + quad.topShift + quad.topWidth / 2, quad.topY))
            shape.addLine(to: point(0.5 + quad.bottomShift + quad.bottomWidth / 2, quad.bottomY))
            shape.addLine(to: point(0.5 + quad.bottomShift - quad.bottomWidth / 2, quad.bottomY))
            shape.closeSubpath()
            context.fill(shape, with: .color(.accentColor.opacity(0.2)))
            context.stroke(shape, with: .color(.accentColor), lineWidth: 2)
        }
    }
}
