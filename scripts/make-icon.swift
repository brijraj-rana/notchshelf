// Renders Resources/AppIcon.icns: a notch hanging from the top of a graphite tile, with three parked files on a shelf below it.
// Usage: swift scripts/make-icon.swift [repo root]
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size / 1024
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [r, g, b, a])!
        }
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)

        // Drop shadow + graphite body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: color(0, 0, 0, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(color(0.1, 0.1, 0.11)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let body = CGGradient(colorsSpace: srgb, colors: [color(0.21, 0.21, 0.23), color(0.08, 0.08, 0.09)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

        // The shelf: three parked files standing on a hairline ledge.
        let cards: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [   // x, width, height, brightness
            (232, 160, 204, 0.62), (432, 160, 262, 1.0), (632, 160, 180, 0.42),
        ]
        let ledge: CGFloat = 300
        for (x, width, height, brightness) in cards {
            let card = CGRect(x: x * s, y: ledge * s, width: width * s, height: height * s)
            let path = CGPath(roundedRect: card, cornerWidth: 30 * s, cornerHeight: 30 * s, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 26 * s, color: color(0, 0, 0, 0.45))
            ctx.addPath(path); ctx.setFillColor(color(0.93, 0.94, 0.96, brightness)); ctx.fillPath()
            ctx.restoreGState()
            // A folded line or two, so the cards read as documents.
            ctx.setFillColor(color(0, 0, 0, 0.16))
            for row in 0..<2 where height > CGFloat(110 + row * 44) {
                let line = CGRect(x: (x + 28) * s, y: (ledge + height - 62 - CGFloat(row) * 44) * s, width: (width - (row == 0 ? 56 : 88)) * s, height: 16 * s)
                ctx.addPath(CGPath(roundedRect: line, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil)); ctx.fillPath()
            }
        }
        let rail = CGRect(x: 188 * s, y: (ledge - 34) * s, width: 648 * s, height: 20 * s)
        ctx.addPath(CGPath(roundedRect: rail, cornerWidth: 10 * s, cornerHeight: 10 * s, transform: nil))
        ctx.setFillColor(color(1, 1, 1, 0.3)); ctx.fillPath()

        // The notch: pure black, hanging from the top edge.
        let notch = CGMutablePath()
        let left = 332 * s, right = 692 * s, top = tile.maxY, bottom = 762 * s, r = 46 * s
        notch.move(to: CGPoint(x: left, y: top))
        notch.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: right, y: bottom), radius: r)
        notch.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: top), radius: r)
        notch.addLine(to: CGPoint(x: right, y: top))
        notch.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 22 * s, color: color(0, 0, 0, 0.5))
        ctx.addPath(notch); ctx.setFillColor(color(0, 0, 0)); ctx.fillPath()
        ctx.restoreGState()

        // Hairline edge highlight.
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
        ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(3 * s); ctx.strokePath()
        return true
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
let docs = root.appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: docs.appendingPathComponent("icon.png"))
try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_256x256@2x.png"), to: docs.appendingPathComponent("icon.png"))
print("Wrote \(output.path)")
