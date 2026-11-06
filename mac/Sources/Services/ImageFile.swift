import AppKit
import CoreImage

/// Project image loading. Logos coming from prePod are sometimes SVG with a .png extension:
/// NSImage opens them by content, and here they're converted to bitmaps for Core Image / Core Graphics.
enum ImageFile {
    static func nsImage(_ url: URL) -> NSImage? {
        if let img = NSImage(contentsOf: url), img.isValid, img.size.width > 0 { return img }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let img = NSImage(data: data), img.isValid, img.size.width > 0 { return img }
        return nil
    }

    /// CGImage of up to 1024 px per side (SVGs are drawn at that size).
    static func cgImage(_ img: NSImage, maxSide: CGFloat = 1024) -> CGImage? {
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 1, cg.height > 1,
           img.representations.contains(where: { $0 is NSBitmapImageRep }) {
            return cg
        }
        let sz = img.size
        guard sz.width > 0, sz.height > 0 else { return nil }
        let s = min(1, maxSide / max(sz.width, sz.height)) * (max(sz.width, sz.height) < maxSide ? maxSide / max(sz.width, sz.height) : 1)
        let w = Int(sz.width * s), h = Int(sz.height * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func ciImage(_ url: URL) -> CIImage? {
        if let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), ci.extent.width > 0 { return ci }
        guard let img = nsImage(url), let cg = cgImage(img) else { return nil }
        return CIImage(cgImage: cg)
    }
}
