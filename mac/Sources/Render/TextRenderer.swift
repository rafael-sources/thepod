import AppKit
import CoreImage
import CoreText

/// Renders caption lines and name tags into CIImages with Core Text.
enum TextRenderer {
    static func registerBundledFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ name: String, size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .heavy)
    }

    static func color(_ hex: String?, alpha: CGFloat = 1) -> NSColor? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    /// Caption line with the active word highlighted (karaoke).
    static func caption(_ line: CaptionLine, activeWord: Int?, style: CaptionStyle,
                        fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let font = font(style.fontName, size: fontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = 0.95

        let textColor = color(style.textColor) ?? .white
        let hiColor = color(style.highlightColor) ?? .yellow
        let outline = color(style.outlineColor) ?? .black

        func build(stroke: Bool) -> NSAttributedString {
            let s = NSMutableAttributedString()
            for (i, w) in line.words.enumerated() {
                let isActive = style.karaoke && i == activeWord
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
                if stroke {
                    attrs[.strokeColor] = outline
                    attrs[.strokeWidth] = 14.0
                    attrs[.foregroundColor] = NSColor.clear
                } else {
                    attrs[.foregroundColor] = isActive ? hiColor : textColor
                }
                s.append(NSAttributedString(string: (i == 0 ? "" : " ") + w.text, attributes: attrs))
            }
            return s
        }

        let fill = build(stroke: false)
        let hasOutline = style.backgroundColor == nil
        let framesetter = CTFramesetterCreateWithAttributedString(fill)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let pad = fontSize * 0.45
        let size = CGSize(width: ceil(fit.width + pad * 2), height: ceil(fit.height + pad * 2))
        return draw(size: size) { ctx in
            if let bg = color(style.backgroundColor, alpha: 0.82) {
                let r = CGRect(origin: .zero, size: size).insetBy(dx: pad * 0.2, dy: pad * 0.2)
                ctx.setFillColor(bg.cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: fontSize * 0.3, cornerHeight: fontSize * 0.3, transform: nil))
                ctx.fillPath()
            }
            let path = CGPath(rect: CGRect(x: pad, y: pad, width: ceil(fit.width) + 1, height: ceil(fit.height) + 1), transform: nil)
            ctx.setLineJoin(.round)
            if hasOutline {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.25,
                              color: NSColor.black.withAlphaComponent(0.6).cgColor)
                let strokeFS = CTFramesetterCreateWithAttributedString(build(stroke: true))
                CTFrameDraw(CTFramesetterCreateFrame(strokeFS, CFRange(location: 0, length: 0), path, nil), ctx)
                ctx.restoreGState()
            }
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
    }

    /// Lower-third style name tag: name (+ optional handle).
    static func nameTag(_ name: String, handle: String?, fontSize: CGFloat, photo: CIImage? = nil) -> CIImage? {
        let nameAttr = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white])
        let handleAttr = handle.map { NSAttributedString(string: "  " + $0, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize * 0.8, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75)]) }
        let full = NSMutableAttributedString(attributedString: nameAttr)
        if let handleAttr { full.append(handleAttr) }
        let line = CTLineCreateWithAttributedString(full)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padX = fontSize * 0.7, padY = fontSize * 0.42
        let height = ceil(fontSize * 1.25 + padY * 2)
        // Con foto: un círculo con la cara a la izquierda, dentro de la píldora.
        let photoCG = photo.flatMap { CIContext().createCGImage($0, from: $0.extent) }
        let photoD = height - fontSize * 0.3
        let lead = photoCG != nil ? photoD + fontSize * 0.35 : 0
        let size = CGSize(width: ceil(bounds.width + padX * 2 + lead), height: height)
        return draw(size: size) { ctx in
            let r = CGRect(origin: .zero, size: size)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil))
            ctx.fillPath()
            if let cg = photoCG {
                let c = CGRect(x: fontSize * 0.15, y: fontSize * 0.15, width: photoD, height: photoD)
                // recorte cuadrado centrado de la foto, dentro de un círculo
                let side = CGFloat(min(cg.width, cg.height))
                let crop = CGRect(x: (CGFloat(cg.width) - side) / 2, y: (CGFloat(cg.height) - side) / 2, width: side, height: side)
                ctx.saveGState()
                ctx.addEllipse(in: c); ctx.clip()
                if let sq = cg.cropping(to: crop) { ctx.draw(sq, in: c) }
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: padX * 0.45, y: size.height / 2 - fontSize * 0.15, width: fontSize * 0.3, height: fontSize * 0.3))
            }
            ctx.textPosition = CGPoint(x: padX + fontSize * 0.1 + lead, y: padY + fontSize * 0.28)
            CTLineDraw(line, ctx)
        }
    }

    /// Sponsor card text: "PATROCINA" kicker, name, and optional copy line.
    static func sponsorText(name: String, copy: String?, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let s = NSMutableAttributedString(string: "PATROCINA\n", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize * 0.55, weight: .heavy),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.78, blue: 0.2, alpha: 1), .kern: 1.5, .paragraphStyle: para])
        s.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para]))
        if let copy, !copy.isEmpty {
            s.append(NSAttributedString(string: "\n" + copy, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize * 0.7, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para]))
        }
        let fs = CTFramesetterCreateWithAttributedString(s)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let size = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height) + 2)
        return draw(size: size) { ctx in
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(origin: CGPoint(x: 1, y: 1), size: fit), transform: nil), nil), ctx)
        }
    }

    /// Title card text (audio-only video, empty frames).
    static func title(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para])
        let fs = CTFramesetterCreateWithAttributedString(s)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let size = CGSize(width: ceil(fit.width) + 4, height: ceil(fit.height) + 4)
        return draw(size: size) { ctx in
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(origin: CGPoint(x: 2, y: 2), size: fit), transform: nil), nil), ctx)
        }
    }

    private static func draw(size: CGSize, _ body: (CGContext) -> Void) -> CIImage? {
        guard size.width >= 1, size.height >= 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        body(ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
