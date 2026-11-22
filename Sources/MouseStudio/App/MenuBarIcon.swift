import AppKit

/// The menu bar mouse, drawn as a template image so macOS tints it for Light, Dark and tinted menu bars.
/// Solid = active, outline = paused, outline with a dot = needs attention.
enum MenuBarIcon {
    enum Style {
        case active, paused, attention
    }

    static let active = make(.active)
    static let paused = make(.paused)
    static let attention = make(.attention)

    private static func make(_ style: Style) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let body = NSRect(x: 4.5, y: 1.5, width: 9, height: 15)
            NSColor.black.setFill()
            NSColor.black.setStroke()

            switch style {
            case .active:
                NSBezierPath(roundedRect: body, xRadius: 4.5, yRadius: 4.5).fill()
                // Wheel and seam are cut out of the solid body.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(roundedRect: NSRect(x: 8.15, y: 10.4, width: 1.7, height: 3.6), xRadius: 0.85, yRadius: 0.85).fill()
                NSBezierPath(rect: NSRect(x: 4.5, y: 8.7, width: 9, height: 0.9)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .paused, .attention:
                let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.7, dy: 0.7), xRadius: 3.8, yRadius: 3.8)
                outline.lineWidth = 1.4
                outline.stroke()
                NSBezierPath(roundedRect: NSRect(x: 8.15, y: 10.4, width: 1.7, height: 3.6), xRadius: 0.85, yRadius: 0.85).fill()
                NSBezierPath(rect: NSRect(x: 5.2, y: 8.9, width: 7.6, height: 0.8)).fill()
            }

            if style == .attention {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 10.2, y: 0, width: 7.2, height: 7.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 11.3, y: 1.1, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
