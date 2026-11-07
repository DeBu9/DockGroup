import AppKit
import Foundation
import CoreGraphics

/// Draws DockGroup icons in the macOS 26/27 idiom: a continuous-corner glass
/// plate, layered highlight, soft shadow and app thumbnails clipped to
/// rounded rectangles. Works in both light and dark appearance.
enum IconRenderer {
    static let canvas: CGFloat = 1024

    private static let plateRect = CGRect(x: 64, y: 64, width: 896, height: 896)
    private static let corner: CGFloat = 210

    static func groupImage(icons: [NSImage]) -> NSImage {
        render { ctx in
            drawPlate(ctx, accent: CGColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 1))
            drawThumbnails(ctx, Array(icons.prefix(4)))
        }
    }

    static func appImage() -> NSImage {
        render { ctx in
            drawPlate(ctx, accent: CGColor(red: 0.40, green: 0.58, blue: 0.95, alpha: 1))
            drawAppGlyph(ctx)
        }
    }

    // MARK: - Canvas

    private static func render(_ draw: (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            draw(ctx)
        }
        image.unlockFocus()
        return image
    }

    private static func roundPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
               transform: nil)
    }

    // MARK: - Glass plate

    private static func drawPlate(_ ctx: CGContext, accent: CGColor) {
        let rect = plateRect
        let path = roundPath(rect, radius: corner)

        // Drop shadow under the plate.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 52,
                      color: CGColor(gray: 0.05, alpha: 0.26))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.01))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        // Base gradient: cool tint at the top-left, neutral glass at the bottom.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let base = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.99, green: 0.99, blue: 1.0, alpha: 1),
                CGColor(red: 0.90, green: 0.93, blue: 0.98, alpha: 1),
                accent.copy(alpha: 0.82) ?? accent
            ] as CFArray,
            locations: [0.0, 0.48, 1.0]
        )
        if let base = base {
            ctx.drawLinearGradient(base,
                                   start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: [])
        }

        // Diagonal specular sweep, the signature Liquid Glass highlight.
        let sheen = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(gray: 1, alpha: 0.72),
                CGColor(gray: 1, alpha: 0.10),
                CGColor(gray: 1, alpha: 0.0)
            ] as CFArray,
            locations: [0.0, 0.38, 0.72]
        )
        if let sheen = sheen {
            ctx.drawLinearGradient(sheen,
                                   start: CGPoint(x: rect.minX + 40, y: rect.maxY - 20),
                                   end: CGPoint(x: rect.maxX - 60, y: rect.minY + 190),
                                   options: [])
        }

        // Soft rim light along the top edge.
        ctx.addEllipse(in: CGRect(x: rect.minX - 180, y: rect.maxY - 300,
                                  width: rect.width + 360, height: 420))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
        ctx.fillPath()
        ctx.restoreGState()

        // Inner white hairline + outer separation line.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.setLineWidth(5)
        ctx.strokePath()
        ctx.addPath(roundPath(rect.insetBy(dx: 3, dy: 3), radius: corner - 3))
        ctx.setStrokeColor(CGColor(gray: 0.25, alpha: 0.16))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Thumbnails

    private static func thumbnailRects(_ count: Int) -> [CGRect] {
        // Fewer items get larger tiles so the plate never looks half empty.
        let cell: CGFloat = count == 1 ? 500 : (count == 2 ? 380 : (count == 3 ? 330 : 304))
        let gap: CGFloat = count == 2 ? 56 : 48

        if count == 1 {
            return [CGRect(x: (canvas - cell) / 2, y: (canvas - cell) / 2,
                           width: cell, height: cell)]
        }
        if count == 2 {
            let total = cell * 2 + gap
            let left = (canvas - total) / 2
            let y = (canvas - cell) / 2
            return [
                CGRect(x: left, y: y, width: cell, height: cell),
                CGRect(x: left + cell + gap, y: y, width: cell, height: cell)
            ]
        }

        let totalW = cell * 2 + gap
        let totalH = cell * 2 + gap
        let left = (canvas - totalW) / 2
        let bottom = (canvas - totalH) / 2
        let top = bottom + cell + gap
        let centreX = (canvas - cell) / 2

        if count == 3 {
            return [
                CGRect(x: left, y: top, width: cell, height: cell),
                CGRect(x: left + cell + gap, y: top, width: cell, height: cell),
                CGRect(x: centreX, y: bottom, width: cell, height: cell)
            ]
        }
        return [
            CGRect(x: left, y: top, width: cell, height: cell),
            CGRect(x: left + cell + gap, y: top, width: cell, height: cell),
            CGRect(x: left, y: bottom, width: cell, height: cell),
            CGRect(x: left + cell + gap, y: bottom, width: cell, height: cell)
        ]
    }

    private static func drawThumbnails(_ ctx: CGContext, _ icons: [NSImage]) {
        guard !icons.isEmpty else {
            drawEmptyGlyph(ctx)
            return
        }
        let rects = thumbnailRects(icons.count)
        for (icon, rect) in zip(icons, rects) {
            let path = roundPath(rect, radius: 72)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26,
                          color: CGColor(gray: 0.1, alpha: 0.20))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.62))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(4)
            ctx.strokePath()
            ctx.restoreGState()

            let imageRect = rect.insetBy(dx: 30, dy: 30)
            ctx.saveGState()
            ctx.addPath(roundPath(imageRect, radius: 52))
            ctx.clip()
            icon.draw(in: imageRect)
            ctx.restoreGState()
        }
    }

    private static func drawEmptyGlyph(_ ctx: CGContext) {
        let inner = plateRect.insetBy(dx: 260, dy: 260)
        ctx.setStrokeColor(CGColor(gray: 0.25, alpha: 0.32))
        ctx.setLineWidth(26)
        ctx.addPath(roundPath(inner, radius: 110))
        ctx.strokePath()
    }

    /// Host app icon: a 2x2 grid of translucent glass tiles.
    private static func drawAppGlyph(_ ctx: CGContext) {
        let rects = thumbnailRects(4)
        let palette: [CGColor] = [
            CGColor(red: 0.16, green: 0.46, blue: 0.95, alpha: 0.96),
            CGColor(red: 0.48, green: 0.32, blue: 0.92, alpha: 0.96),
            CGColor(red: 0.10, green: 0.68, blue: 0.72, alpha: 0.96),
            CGColor(red: 0.96, green: 0.45, blue: 0.30, alpha: 0.96)
        ]
        for (i, rect) in rects.enumerated() {
            let inset = rect.insetBy(dx: 26, dy: 26)
            let path = roundPath(inset, radius: 66)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
                          color: CGColor(gray: 0.1, alpha: 0.18))
            ctx.setFillColor(palette[i])
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let gloss = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0.0)] as CFArray,
                locations: [0, 1]
            )
            if let gloss = gloss {
                ctx.drawLinearGradient(gloss,
                                       start: CGPoint(x: inset.minX, y: inset.maxY),
                                       end: CGPoint(x: inset.minX, y: inset.minY),
                                       options: [])
            }
            ctx.restoreGState()
        }
    }

    // MARK: - ICNS output

    static func writeICNS(_ image: NSImage, to dest: URL) {
        let fm = FileManager.default
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let temp = fm.temporaryDirectory
            .appendingPathComponent("dockgroup-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = temp.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        do {
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
            let base = temp.appendingPathComponent("base.png")
            try png.write(to: base)
            let sizes: [(String, Int)] = [
                ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
            ]
            for (name, px) in sizes {
                run("/usr/bin/sips", ["-z", "\(px)", "\(px)", base.path,
                                      "--out", iconset.appendingPathComponent(name).path])
            }
            try? fm.removeItem(at: dest)
            run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", dest.path])
            try? fm.removeItem(at: temp)
        } catch {
            try? fm.removeItem(at: temp)
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
