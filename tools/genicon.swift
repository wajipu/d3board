import AppKit

// Renders the app icon: a dark squircle showing three device rows with status
// dots — the same thing the window does, at icon size.
let side: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: side, height: side)
NSColor.clear.setFill()
canvas.fill()

// Background squircle
let inset: CGFloat = 52
let background = NSBezierPath(roundedRect: canvas.insetBy(dx: inset, dy: inset),
                              xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1),
])!
gradient.draw(in: background, angle: -90)

// Hairline highlight on top edge
NSColor.white.withAlphaComponent(0.10).setStroke()
background.lineWidth = 6
background.stroke()

// Three "device rows"
let rowWidth: CGFloat = 560
let rowHeight: CGFloat = 104
let rowX = (side - rowWidth) / 2
let rowsY: [CGFloat] = [596, 460, 324]
let accents: [NSColor] = [
    NSColor(srgbRed: 0.24, green: 0.82, blue: 0.42, alpha: 1),
    NSColor(srgbRed: 0.36, green: 0.58, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.60, blue: 0.70, alpha: 1),
]

for (index, y) in rowsY.enumerated() {
    let rowRect = NSRect(x: rowX, y: y, width: rowWidth, height: rowHeight)
    let row = NSBezierPath(roundedRect: rowRect, xRadius: 34, yRadius: 34)
    NSColor(srgbRed: 0.13, green: 0.16, blue: 0.23, alpha: 1).setFill()
    row.fill()
    if index == 1 {
        NSColor(srgbRed: 0.36, green: 0.58, blue: 1.0, alpha: 0.22).setFill()
        row.fill()
    }

    // status dot
    let dotRect = NSRect(x: rowRect.minX + 34, y: rowRect.midY - 17, width: 34, height: 34)
    accents[index].setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    // label bars
    let bar1 = NSRect(x: dotRect.maxX + 30, y: rowRect.midY + 6, width: 300, height: 22)
    let bar2 = NSRect(x: dotRect.maxX + 30, y: rowRect.midY - 30, width: 190, height: 16)
    NSColor.white.withAlphaComponent(index == 2 ? 0.18 : 0.42).setFill()
    NSBezierPath(roundedRect: bar1, xRadius: 11, yRadius: 11).fill()
    NSColor.white.withAlphaComponent(index == 2 ? 0.12 : 0.24).setFill()
    NSBezierPath(roundedRect: bar2, xRadius: 8, yRadius: 8).fill()
}

NSGraphicsContext.restoreGraphicsState()

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outDir + "/icon-1024.png"))
print("wrote icon-1024.png")
