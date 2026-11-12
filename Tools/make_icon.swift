// Renders Resources/AppIcon.icns (run once: swift Tools/make_icon.swift)
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(red: 0.10, green: 0.62, blue: 0.98, alpha: 1)])!.draw(in: path, angle: -90)
    // Three faders
    let knobs: [CGFloat] = [0.68, 0.38, 0.55]
    for (i, k) in knobs.enumerated() {
        let x = rect.minX + rect.width * (0.27 + CGFloat(i) * 0.23)
        let track = NSRect(x: x - rect.width * 0.018, y: rect.minY + rect.height * 0.2,
                           width: rect.width * 0.036, height: rect.height * 0.6)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.width / 2, yRadius: track.width / 2).fill()
        let kh = rect.height * 0.09, kw = rect.width * 0.15
        let knob = NSRect(x: x - kw / 2, y: rect.minY + rect.height * (0.2 + 0.6 * k) - kh / 2, width: kw, height: kh)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knob, xRadius: kh / 2.5, yRadius: kh / 2.5).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    try! render(CGFloat(s)).write(to: set.appendingPathComponent("icon_\(s)x\(s).png"))
    try! render(CGFloat(s * 2)).write(to: set.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
