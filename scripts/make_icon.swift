// Renders Resources/AppIcon.icns: a graphite squircle with a silver mouse and a softly glowing blue wheel.
// Usage: swift scripts/make_icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw() {
    let center = NSPoint(x: 512, y: 512)

    // Tile
    let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    tileShadow.shadowOffset = NSSize(width: 0, height: -14)
    tileShadow.shadowBlurRadius = 30
    tileShadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color(0x3B3F47), color(0x121418)])!.draw(in: tileRect, angle: -90)
    // Soft blue light behind the mouse
    NSGradient(colors: [color(0x0A84FF, 0.34), color(0x0A84FF, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 400, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Thin rim light on the tile
    color(0xFFFFFF, 0.14).setStroke()
    let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()

    // Mouse
    let mouseRect = NSRect(x: 342, y: 232, width: 340, height: 560)
    let mouse = NSBezierPath(roundedRect: mouseRect, xRadius: 170, yRadius: 170)
    NSGraphicsContext.saveGraphicsState()
    let mouseShadow = NSShadow()
    mouseShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    mouseShadow.shadowOffset = NSSize(width: 0, height: -20)
    mouseShadow.shadowBlurRadius = 44
    mouseShadow.set()
    NSColor.black.setFill()
    mouse.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    mouse.addClip()
    NSGradient(colors: [color(0xFFFFFF), color(0xE3E6EB), color(0xB9BFCA)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: mouseRect, angle: -90)
    // Gloss
    NSGradient(colors: [color(0xFFFFFF, 0.7), color(0xFFFFFF, 0)])!
        .draw(fromCenter: NSPoint(x: 440, y: 760), radius: 0, toCenter: NSPoint(x: 440, y: 760), radius: 250, options: [])
    // Button seams
    color(0x0B1220, 0.2).setStroke()
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: 512, y: mouseRect.maxY))
    seam.line(to: NSPoint(x: 512, y: 612))
    seam.move(to: NSPoint(x: mouseRect.minX, y: 612))
    seam.line(to: NSPoint(x: mouseRect.maxX, y: 612))
    seam.lineWidth = 5
    seam.stroke()
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFFFFF, 0.9).setStroke()
    let mouseRim = NSBezierPath(roundedRect: mouseRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 168, yRadius: 168)
    mouseRim.lineWidth = 3
    mouseRim.stroke()

    // Wheel
    let wheelRect = NSRect(x: 488, y: 646, width: 48, height: 116)
    let wheel = NSBezierPath(roundedRect: wheelRect, xRadius: 24, yRadius: 24)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x0A84FF, 0.85)
    glow.shadowOffset = .zero
    glow.shadowBlurRadius = 34
    glow.set()
    color(0x0A84FF).setFill()
    wheel.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x5AB0FF), color(0x0A6CFF)])!.draw(in: wheel, angle: -90)
    _ = center
}

func render(_ px: Int) -> Data {
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        let transform = NSAffineTransform()
        transform.scale(by: rect.width / 1024)
        transform.concat()
        draw()
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes {
    let data = render(size)
    if size <= 512 { try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: iconset.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
try render(512).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIconPreview.png"))
print("Wrote \(output.path)")
