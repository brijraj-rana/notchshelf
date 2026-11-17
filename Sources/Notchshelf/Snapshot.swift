import AppKit
import NotchshelfCore
import QuickLookThumbnailing
import SwiftUI

/// Development aid: renders each state to a PNG with made-up files, so README images never show a real shelf.
@MainActor
enum Snapshot {
    static func render(to directory: String, scale: CGFloat) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("notchshelf-snapshot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        let files = sampleFiles(in: work.appendingPathComponent("files"))
        let store = ShelfStore(directory: work.appendingPathComponent("store"))
        store.add(files.reversed())
        Thumbnailer.scale = max(2, scale)
        preloadThumbnails(for: files)

        let empty = ShelfStore(directory: work.appendingPathComponent("empty"))
        let shots: [(String, Mode, ShelfStore, Bool)] = [
            ("collapsed", .ear, store, false),
            ("drop", .hint, empty, false),
            ("open", .open, store, false),
            ("empty", .open, empty, true),
        ]
        let out = URL(fileURLWithPath: directory)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)

        for (name, mode, shelf, targeted) in shots {
            let state = PanelState()
            state.mode = mode
            state.targeted = targeted
            let geo = state.geo
            let body = geo.dims(mode, hasItems: !shelf.items.isEmpty).height
            let height = geo.notchHeight + body + 56
            let view = RootView(state: state, store: shelf, actions: ShelfActions())
                .environment(\.isSnapshot, true)
                .frame(height: height, alignment: .top)
                .clipped()
                .background(alignment: .top) {
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.56), Color(red: 0.62, green: 0.56, blue: 0.66)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Color.white.opacity(0.22).frame(height: geo.notchHeight)
                    }
                }
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            if let cg = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
        try? fm.removeItem(at: work)
        exit(0)
    }

    /// ImageRenderer draws once and does not run view tasks, so thumbnails have to be in the cache beforehand.
    private static func preloadThumbnails(for files: [URL]) {
        var remaining = files.count
        for url in files {
            Task {
                _ = await Thumbnailer.thumbnail(for: url.standardizedFileURL)
                remaining -= 1
            }
        }
        let deadline = Date().addingTimeInterval(8)
        while remaining > 0, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: Sample files

    private static func sampleFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let cover = directory.appendingPathComponent("cover-art.png")
        writeImage(to: cover, type: .png, top: (0.98, 0.55, 0.32), bottom: (0.86, 0.22, 0.42))

        let board = directory.appendingPathComponent("moodboard.jpg")
        writeImage(to: board, type: .jpeg, top: (0.24, 0.62, 0.92), bottom: (0.16, 0.26, 0.62))

        let invoice = directory.appendingPathComponent("Invoice 0425.pdf")
        writePDF(to: invoice)

        let notes = directory.appendingPathComponent("release-notes.txt")
        let text = "Release notes\n\n" + (1...14).map { "\($0). Smaller, faster, and a little kinder to the battery." }.joined(separator: "\n")
        try? Data(text.utf8).write(to: notes)

        let folder = directory.appendingPathComponent("Brand assets", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        return [cover, invoice, board, notes, folder]
    }

    private typealias RGB = (CGFloat, CGFloat, CGFloat)

    private static func writeImage(to url: URL, type: NSBitmapImageRep.FileType, top: RGB, bottom: RGB) {
        let width = 960, height = 720
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let ctx = context.cgContext
        let space = CGColorSpaceCreateDeviceRGB()
        func color(_ c: RGB, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [c.0, c.1, c.2, a])! }

        let gradient = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        ctx.setFillColor(color((1, 1, 1), 0.22))
        ctx.fillEllipse(in: CGRect(x: 520, y: 300, width: 520, height: 520))
        ctx.setFillColor(color((0, 0, 0), 0.16))
        ctx.fillEllipse(in: CGRect(x: -140, y: -220, width: 620, height: 620))

        try? rep.representation(using: type, properties: [.compressionFactor: 0.9])?.write(to: url)
    }

    private static func writePDF(to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(box)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 56, y: 690, width: 190, height: 30))
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        for row in 0..<11 {
            let y = CGFloat(610 - row * 44)
            ctx.fill(CGRect(x: 56, y: y, width: row % 3 == 2 ? 250 : 340, height: 12))
            ctx.fill(CGRect(x: 470, y: y, width: 86, height: 12))
        }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 420, y: 96, width: 136, height: 20))
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
