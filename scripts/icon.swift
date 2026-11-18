// Renders the suite's folded S mark into a macOS iconset.
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 128)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 9, y: 9, width: 110, height: 110), xRadius: 25, yRadius: 25)
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.115, blue: 0.125, alpha: 1), ending: NSColor(srgbRed: 0.23, green: 0.21, blue: 0.235, alpha: 1))!.draw(in: tile, angle: 65)
        func shape(_ points: [(Int, Int)], _ color: NSColor) {
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let p = NSPoint(x: point.0, y: point.1)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            color.setFill()
            path.fill()
        }
        shape([(34,75),(67,94),(96,78),(84,71),(67,80),(47,68)], NSColor(srgbRed: 1, green: 0.44, blue: 0.43, alpha: 1))
        shape([(34,75),(47,68),(93,51),(80,43),(34,61)], NSColor(srgbRed: 0.99, green: 0.28, blue: 0.34, alpha: 1))
        shape([(93,51),(93,45),(61,27),(32,43),(44,51),(61,41),(80,51)], NSColor(srgbRed: 0.88, green: 0.16, blue: 0.23, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
