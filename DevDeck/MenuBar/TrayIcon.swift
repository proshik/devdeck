import AppKit

/// Menu bar icon: a mini "control panel" (console frame + horizontal faders).
/// Drawn in code → crisp at any size; `isTemplate` → adapts to light/dark menu bar appearance.
enum TrayIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let body = rect.insetBy(dx: 1.5, dy: 1.5)

            // Console frame.
            let frame = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.2
            NSColor.black.setStroke()
            frame.stroke()

            // Three faders: track + knob at different positions.
            let faders: [(y: CGFloat, x: CGFloat)] = [(0.72, 0.62), (0.50, 0.32), (0.28, 0.50)]
            let trackLeft = body.minX + 3
            let trackRight = body.maxX - 3
            let knob = NSSize(width: 3, height: 2.4)

            for fader in faders {
                let y = body.minY + body.height * fader.y

                let track = NSBezierPath()
                track.move(to: NSPoint(x: trackLeft, y: y))
                track.line(to: NSPoint(x: trackRight, y: y))
                track.lineWidth = 0.8
                NSColor.black.withAlphaComponent(0.5).setStroke()
                track.stroke()

                let knobX = trackLeft + (trackRight - trackLeft) * fader.x - knob.width / 2
                let knobRect = NSRect(x: knobX, y: y - knob.height / 2, width: knob.width, height: knob.height)
                let knobPath = NSBezierPath(roundedRect: knobRect, xRadius: 0.8, yRadius: 0.8)
                NSColor.black.setFill()
                knobPath.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Badge color for a pressure level; nil under normal pressure (no badge).
    static func badgeColor(for level: MemoryPressureLevel) -> NSColor? {
        switch level {
        case .normal: return nil
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    /// The tray glyph, optionally with a colored pressure dot in the top-right corner.
    /// With a badge the image is non-template (the dot keeps its color); the glyph is drawn
    /// in `labelColor` so it still adapts to the menu bar appearance.
    static func image(pressureColor: NSColor?) -> NSImage {
        guard let pressureColor else { return image() }   // normal → existing template glyph
        let base = image()
        let composed = NSImage(size: base.size, flipped: false) { rect in
            NSColor.labelColor.set()
            base.draw(in: rect)   // template glyph tinted with the current label color
            let d: CGFloat = 6
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            pressureColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        composed.isTemplate = false
        return composed
    }
}
