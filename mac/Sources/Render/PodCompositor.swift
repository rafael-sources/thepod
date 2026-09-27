import AVFoundation
import CoreImage
import Metal

/// Everything the compositor needs to draw a frame. Immutable once built.
final class RenderScene: @unchecked Sendable {
    let renderSize: CGSize
    let format: ExportFormat
    let layout: LayoutTemplate
    let laneOrder: [Int]
    let trackIDs: [Int: CMPersistentTrackID]        // lane → composition video track
    let captions: [CaptionLine]
    let style: CaptionStyle
    let switches: [SpeakerSwitch]
    let names: [Int: (name: String, handle: String?)]
    let showNames: Bool
    let cropX: [Int: Double]
    let logo: CIImage?
    let background: CIImage?
    let title: String

    private var cache: [String: CIImage] = [:]
    private let lock = NSLock()

    init(renderSize: CGSize, format: ExportFormat, layout: LayoutTemplate, laneOrder: [Int],
         trackIDs: [Int: CMPersistentTrackID], captions: [CaptionLine], style: CaptionStyle,
         switches: [SpeakerSwitch], names: [Int: (name: String, handle: String?)], showNames: Bool,
         cropX: [Int: Double], logo: CIImage?, background: CIImage?, title: String) {
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

    func render(frames: [Int: CIImage], time t: Double) -> CIImage {
        let W = renderSize.width, H = renderSize.height
        let full = CGRect(x: 0, y: 0, width: W, height: H)
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
            let rects = panels(for: resolved, lanes: visible, main: main ?? visible[0], in: full)
            for (lane, rect, border) in rects {
                guard let frame = frames[lane] else { continue }
                var panel = fill(frame, into: rect, cropX: cropX[lane] ?? 0.5)
                if border {
                    let b = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect.insetBy(dx: -4, dy: -4))
                    panel = panel.composited(over: b)
                }
                out = panel.composited(over: out)
                tags.append((lane, rect))
            }
            if showNames {
                let multi = resolved == .sideBySide || resolved == .grid || resolved == .stack
                for (lane, rect) in tags {
                    let isMainPanel = lane == main
                    let showThis = multi || (isMainPanel && (t - since < 3.5 || t < 4))
                    guard showThis, let n = names[lane] else { continue }
                    let fs = max(18, min(W, H) * (format.isVertical ? 0.032 : 0.026))
                    guard let tag = cached("tag-\(lane)-\(Int(fs))", { TextRenderer.nameTag(n.name, handle: n.handle, fontSize: fs) }) else { continue }
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
                case .bottom: y = format.isVertical ? H * 0.20 : H * 0.07
                case .center: y = (H - img.extent.height) / 2 - (format.isVertical ? H * 0.05 : 0)
                case .top: y = H - img.extent.height - H * (format.isVertical ? 0.14 : 0.07)
                }
                out = img.transformed(by: .init(translationX: x, y: y)).composited(over: out)
            }
        }
        return out.cropped(to: full)
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
        if count <= 1 { return .solo }
        switch l {
        case .auto:
            switch format {
            case .vertical, .square: return .solo
            default: return count == 2 ? .sideBySide : .grid
            }
        default: return l
        }
    }

    private func panels(for layout: LayoutTemplate, lanes: [Int], main: Int, in full: CGRect)
        -> [(lane: Int, rect: CGRect, border: Bool)] {
        let W = full.width, H = full.height
        let others = lanes.filter { $0 != main }
        switch layout {
        case .solo, .auto:
            return [(main, full, false)]
        case .sideBySide:
            let w = W / CGFloat(lanes.count)
            return lanes.enumerated().map { (i, l) in (l, CGRect(x: CGFloat(i) * w, y: 0, width: w, height: H), false) }
        case .stack:
            let h = H / CGFloat(lanes.count)
            return lanes.enumerated().map { (i, l) in (l, CGRect(x: 0, y: H - CGFloat(i + 1) * h, width: W, height: h), false) }
        case .grid:
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
            if let other = others.first {
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
                var frames: [Int: CIImage] = [:]
                for (lane, tid) in scene.trackIDs {
                    if let pb = request.sourceFrame(byTrackID: tid) {
                        frames[lane] = CIImage(cvPixelBuffer: pb)
                    }
                }
                let image = scene.render(frames: frames, time: request.compositionTime.seconds)
                Self.ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: scene.renderSize), colorSpace: self.colorSpace)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }
}
