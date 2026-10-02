// Draws the app icon, a waving pennant on a pole, into AppIcon.appiconset at every size,
// and a matching template pennant into MenuBarIcon.imageset as a vector PDF.
// Run from the repo root after changing the design: swift scripts/app-icon.swift

import AppKit

let canvas: CGFloat = 1024
let outputDir = "Pennant/Assets.xcassets/AppIcon.appiconset"
let menuBarDir = "Pennant/Assets.xcassets/MenuBarIcon.imageset"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Drawn in a 1024pt space with y up, following Apple's macOS icon grid.
func draw() {
    // Rounded-square body with the standard grid inset and drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    color(0.10, 0.17, 0.36).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(starting: color(0.20, 0.36, 0.70), ending: color(0.08, 0.14, 0.33))?
        .draw(in: body, angle: -90)

    // Pole with a gold finial.
    let poleX: CGFloat = 330
    let pole = NSBezierPath(roundedRect: NSRect(x: poleX - 14, y: 210, width: 28, height: 560), xRadius: 14, yRadius: 14)
    NSGradient(starting: color(0.96, 0.96, 0.98), ending: color(0.74, 0.76, 0.82))?.draw(in: pole, angle: 0)
    let finial = NSBezierPath(ovalIn: NSRect(x: poleX - 32, y: 752, width: 64, height: 64))
    NSGradient(starting: color(1.0, 0.86, 0.45), ending: color(0.88, 0.62, 0.18))?.draw(in: finial, angle: -60)

    // The pennant: a long triangle from the pole with a gentle wave to the tip.
    let hoistTop = NSPoint(x: poleX + 12, y: 742)
    let hoistBottom = NSPoint(x: poleX + 12, y: 500)
    let tip = NSPoint(x: 820, y: 586)
    let flag = NSBezierPath()
    flag.move(to: hoistTop)
    flag.curve(to: tip, controlPoint1: NSPoint(x: 500, y: 742), controlPoint2: NSPoint(x: 640, y: 600))
    flag.curve(to: hoistBottom, controlPoint1: NSPoint(x: 660, y: 548), controlPoint2: NSPoint(x: 500, y: 470))
    flag.close()

    NSGraphicsContext.saveGraphicsState()
    let flagShadow = NSShadow()
    flagShadow.shadowColor = color(0, 0, 0, 0.25)
    flagShadow.shadowOffset = NSSize(width: 0, height: -12)
    flagShadow.shadowBlurRadius = 24
    flagShadow.set()
    color(0.95, 0.35, 0.28).setFill()
    flag.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    flag.addClip()
    NSGradient(starting: color(1.0, 0.50, 0.36), ending: color(0.86, 0.20, 0.24))?.draw(in: flag.bounds, angle: -30)
    // A lighter hoist band, like a sports pennant.
    color(1, 1, 1, 0.9).setFill()
    NSRect(x: hoistTop.x, y: hoistBottom.y - 40, width: 58, height: hoistTop.y - hoistBottom.y + 80).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
}

struct Slot { let points: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("Could not create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / canvas)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()

    let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
    let filename = "icon_\(slot.points)x\(slot.points)\(suffix).png"
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outputDir)/\(filename)"))
    images.append([
        "filename": filename, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)",
    ])
    print("Wrote \(filename)")
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: "\(outputDir)/Contents.json"))

// The menu bar version is a single-color template in an 18pt square, so the pole is thicker
// than a straight scale-down and a thin gap stands in for the hoist band.
func drawMenuBar() {
    let pole = NSBezierPath(roundedRect: NSRect(x: 2.4, y: 0.5, width: 1.7, height: 14.5), xRadius: 0.85, yRadius: 0.85)
    let finial = NSBezierPath(ovalIn: NSRect(x: 1.65, y: 14.2, width: 3.2, height: 3.2))
    let hoistTop = NSPoint(x: 4.1, y: 14.2)
    let hoistBottom = NSPoint(x: 4.1, y: 7.4)
    let tip = NSPoint(x: 17.5, y: 10.0)
    let flag = NSBezierPath()
    flag.move(to: hoistTop)
    flag.curve(to: tip, controlPoint1: NSPoint(x: 8.8, y: 14.2), controlPoint2: NSPoint(x: 12.5, y: 10.6))
    flag.curve(to: hoistBottom, controlPoint1: NSPoint(x: 13.0, y: 9.1), controlPoint2: NSPoint(x: 8.8, y: 6.5))
    flag.close()

    NSColor.black.setFill()
    pole.fill()
    finial.fill()
    NSGraphicsContext.saveGraphicsState()
    let band = NSBezierPath(rect: NSRect(x: 6.1, y: 0, width: 0.9, height: 18))
    band.append(NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18)))
    band.windingRule = .evenOdd
    band.addClip()
    flag.fill()
    NSGraphicsContext.restoreGraphicsState()
}

var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
guard let pdf = CGContext(URL(fileURLWithPath: "\(menuBarDir)/menubar.pdf") as CFURL, mediaBox: &mediaBox, nil)
else { fatalError("Could not create PDF") }
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
drawMenuBar()
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()
print("Wrote menubar.pdf")

let menuBarContents: [String: Any] = [
    "images": [["filename": "menubar.pdf", "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
]
try JSONSerialization.data(withJSONObject: menuBarContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(menuBarDir)/Contents.json"))
