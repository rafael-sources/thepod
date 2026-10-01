import AVFoundation
import CoreImage
import Metal
import Vision

/// Everything the compositor needs to draw a frame. Immutable once built.
final class RenderScene: @unchecked Sendable {
    let renderSize: CGSize
    let format: ExportFormat
    let layout: LayoutTemplate
    let options: LayoutOptions
    let laneOrder: [Int]
    let trackIDs: [Int: CMPersistentTrackID]        // lane → composition video track
    let captions: [CaptionLine]
    let style: CaptionStyle
    let switches: [SpeakerSwitch]
    let names: [Int: (name: String, handle: String?)]
    let photos: [Int: CIImage]
    let showNames: Bool
    let cropX: [Int: Double]
    let mirror: [Int: Bool]
    let logo: CIImage?
    let background: CIImage?
    let title: String
    struct SponsorCard { let start: Double; let end: Double; let name: String; let copy: String?; let logo: CIImage? }
    let sponsorCards: [SponsorCard]
    /// Cintillos del director ya dibujados (se colocan abajo a la izquierda y entran deslizándose).
    struct CintilloCard { let start: Double; let end: Double; let image: CIImage }
    var cintillos: [CintilloCard] = []
    /// Capas (textos, imágenes, stickers) ya dibujadas a su tamaño; centro en fracción del cuadro (y desde arriba).
    struct OverlayCard { let id: Int; let start: Double; let end: Double; let image: CIImage; let cx: Double; let cy: Double; let animate: Bool }
    var overlays: [OverlayCard] = []
    /// Recuadro de cada capa en fracciones del cuadro (x, y desde arriba, ancho, alto), para poder moverla sobre la vista previa.
    func overlayBox(_ id: Int) -> CGRect? {
        guard let c = overlays.first(where: { $0.id == id }) else { return nil }
        let r = overlayRect(c)
        let W = renderSize.width, H = renderSize.height
        return CGRect(x: r.minX / W, y: 1 - r.maxY / H, width: r.width / W, height: r.height / H)
    }
    /// Dónde va la capa (coordenadas de Core Image, y hacia arriba), sin salirse del cuadro.
    func overlayRect(_ c: OverlayCard) -> CGRect {
        let W = renderSize.width, H = renderSize.height
        let w = c.image.extent.width, h = c.image.extent.height
        // Un margen chico para que nada quede pegado al borde (si cabe)
        let m = min(W, H) * 0.03
        let mx = w + 2 * m <= W ? m : 0, my = h + 2 * m <= H ? m : 0
        let x = min(max(mx, CGFloat(c.cx) * W - w / 2), max(0, W - w - mx))
        let y = min(max(my, (1 - CGFloat(c.cy)) * H - h / 2), max(0, H - h - my))
        return CGRect(x: x, y: y, width: w, height: h)
    }
    /// Intro y cierre: imagen fija antes de `contentStart` y después de `contentEnd` (tiempos del video final).
    var contentStart: Double = 0
    var contentEnd: Double = .infinity
    var introImage: CIImage?
    var outroImage: CIImage?
    /// Fondo virtual por persona (lo que va detrás, ya preparado) y calidad de la separación (rápida en la vista previa)
    struct VirtualBG { let mode: VirtualBackground.Mode; let blur: Double; let color: CIColor; let image: CIImage? }
    var virtualBG: [Int: VirtualBG] = [:]
    var fastSegmentation = false

    /// Máscara de la persona (blanco = persona) al tamaño del cuadro, o nil si Vision no pudo.
    private func personMask(_ pb: CVPixelBuffer, extent: CGRect) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = fastSegmentation ? .fast : .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([req])) != nil, let mpb = req.results?.first?.pixelBuffer else { return nil }
        var mask = CIImage(cvPixelBuffer: mpb)
        let sx = extent.width / max(1, mask.extent.width), sy = extent.height / max(1, mask.extent.height)
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        // Borde suave (la máscara viene en baja resolución) y decidida: lo dudoso (< 35 %) es fondo, lo seguro (> 70 %) es persona.
        // Sin esto el fondo nuevo se transparenta sobre la persona cuando Vision no está segura (cámaras oscuras).
        mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: fastSegmentation ? 3.0 : 2.0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.9, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 2.9, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 2.9, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -1.0, y: -1.0, z: -1.0, w: 0)])
            .applyingFilter("CIColorClamp")
        return mask.cropped(to: extent)
    }

    /// Cambia el fondo real de una persona por el elegido.
    func replacedBackground(_ frame: CIImage, buffer: CVPixelBuffer, lane: Int) -> CIImage {
        guard let vb = virtualBG[lane], let mask = personMask(buffer, extent: frame.extent) else { return frame }
        let e = frame.extent
        let behind: CIImage
        switch vb.mode {
        case .blur:
            behind = frame.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: vb.blur]).cropped(to: e)
        case .podcast:
            behind = background.map { fill($0, into: e, cropX: 0.5) } ?? CIImage(color: vb.color).cropped(to: e)
        case .image:
            behind = vb.image.map { fill($0, into: e, cropX: 0.5) } ?? CIImage(color: vb.color).cropped(to: e)
        case .color:
            behind = CIImage(color: vb.color).cropped(to: e)
        }
        return frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: behind, kCIInputMaskImageKey: mask]).cropped(to: e)
    }

    /// Color: filtro general y corrección por persona (igualar cámaras)
    var colorLook = "none"
    var laneGain: [Int: [Double]] = [:]

    func colored(_ img: CIImage, lane: Int) -> CIImage {
        var out = img
        if let g = laneGain[lane], g.count == 3 {
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g[2], w: 0)])
        }
        func matrix(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
            ["inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
             "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0)]
        }
        switch colorLook {
        case "warm": out = out.applyingFilter("CIColorMatrix", parameters: matrix(1.06, 1.0, 0.90))
        case "cool": out = out.applyingFilter("CIColorMatrix", parameters: matrix(0.94, 1.0, 1.08))
        case "cine":
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.82, kCIInputContrastKey: 1.10])
                .applyingFilter("CIColorMatrix", parameters: matrix(1.02, 0.99, 1.04))
        case "bw": out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.08])
        case "vivid": out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputContrastKey: 1.05])
        default: break
        }
        return out.cropped(to: img.extent)
    }

    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    init(renderSize: CGSize, format: ExportFormat, layout: LayoutTemplate, laneOrder: [Int],
         trackIDs: [Int: CMPersistentTrackID], captions: [CaptionLine], style: CaptionStyle,
         switches: [SpeakerSwitch], names: [Int: (name: String, handle: String?)], showNames: Bool,
         cropX: [Int: Double], logo: CIImage?, background: CIImage?, title: String,
         sponsorCards: [SponsorCard] = [], photos: [Int: CIImage] = [:], options: LayoutOptions = LayoutOptions(),
         mirror: [Int: Bool] = [:]) {
        self.sponsorCards = sponsorCards
        self.options = options
        self.mirror = mirror
        self.photos = photos
        self.renderSize = renderSize
        self.format = format
        self.layout = layout
        self.laneOrder = laneOrder
        self.trackIDs = trackIDs
        self.captions = captions
        self.style = style
        self.switches = switches
        self.names = names
        self.showNames = showNames
        self.cropX = cropX
        self.logo = logo
        self.background = background
        self.title = title
    }

    private func cached(_ key: String, _ make: () -> CIImage?) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        guard let img = make() else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = img
        return img
    }

    // MARK: Speaker

    func activeLane(at t: Double) -> (lane: Int, since: Double) {
        var current = switches.first ?? SpeakerSwitch(time: 0, lane: laneOrder.first ?? 1)
        for s in switches {
            if s.time > t + 1e-4 { break }
            current = s
        }
        return (current.lane, current.time)
    }

    // MARK: Frame

    func render(frames: [Int: CIImage], buffers: [Int: CVPixelBuffer] = [:], time time: Double) -> CIImage {
        let W = renderSize.width, H = renderSize.height
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.03)).cropped(to: full)
        // Intro / cierre: la imagen completa (sin recortar) sobre fondo oscuro, con medio segundo de fundido
        if time < contentStart - 1e-3 || time >= contentEnd - 1e-3 {
            let isIntro = time < contentStart
            guard let img = isIntro ? introImage : outroImage else { return dark }
            let edge = isIntro ? min(1, max(0, (contentStart - time) / 0.5)) : min(1, max(0, (time - contentEnd) / 0.5))
            var pic = fit(img, into: full.insetBy(dx: 0, dy: 0)).composited(over: dark)
            if edge < 1 {
                pic = pic.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(edge))]).composited(over: dark)
            }
            return pic.cropped(to: full)
        }
        let t = time - contentStart   // tiempos del contenido (subtítulos, quién habla, cintillos…)
        var out: CIImage = background.map { fill($0, into: full, cropX: 0.5) }
            ?? CIImage(color: CIColor(red: 0.055, green: 0.055, blue: 0.07)).cropped(to: full)

        let visible = laneOrder.filter { frames[$0] != nil }
        let (active, since) = activeLane(at: t)
        let main = visible.contains(active) ? active : visible.first

        var tags: [(lane: Int, rect: CGRect)] = []
        if visible.isEmpty {
            // Audio-only: logo + who is talking
            if let logo {
                let side = min(W, H) * 0.35
                out = fit(logo, into: CGRect(x: (W - side) / 2, y: H * 0.52, width: side, height: side)).composited(over: out)
            }
            let who = names[active]?.name ?? title
            if let img = cached("title-\(who)", { TextRenderer.title(who, fontSize: min(W, H) * 0.07, maxWidth: W * 0.8) }) {
                out = img.transformed(by: .init(translationX: (W - img.extent.width) / 2, y: H * 0.3)).composited(over: out)
            }
        } else {
            let resolved = resolve(layout, count: visible.count)
            let mainLane: Int = {
                // Ventanita con "siempre la primera persona": el grande es la primera pista y la ventanita cambia
                if resolved == .pip, !options.pipFollowSpeaker, let first = visible.first { return first }
                return main ?? visible[0]
            }()
            let rects = panels(for: resolved, lanes: visible, main: mainLane, speaking: main ?? visible[0], in: full, frames: frames)
            for (lane, rect, border) in rects {
                guard var frame = frames[lane] else { continue }
                if virtualBG[lane] != nil, let pb = buffers[lane] { frame = replacedBackground(frame, buffer: pb, lane: lane) }
                if colorLook != "none" || laneGain[lane] != nil { frame = colored(frame, lane: lane) }
                if mirror[lane] == true {
                    // Espejo horizontal, dejando el cuadro donde estaba
                    let e = frame.extent
                    frame = frame.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -(e.minX * 2 + e.width), y: 0))
                }
                var panel = fill(frame, into: rect, cropX: cropX[lane] ?? 0.5)
                if border {
                    let b = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect.insetBy(dx: -4, dy: -4))
                    panel = panel.composited(over: b)
                }
                out = panel.composited(over: out)
                tags.append((lane, rect))
            }
            if showNames {
                let multi = resolved == .sideBySide || resolved == .grid || resolved == .stack || resolved == .studio
                    || (resolved == .solo && options.soloStudio)
                for (lane, rect) in tags {
                    let isMainPanel = lane == main
                    let showThis = multi || (isMainPanel && (t - since < 3.5 || t < 4))
                    guard showThis, let n = names[lane] else { continue }
                    let fs = max(18, min(W, H) * (format.isVertical ? 0.032 : 0.026))
                    guard let tag = cached("tag-\(lane)-\(Int(fs))", { TextRenderer.nameTag(n.name, handle: n.handle, fontSize: fs, photo: photos[lane]) }) else { continue }
                    let margin = min(W, H) * 0.025
                    var y = rect.minY + margin
                    if format.isVertical && !multi { y = rect.minY + H * 0.30 }
                    out = tag.transformed(by: .init(translationX: rect.minX + margin, y: y)).composited(over: out)
                }
            }
        }

        if let logo {
            let h = min(W, H) * 0.085
            let scale = h / max(1, logo.extent.height)
            let w = logo.extent.width * scale
            let m = min(W, H) * 0.03
            let placed = logo.transformed(by: .init(scaleX: scale, y: scale))
            let pos = placed.transformed(by: .init(translationX: W - w - m - placed.extent.minX, y: H - h - m - placed.extent.minY))
            out = pos.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.9)]).composited(over: out)
        }

        for (i, card) in sponsorCards.enumerated() where t >= card.start && t < card.end {
            if let img = cached("sponsor-\(i)-\(Int(W))", { sponsorImage(card) }) {
                let m = min(W, H) * 0.03
                // slide in during the first 0.35 s
                let p = min(1, (t - card.start) / 0.35), q = min(1, (card.end - t) / 0.35)
                let k = CGFloat(min(p, q))
                let x = W - m - img.extent.width * k
                let y = format.isVertical ? H * 0.62 : H - img.extent.height - m - (logo != nil ? min(W, H) * 0.11 : 0)
                out = img.transformed(by: .init(translationX: x, y: y)).composited(over: out)
            }
        }

        // Cintillos del director: abajo a la izquierda, entran desde la izquierda y salen igual
        var cintilloTop: CGFloat = 0
        for c in cintillos where t >= c.start && t < c.end {
            let img = c.image
            let m = min(W, H) * 0.04
            let p = min(1, (t - c.start) / 0.4), q = min(1, (c.end - t) / 0.3)
            let k = CGFloat(1 - pow(1 - min(p, q), 3))
            let x = m - (img.extent.width + m) * (1 - k)
            // Si hay dos a la vez, el segundo va encima del primero (como en vivo)
            let y = max(format.isVertical ? H * 0.30 : m, cintilloTop > 0 ? cintilloTop + m * 0.4 : 0)
            out = img.transformed(by: .init(translationX: x, y: y)).composited(over: out)
            cintilloTop = max(cintilloTop, y + img.extent.height)
        }

        // Capas del usuario: encima del video y de los cintillos, debajo de los subtítulos
        for c in overlays where t >= c.start && t < c.end {
            let r = overlayRect(c)
            var img = c.image.transformed(by: .init(translationX: -c.image.extent.minX, y: -c.image.extent.minY))
            if c.animate {
                let k = min(1, (t - c.start) / 0.3, (c.end - t) / 0.3)
                if k < 1 {
                    let s = CGFloat(0.85 + 0.15 * (1 - pow(1 - k, 3)))
                    img = img.transformed(by: CGAffineTransform(translationX: -r.width / 2, y: -r.height / 2)
                        .concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: r.width / 2, y: r.height / 2)))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(k))])
                }
            }
            out = img.transformed(by: .init(translationX: r.minX, y: r.minY)).composited(over: out)
        }

        if style.enabled, let (idx, line) = caption(at: t) {
            let active = line.words.lastIndex { $0.start <= t + 0.02 }
            let base = min(W, H)
            let factor: CGFloat
            switch style.size {
            case .small: factor = format.isVertical ? 0.058 : 0.045
            case .medium: factor = format.isVertical ? 0.075 : 0.057
            case .large: factor = format.isVertical ? 0.095 : 0.072
            }
            let fs = base * factor
            let key = "cap-\(idx)-\(active ?? -1)-\(Int(fs))"
            if let img = cached(key, { TextRenderer.caption(line, activeWord: active, style: style, fontSize: fs, maxWidth: W * 0.86) }) {
                let x = (W - img.extent.width) / 2
                let y: CGFloat
                switch style.position {
                case .bottom: y = max(format.isVertical ? H * 0.20 : H * 0.07, cintilloTop > 0 && !format.isVertical ? cintilloTop + H * 0.03 : 0)
                case .center: y = (H - img.extent.height) / 2 - (format.isVertical ? H * 0.05 : 0)
                case .top: y = H - img.extent.height - H * (format.isVertical ? 0.14 : 0.07)
                }
                out = img.transformed(by: .init(translationX: x, y: y)).composited(over: out)
            }
        }
        return out.cropped(to: full)
    }

    private func sponsorImage(_ card: SponsorCard) -> CIImage? {
        let W = renderSize.width, H = renderSize.height
        let fs = max(18, min(W, H) * (format.isVertical ? 0.03 : 0.028))
        guard let text = TextRenderer.sponsorText(name: card.name, copy: card.copy, fontSize: fs, maxWidth: W * (format.isVertical ? 0.6 : 0.3)) else { return nil }
        let pad = fs * 0.6
        var logoImg: CIImage?
        var logoW: CGFloat = 0
        if let logo = card.logo {
            let h = max(text.extent.height, fs * 2.4)
            let s = h / max(1, logo.extent.height)
            logoImg = logo.transformed(by: .init(scaleX: s, y: s))
            logoW = logo.extent.width * s
        }
        let w = pad * 2 + logoW + (logoImg != nil ? pad : 0) + text.extent.width
        let h = pad * 2 + max(text.extent.height, logoImg?.extent.height ?? 0)
        let box = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.68)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let accent = CIImage(color: CIColor(red: 1, green: 0.78, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: fs * 0.18, height: h))
        var out = accent.composited(over: box)
        if let li = logoImg {
            out = li.transformed(by: .init(translationX: pad - li.extent.minX, y: (h - li.extent.height) / 2 - li.extent.minY)).composited(over: out)
        }
        let tx = pad + logoW + (logoImg != nil ? pad : 0)
        out = text.transformed(by: .init(translationX: tx, y: (h - text.extent.height) / 2)).composited(over: out)
        return out
    }

    private func caption(at t: Double) -> (Int, CaptionLine)? {
        // binary search on start
        var lo = 0, hi = captions.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if captions[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, t < captions[found].end else { return nil }
        return (found, captions[found])
    }

    // MARK: Layout

    func resolve(_ l: LayoutTemplate, count: Int) -> LayoutTemplate {
        if count <= 1 && l != .studio { return .solo }   // con 1 persona, "Quien habla" (y su marco de estudio si está activo)
        switch l {
        case .auto:
            switch format {
            case .vertical, .square: return .solo
            default: return count == 2 ? .sideBySide : .grid
            }
        default: return l
        }
    }

    /// `main` = quien va en grande; `speaking` = quien habla ahora (para elegir la ventanita cuando no coinciden).
    private func panels(for layout: LayoutTemplate, lanes: [Int], main: Int, speaking: Int, in full: CGRect,
                        frames: [Int: CIImage] = [:])
        -> [(lane: Int, rect: CGRect, border: Bool)] {
        let W = full.width, H = full.height
        let others = lanes.filter { $0 != main }
        switch layout {
        case .solo, .auto:
            if options.soloStudio {
                // Un solo recuadro con marco sobre el fondo del podcast: el video entra completo (sin recortar),
                // así el fondo rellena lo que sobre arriba/abajo o a los lados.
                let m = min(W, H) * 0.06
                let area = CGRect(x: m, y: m, width: W - 2 * m, height: H - 2 * m)
                let e = frames[main]?.extent ?? CGRect(x: 0, y: 0, width: 16, height: 9)
                let s = min(area.width / max(1, e.width), area.height / max(1, e.height))
                let w = e.width * s, h = e.height * s
                return [(main, CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h), true)]
            }
            return [(main, full, false)]
        case .studio:
            let m = min(W, H) * 0.06
            let gap = min(W, H) * 0.025
            let n = CGFloat(lanes.count)
            if format.isVertical {
                let h = (H * 0.72 - gap * (n - 1)) / n
                let top = H * 0.86
                return lanes.enumerated().map { (i, l) in
                    (l, CGRect(x: m, y: top - CGFloat(i + 1) * h - CGFloat(i) * gap, width: W - 2 * m, height: h), true)
                }
            }
            let w = (W - 2 * m - gap * (n - 1)) / n
            let h = min(H * 0.72, w * 1.1)
            let y = (H - h) / 2 - H * 0.03
            return lanes.enumerated().map { (i, l) in
                (l, CGRect(x: m + CGFloat(i) * (w + gap), y: y, width: w, height: h), true)
            }
        case .sideBySide:
            let w = W / CGFloat(lanes.count)
            return lanes.enumerated().map { (i, l) in (l, CGRect(x: CGFloat(i) * w, y: 0, width: w, height: H), false) }
        case .stack:
            let h = H / CGFloat(lanes.count)
            if !format.isVertical {
                // En horizontal una franja a todo el ancho recortaría cada cara a una tira: cada video conserva
                // su forma, centrado en su franja, con marco, y el fondo del podcast ocupa los lados.
                let gap = min(W, H) * 0.02
                return lanes.enumerated().map { (i, l) in
                    let band = CGRect(x: 0, y: H - CGFloat(i + 1) * h, width: W, height: h).insetBy(dx: gap, dy: gap)
                    let e = frames[l]?.extent ?? CGRect(x: 0, y: 0, width: 16, height: 9)
                    let sc = min(band.width / max(1, e.width), band.height / max(1, e.height))
                    let w = e.width * sc, hh = e.height * sc
                    return (l, CGRect(x: band.midX - w / 2, y: band.midY - hh / 2, width: w, height: hh), true)
                }
            }
            return lanes.enumerated().map { (i, l) in (l, CGRect(x: 0, y: H - CGFloat(i + 1) * h, width: W, height: h), false) }
        case .grid:
            if options.gridSpeakerBig, !others.isEmpty {
                // Quien habla en grande arriba; los demás en una fila de cuadritos abajo
                let gap = min(W, H) * 0.02
                let rowH = H * 0.30
                let bigH = H - rowH
                var out = [(main, CGRect(x: 0, y: rowH, width: W, height: bigH).insetBy(dx: gap, dy: gap), true)]
                let n = CGFloat(others.count)
                let cellW = min((W - gap * (n + 1)) / n, (rowH - 2 * gap) * 16 / 9)
                let totalW = cellW * n + gap * (n - 1)
                let x0 = (W - totalW) / 2
                for (i, l) in others.enumerated() {
                    out.append((l, CGRect(x: x0 + CGFloat(i) * (cellW + gap), y: gap, width: cellW, height: rowH - 2 * gap), true))
                }
                return out
            }
            let cols = 2
            let rows = Int(ceil(Double(lanes.count) / Double(cols)))
            let w = W / CGFloat(cols), h = H / CGFloat(rows)
            return lanes.enumerated().map { (i, l) in
                let r = i / cols, c = i % cols
                let inRow = min(cols, lanes.count - r * cols)
                let xOff = inRow < cols ? (W - CGFloat(inRow) * w) / 2 : 0
                return (l, CGRect(x: xOff + CGFloat(c) * w, y: H - CGFloat(r + 1) * h, width: w, height: h), false)
            }
        case .spotlight:
            if format.isVertical {
                let mainH = H * 0.7
                var out = [(main, CGRect(x: 0, y: H - mainH, width: W, height: mainH), false)]
                for (i, l) in others.enumerated() {
                    let w = W / CGFloat(others.count)
                    out.append((l, CGRect(x: CGFloat(i) * w, y: 0, width: w, height: H - mainH), false))
                }
                return out
            }
            let mainW = W * 0.7
            let h = H / CGFloat(max(1, others.count))
            var out = [(main, CGRect(x: 0, y: 0, width: mainW, height: H), false)]
            for (i, l) in others.enumerated() {
                out.append((l, CGRect(x: mainW, y: H - CGFloat(i + 1) * h, width: W - mainW, height: h), false))
            }
            return out
        case .pip:
            var out = [(main, full, false)]
            // Ventanita: el primero que NO está en grande; si hay varios, preferir al que habla (si no es el grande)
            let pipLane = (speaking != main && others.contains(speaking)) ? speaking : others.first
            if let other = pipLane {
                let w = W * (format.isVertical ? 0.36 : 0.26)
                let h = format.isVertical ? w * 1.25 : w * 9 / 16
                let m = min(W, H) * 0.035
                out.append((other, CGRect(x: W - w - m, y: format.isVertical ? H * 0.62 : m, width: w, height: h), true))
            }
            return out
        }
    }

    // MARK: Image helpers

    /// Aspect-fill `img` into `rect`, keeping `cropX` (0…1) of the source horizontally centered.
    func fill(_ img: CIImage, into rect: CGRect, cropX: Double) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0 else { return img }
        let s = max(rect.width / e.width, rect.height / e.height)
        let scaledW = e.width * s, scaledH = e.height * s
        var dx = rect.midX - (e.minX * s + scaledW * CGFloat(cropX))
        dx = min(rect.minX - e.minX * s, max(rect.maxX - (e.minX * s + scaledW), dx))
        let dy = rect.midY - (e.minY * s + scaledH / 2)
        return img.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(.init(translationX: dx, y: dy)))
            .cropped(to: rect)
    }

    func fit(_ img: CIImage, into rect: CGRect) -> CIImage {
        let e = img.extent
        guard e.width > 0, e.height > 0 else { return img }
        let s = min(rect.width / e.width, rect.height / e.height)
        let w = e.width * s, h = e.height * s
        return img.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(.init(translationX: rect.midX - w / 2 - e.minX * s, y: rect.midY - h / 2 - e.minY * s)))
    }
}

// MARK: - Instruction

final class PodInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let scene: RenderScene

    init(timeRange: CMTimeRange, scene: RenderScene) {
        self.timeRange = timeRange
        self.scene = scene
        self.requiredSourceTrackIDs = scene.trackIDs.values.map { NSNumber(value: $0) }
    }
}

// MARK: - Compositor

final class PodCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let ciContext: CIContext = {
        if let d = device { return CIContext(mtlDevice: d, options: [.cacheIntermediates: false]) }
        return CIContext()
    }()
    private let queue = DispatchQueue(label: "postpod.compositor", qos: .userInitiated)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? PodInstruction,
                      let out = request.renderContext.newPixelBuffer() else {
                    request.finish(with: NSError(domain: "postpod.compositor", code: 1))
                    return
                }
                let scene = instruction.scene
                // Modo tranquilo: si la Mac está caliente, ir más despacio en vez de forzar los ventiladores
                switch ProcessInfo.processInfo.thermalState {
                case .serious: usleep(12_000)
                case .critical: usleep(35_000)
                default: break
                }
                var frames: [Int: CIImage] = [:]
                var buffers: [Int: CVPixelBuffer] = [:]
                for (lane, tid) in scene.trackIDs {
                    if let pb = request.sourceFrame(byTrackID: tid) {
                        frames[lane] = CIImage(cvPixelBuffer: pb)
                        buffers[lane] = pb
                    }
                }
                let image = scene.render(frames: frames, buffers: buffers, time: request.compositionTime.seconds)
                Self.ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: scene.renderSize), colorSpace: self.colorSpace)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }
}
