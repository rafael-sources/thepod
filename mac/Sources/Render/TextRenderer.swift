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

    /// Cintillo tipo noticiero: logo a la izquierda, arriba el título sobre el color, abajo el texto sobre blanco.
    static func cintillo(title: String, text: String, tag: String, accent: NSColor, logo: CGImage?, width: CGFloat, height: CGFloat) -> CIImage? {
        let showLogo = logo != nil || tag != "SEGMENTO"
        let logoW = showLogo ? height : 0
        let topH = height * 0.44, botH = height - topH
        return draw(size: CGSize(width: width, height: height)) { ctx in
            // Barra de color (arriba) y barra blanca (abajo); en Core Graphics y=0 es abajo
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.fill(CGRect(x: logoW, y: 0, width: width - logoW, height: botH))
            ctx.setFillColor(accent.cgColor)
            ctx.fill(CGRect(x: logoW, y: botH, width: width - logoW, height: topH))
            if showLogo {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: logoW, height: height))
                if let logo {
                    let pad = height * 0.08
                    let box = CGRect(x: pad, y: pad, width: logoW - 2 * pad, height: height - 2 * pad)
                    let s = min(box.width / CGFloat(logo.width), box.height / CGFloat(logo.height))
                    let w = CGFloat(logo.width) * s, h = CGFloat(logo.height) * s
                    ctx.interpolationQuality = .high
                    ctx.draw(logo, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
                } else {
                    let ini = NSAttributedString(string: String(title.prefix(1)).uppercased(), attributes: [
                        .font: NSFont.systemFont(ofSize: height * 0.45, weight: .black), .foregroundColor: accent])
                    let l = CTLineCreateWithAttributedString(ini)
                    let b = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
                    ctx.textPosition = CGPoint(x: (logoW - b.width) / 2 - b.minX, y: (height - b.height) / 2 - b.minY)
                    CTLineDraw(l, ctx)
                }
            }
            func line(_ str: String, font: NSFont, color: NSColor, x: CGFloat, maxW: CGFloat, midY: CGFloat) -> CGFloat {
                let a = NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color])
                var l = CTLineCreateWithAttributedString(a)
                let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: color]))
                if let t = CTLineCreateTruncatedLine(l, Double(maxW), .end, dots) { l = t }
                var asc: CGFloat = 0, desc: CGFloat = 0
                let w = CGFloat(CTLineGetTypographicBounds(l, &asc, &desc, nil))
                ctx.textPosition = CGPoint(x: x, y: midY - (asc - desc) / 2)
                CTLineDraw(l, ctx)
                return w
            }
            let pad = height * 0.14
            var x = logoW + pad
            if !tag.isEmpty {
                let f = NSFont.systemFont(ofSize: topH * 0.36, weight: .heavy)
                let tw = (tag as NSString).size(withAttributes: [.font: f]).width
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                ctx.fill(CGRect(x: x, y: botH + topH * 0.2, width: tw + pad * 0.8, height: topH * 0.6))
                _ = line(tag, font: f, color: .white, x: x + pad * 0.4, maxW: tw + 4, midY: botH + topH / 2)
                x += tw + pad * 1.4
            }
            _ = line(title.uppercased(), font: NSFont.systemFont(ofSize: topH * 0.52, weight: .heavy), color: .white,
                     x: x, maxW: width - x - pad, midY: botH + topH / 2)
            _ = line(text, font: NSFont.systemFont(ofSize: botH * 0.42, weight: .semibold), color: .black,
                     x: logoW + pad, maxW: width - logoW - 2 * pad, midY: botH / 2)
        }
    }

    /// Texto de una capa: título con contorno, texto en caja oscura o etiqueta de color.
    static func overlayText(_ text: String, style: VideoLayer.Style, color hex: String, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = 0.95
        let chosen = color(hex) ?? .white
        let bg: NSColor? = {
            switch style {
            case .title: return nil
            case .box: return NSColor.black.withAlphaComponent(0.72)
            case .label: return chosen
            }
        }()
        let fg: NSColor = {
            guard style == .label else { return chosen }
            // Sobre el color de la etiqueta: texto negro o blanco, el que se lea mejor
            let c = chosen.usingColorSpace(.sRGB) ?? chosen
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            return lum > 0.6 ? .black : .white
        }()
        let weight: NSFont.Weight = style == .title ? .black : .bold
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        func build(stroke: Bool) -> NSAttributedString {
            var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
            if stroke { a[.strokeColor] = NSColor.black; a[.strokeWidth] = 14.0; a[.foregroundColor] = NSColor.clear }
            else { a[.foregroundColor] = fg }
            return NSAttributedString(string: trimmed, attributes: a)
        }
        let fill = build(stroke: false)
        let fsetter = CTFramesetterCreateWithAttributedString(fill)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(fsetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let padX = bg != nil ? fontSize * 0.55 : fontSize * 0.3
        let padY = bg != nil ? fontSize * 0.3 : fontSize * 0.3
        let size = CGSize(width: ceil(fit.width + padX * 2), height: ceil(fit.height + padY * 2))
        return draw(size: size) { ctx in
            if let bg {
                ctx.setFillColor(bg.cgColor)
                let r = style == .label ? fontSize * 0.22 : fontSize * 0.35
                ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
            let path = CGPath(rect: CGRect(x: padX, y: padY, width: ceil(fit.width) + 1, height: ceil(fit.height) + 1), transform: nil)
            if style == .title {
                ctx.saveGState()
                ctx.setLineJoin(.round)
                ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.25,
                              color: NSColor.black.withAlphaComponent(0.6).cgColor)
                CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(build(stroke: true)),
                                                     CFRange(location: 0, length: 0), path, nil), ctx)
                ctx.restoreGState()
            }
            CTFrameDraw(CTFramesetterCreateFrame(fsetter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
    }

    /// Sticker: un emoji grande con sombra suave.
    static func sticker(_ emoji: String, fontSize: CGFloat) -> CIImage? {
        let e = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return nil }
        let a = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let line = CTLineCreateWithAttributedString(a)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard b.width > 0, b.height > 0 else { return nil }
        let pad = fontSize * 0.12
        let size = CGSize(width: ceil(b.width + pad * 2), height: ceil(b.height + pad * 2))
        return draw(size: size) { ctx in
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.03), blur: fontSize * 0.08,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.textPosition = CGPoint(x: pad - b.minX, y: pad - b.minY)
            CTLineDraw(line, ctx)
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
