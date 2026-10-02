// Draws the DMG window background at 1x and 2x.
// Run from the repo root after changing the design: swift .github/dmg/background.swift Pennant
// The icon positions here must match settings.py.

import AppKit

let name = CommandLine.arguments.dropFirst().first ?? "App"
let size = NSSize(width: 640, height: 400)
let appCenter = NSPoint(x: 160, y: 200)
let applicationsCenter = NSPoint(x: 480, y: 200)

func draw() {
    // Flip so y runs down like Finder's icon positions.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: size.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    NSGradient(
        starting: NSColor(srgbRed: 0.99, green: 0.99, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.91, green: 0.91, blue: 0.93, alpha: 1)
    )?.draw(in: NSRect(origin: .zero, size: size), angle: 90)

    let title = NSAttributedString(
        string: "Install \(name)",
        attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        ])
    let titleSize = title.size()
    title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: 44))

    let caption = NSAttributedString(
        string: "Drag \(name) into the Applications folder",
        attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
        ])
    let captionSize = caption.size()
    caption.draw(at: NSPoint(x: (size.width - captionSize.width) / 2, y: 82))

    // A gentle arc from the app to Applications, with an open arrowhead.
    let start = NSPoint(x: appCenter.x + 92, y: appCenter.y)
    let end = NSPoint(x: applicationsCenter.x - 92, y: applicationsCenter.y)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(
        to: end,
        controlPoint1: NSPoint(x: start.x + 40, y: start.y - 26),
        controlPoint2: NSPoint(x: end.x - 40, y: end.y - 26))
    let back = atan2(-26.0, -40.0)  // Points from the tip back along the curve.
    for wing in [back - 0.5, back + 0.5] {
        arrow.move(to: NSPoint(x: end.x + 18 * cos(wing), y: end.y + 18 * sin(wing)))
        arrow.line(to: end)
    }
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(srgbRed: 0.62, green: 0.62, blue: 0.66, alpha: 1).setStroke()
    arrow.stroke()
}

for scale in [1, 2] {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("Could not create bitmap") }
    rep.size = size  // Sets 144 DPI on the 2x file so tiffutil pairs them.
    NSGraphicsContext.saveGraphicsState()
    let bitmap = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let url = URL(fileURLWithPath: ".github/dmg/background\(suffix).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}
