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
    /// Director lower thirds already drawn (placed at bottom left and sliding in).
    struct CintilloCard {
        let start: Double; let end: Double; let image: CIImage
        var base: CIImage? = nil      // without text (for the wipe on entering)
        var logoW: CGFloat = 0        // width of the logo box (appears first, with a bounce)
        var style: String = "news"
        var sound = true
    }
    var cintillos: [CintilloCard] = []
    /// Layers (texts, images, stickers) already drawn at their size; center as a frame fraction (from the top).
    struct OverlayCard {
        let id: Int; let start: Double; let end: Double; let image: CIImage; let cx: Double; let cy: Double; let animate: Bool
        /// Studio · Video: keyframes (already in final video time) and the size the image was drawn at.
        var anim: LayerAnimation? = nil
        var baseScale: Double = 1
        var enter: TitleMotion? = nil
        var exit: TitleMotion? = nil
    }

    /// A layer's in or out: `k` goes from 0 (out) to 1 (in place). Works on the image already placed in
    /// its box `r` (origin 0,0 = the box's bottom-left corner).
    static func motion(_ img: CIImage, kind: TitleMotion.Kind, k: Double, r: CGRect, H: CGFloat) -> CIImage {
        let e = CGFloat(1 - pow(1 - max(0, min(1, k)), 3))     // eases out
        let alpha = { (i: CIImage, a: CGFloat) in i.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)]) }
        switch kind {
        case .fade:
            return alpha(img, e)
        case .rise:
            return alpha(img.transformed(by: .init(translationX: 0, y: -(r.height * 0.6 + H * 0.03) * (1 - e))), e)
        case .drop:
            return alpha(img.transformed(by: .init(translationX: 0, y: (r.height * 0.6 + H * 0.03) * (1 - e))), e)
        case .grow:
            let s = 0.6 + 0.4 * e
            return alpha(img.transformed(by: CGAffineTransform(translationX: -r.width / 2, y: -r.height / 2).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: r.width / 2, y: r.height / 2))), e)
        case .reveal:
            // Typed left to right (linear, like a typewriter)
            return img.cropped(to: CGRect(x: 0, y: -4, width: max(0, r.width * CGFloat(k)) + 1, height: r.height + 8))
        case .wipe:
            // A bar in the text color sweeps and leaves the text behind
            let x = r.width * e
            let shown = img.cropped(to: CGRect(x: 0, y: -4, width: max(0, x) + 1, height: r.height + 8))
            guard e < 1 else { return shown }
            let bar = CIImage(color: CIColor(red: 0.957, green: 0.780, blue: 0.439)).cropped(to: CGRect(x: x, y: 0, width: max(2, r.height * 0.08), height: r.height))
            return bar.composited(over: shown)
        }
    }
    var overlays: [OverlayCard] = []
    /// Each layer's box in frame fractions (x, y from the top, width, height), so it can be moved over the preview.
    func overlayBox(_ id: Int, at t: Double? = nil) -> CGRect? {
        guard let c = overlays.first(where: { $0.id == id }) else { return nil }
        let r = overlayRect(c, at: t.map { $0 - contentStart })
        let W = renderSize.width, H = renderSize.height
        return CGRect(x: r.minX / W, y: 1 - r.maxY / H, width: r.width / W, height: r.height / H)
    }
    /// Where the layer goes (Core Image coordinates, y up), without leaving the frame. With `t` (content
    /// time) it follows its position and size keyframes.
    func overlayRect(_ c: OverlayCard, at t: Double? = nil) -> CGRect {
        let W = renderSize.width, H = renderSize.height
        var cx = c.cx, cy = c.cy, s = 1.0
        if let t, let a = c.anim {
            cx = a.value(LayerAnimation.x, at: t) ?? cx
            cy = a.value(LayerAnimation.y, at: t) ?? cy
            if let k = a.value(LayerAnimation.scale, at: t), c.baseScale > 0 { s = max(0.05, k / c.baseScale) }
        }
        let w = c.image.extent.width * s, h = c.image.extent.height * s
        // A small margin so nothing sits against the edge (if it fits). With keyframes the layer may leave the
        // frame on purpose (enter from outside), so it isn't clamped there.
        if c.anim?.isEmpty == false {
            return CGRect(x: CGFloat(cx) * W - w / 2, y: (1 - CGFloat(cy)) * H - h / 2, width: w, height: h)
        }
        let m = min(W, H) * 0.03
        let mx = w + 2 * m <= W ? m : 0, my = h + 2 * m <= H ? m : 0
        let x = min(max(mx, CGFloat(cx) * W - w / 2), max(0, W - w - mx))
        let y = min(max(my, (1 - CGFloat(cy)) * H - h / 2), max(0, H - h - my))
        return CGRect(x: x, y: y, width: w, height: h)
    }
    /// Audiogram: voice level 0…1 per person every 100 ms (content time). Empty = off.
    var audiogram: [Int: [Float]] = [:]
    /// Voice level at `t` interpolated between steps (so the waves don't jerk).
    func voiceLevel(_ lane: Int, at t: Double) -> CGFloat {
        guard let arr = audiogram[lane], !arr.isEmpty else { return 0 }
        let x = max(0, t / 0.1), i = Int(x), f = CGFloat(x - Double(i))
        let a = arr[min(arr.count - 1, i)], b = arr[min(arr.count - 1, i + 1)]
        return CGFloat(a) + (CGFloat(b) - CGFloat(a)) * f
    }
    /// Dynamic punch-in: zoom factor per person every 100 ms (content time). Empty = off.
    var punchIn: [Int: [Float]] = [:]
    func punch(_ lane: Int, at t: Double) -> CGFloat {
        guard let arr = punchIn[lane], !arr.isEmpty else { return 1 }
        let i = max(0, min(arr.count - 1, Int(t / 0.1)))
        return CGFloat(arr[i])
    }
    /// Studio · Video: camera spans pinned by hand (final video content time).
    struct CameraSpan { let start: Double; let end: Double; let lane: Int?; let template: LayoutTemplate? }
    var cameraSpans: [CameraSpan] = []
    func cameraSpan(at t: Double) -> CameraSpan? { cameraSpans.first { t >= $0.start && t < $0.end } }
    /// Intro and outro: still image before `contentStart` and after `contentEnd` (final video times).
    var contentStart: Double = 0
    var contentEnd: Double = .infinity
    var introImage: CIImage?
    var outroImage: CIImage?
    /// B-roll: video track (or still image) covering the screen between `start` and `end` (final video times).
    struct BRoll {
        let trackID: CMPersistentTrackID?; let image: CIImage?; let start: Double; let end: Double; let fill: Bool; let placement: String
        var transform: CGAffineTransform = .identity     // the track's preferredTransform (rotation of phone videos)
        var transition: Transition? = nil                // Studio · Video: how it enters (nil = short fade)
        var grade: ColorGrade? = nil                     // Studio · Video: color for this clip only
    }
    var brolls: [BRoll] = []

    /// Virtual background per person (what goes behind, already prepared) and segmentation quality (fast in the preview)
    struct VirtualBG { let mode: VirtualBackground.Mode; let blur: Double; let color: CIColor; let image: CIImage? }
    var virtualBG: [Int: VirtualBG] = [:]
    var fastSegmentation = false

    /// The person's mask (white = person) at frame size, or nil if Vision couldn't.
    private var lastMask: [Int: CIImage] = [:]        // previous frame's mask per person (so it doesn't shimmer)
    private var lastMaskTime: [Int: Double] = [:]
    private static let maskContext = CIContext(options: [.cacheIntermediates: false])

    /// The person's mask (white = person) at frame size, or nil if Vision couldn't.
    /// Against artifacts: high quality when exporting, small holes are filled, soft edge,
    /// and it's blended with the previous frame's mask so the edge doesn't shimmer between frames.
    private func personMask(_ pb: CVPixelBuffer, extent: CGRect, lane: Int, time: Double) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = fastSegmentation ? .fast : .balanced   // .accurate gives less confidence on dark cameras (the person turns see-through)
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([req])) != nil, let mpb = req.results?.first?.pixelBuffer else {
            // If the person couldn't be separated in a frame, the previous mask is used (that frame used to show
            // the real background: a flicker). Only if it's recent.
            if let prev = lastMask[lane], let pt = lastMaskTime[lane], abs(time - pt) < 0.5 { return finish(prev, extent: extent) }
            return nil
        }
        var mask = CIImage(cvPixelBuffer: mpb)
        let native = mask.extent
        let r: CGFloat = fastSegmentation ? 1.5 : 2.5
        // 1) Fill small holes (headphones, hands, hair): close = dilate then erode
        mask = mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
            .cropped(to: native)
        // 2) Blend with the previous frame (if it's the next frame, not a jump). Where the mask barely changed
        //    it's averaged half and half (the edge stops shimmering: that was the flicker); where it changed a lot (the person
        //    moved) the new frame wins, so no trail is left.
        //    CIMix also blends alpha; adding the two images doubled the alpha and the mask dropped to half.
        if let prev = lastMask[lane], let pt = lastMaskTime[lane], time - pt < 0.2, time > pt, prev.extent == native {
            let calm = mask.applyingFilter("CIMix", parameters: [kCIInputBackgroundImageKey: prev, "inputAmount": 0.5]).cropped(to: native)
            let moved = mask.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: prev])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 6, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 6, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: -0.6, y: -0.6, z: -0.6, w: 0)])
                .applyingFilter("CIColorClamp")
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: native)
            mask = mask.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: calm, kCIInputMaskImageKey: moved]).cropped(to: native)
        }
        // Store the computed mask as a flat single-channel image, without color management
        // (passing it through an sRGB CGImage darkened it frame by frame and the person turned see-through).
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(native.width), Int(native.height), kCVPixelFormatType_OneComponent8, nil, &out)
        if let out {
            Self.maskContext.render(mask, to: out, bounds: native, colorSpace: nil)
            lastMask[lane] = CIImage(cvPixelBuffer: out)
            lastMaskTime[lane] = time
        }
        return finish(mask, extent: extent)
    }

    /// The mask at the frame's size and position, with a soft, decisive edge.
    private func finish(_ m: CIImage, extent: CGRect) -> CIImage {
        var mask = m
        let native = m.extent
        // 3) At frame size, soft and decisive edge: the doubtful (< 35 %) is background, the sure (> 70 %) is person.
        //    Also in place: if the frame doesn't start at 0,0 (rotated videos) the mask was offset and left
        //    a strip of background on one side.
        let sx = extent.width / max(1, native.width), sy = extent.height / max(1, native.height)
        mask = mask.transformed(by: CGAffineTransform(translationX: -native.minX, y: -native.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
        let feather = max(1.5, min(extent.width, extent.height) * (fastSegmentation ? 0.006 : 0.004))
        mask = mask.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.9, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 2.9, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 2.9, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -1.0, y: -1.0, z: -1.0, w: 0)])
            .applyingFilter("CIColorClamp")
        return mask.cropped(to: extent)
    }

    // MARK: Green screen
    //
    // If the person recorded with a green background, person segmentation leaves a green edge (green bounces
    // off hair and shoulders, and the mask doesn't cut right there). With a green background the cut is by color, which is
    // exact, and the green spill is removed from the person.

    private var greenLane: [Int: Bool] = [:]
    private var greenCheckedAt: [Int: Double] = [:]

    /// «How much greener than red and blue»: 1 = person, 0 = green background (with a smooth transition between lo and hi).
    private static let keyKernel = CIColorKernel(source: """
        kernel vec4 thepodKey(__sample s, float lo, float hi) {
            float k = s.g - max(s.r, s.b);
            float bg = smoothstep(lo, hi, k);
            return vec4(1.0 - bg, 1.0 - bg, 1.0 - bg, 1.0);
        }
        """)
    /// Removes green spill: green never exceeds the larger of red and blue (doesn't touch skin, yellows or grays).
    private static let despillKernel = CIColorKernel(source: """
        kernel vec4 thepodDespill(__sample s) {
            return vec4(s.r, min(s.g, max(s.r, s.b)), s.b, s.a);
        }
        """)

    /// Is this person's background green? Looks at strips at the top and sides; checked every 2 s.
    func isGreenScreen(_ frame: CIImage, lane: Int, time: Double) -> Bool {
        if let t = greenCheckedAt[lane], abs(time - t) < 2, let g = greenLane[lane] { return g }
        let e = frame.extent
        let strips = [CGRect(x: e.minX, y: e.maxY - e.height * 0.12, width: e.width, height: e.height * 0.12),
                      CGRect(x: e.minX, y: e.minY + e.height * 0.3, width: e.width * 0.1, height: e.height * 0.6),
                      CGRect(x: e.maxX - e.width * 0.1, y: e.minY + e.height * 0.3, width: e.width * 0.1, height: e.height * 0.6)]
        var votes = 0
        for r in strips {
            let avg = frame.cropped(to: r).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            var px = [Float](repeating: 0, count: 4)
            Self.maskContext.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: avg.extent.origin, size: CGSize(width: 1, height: 1)),
                                    format: .RGBAf, colorSpace: nil)
            if px[1] > 0.06, px[1] > 1.6 * max(px[0], px[2]) { votes += 1 }
        }
        let green = votes >= 2
        greenLane[lane] = green
        greenCheckedAt[lane] = time
        return green
    }

    /// With a green background: the mask is refined with color (exact edge) and the person loses the green spill.
    /// Returns the clean frame and the final mask. Without a green background, returns them as is.
    func greenScreen(_ frame: CIImage, mask: CIImage, lane: Int, time: Double) -> (frame: CIImage, mask: CIImage) {
        guard isGreenScreen(frame, lane: lane, time: time),
              let key = Self.keyKernel?.apply(extent: frame.extent, arguments: [frame, 0.02, 0.10]),
              let clean = Self.despillKernel?.apply(extent: frame.extent, arguments: [frame]) else { return (frame, mask) }
        let e = frame.extent
        // The segmentation mask, slightly larger: that way the color decides the edge, not it;
        // it still serves to remove what isn't green outside the cloth (walls, lamps).
        let loose = mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(3, e.width * 0.006)]).cropped(to: e)
        let byColor = key.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8]).cropped(to: e)
        let final = byColor.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: loose]).cropped(to: e)
        return (clean, final)
    }

    /// Replaces a person's real background with the chosen one.
    func replacedBackground(_ frame: CIImage, buffer: CVPixelBuffer, lane: Int, time: Double) -> CIImage {
        guard let vb = virtualBG[lane], let raw = personMask(buffer, extent: frame.extent, lane: lane, time: time) else { return frame }
        let (frame, mask) = greenScreen(frame, mask: raw, lane: lane, time: time)
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

    /// Color: general filter and per-person correction (match cameras)
    var colorLook = "none"
    var laneGain: [Int: [Double]] = [:]
    /// Studio · Video: per-camera and whole-track color
    var laneGrade: [Int: ColorGrade] = [:]
    var globalGrade: ColorGrade?
    /// Per-camera mask (keyframes already in final video time)
    var laneMask: [Int: ShapeMask] = [:]

    /// The mask drawn in the person's box: white inside (feathered edge), black outside.
    func maskImage(_ m: ShapeMask, in rect: CGRect, at t: Double) -> CIImage {
        let p = m.placement(at: t)
        let w = rect.width * m.w * p.scale, h = rect.height * m.h * p.scale
        let cx = rect.minX + rect.width * p.x, cy = rect.maxY - rect.height * p.y
        let feather = max(0, m.feather) * (renderSize.height / 1080)
        var shape: CIImage
        if m.shape == .ellipse {
            // a hard-edged white circle, scaled to an ellipse; the feathering comes from the later blur
            let r = max(w, h) / 2
            let gen = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": r - 0.5, "inputRadius1": r + 0.5,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black])!
            shape = (gen.outputImage ?? CIImage(color: .black)).cropped(to: CGRect(x: -r - 2, y: -r - 2, width: 2 * r + 4, height: 2 * r + 4))
                .transformed(by: CGAffineTransform(translationX: cx, y: cy).scaledBy(x: w / (2 * r), y: h / (2 * r)))
        } else {
            shape = CIImage(color: .white).cropped(to: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        }
        var out = shape.composited(over: CIImage(color: .black).cropped(to: rect.insetBy(dx: -feather * 3, dy: -feather * 3)))
        if feather > 0.5 { out = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather / 2]) }
        out = out.cropped(to: rect)
        if m.invert { out = out.applyingFilter("CIColorInvert").cropped(to: rect) }
        return out
    }

    func colored(_ img: CIImage, lane: Int) -> CIImage {
        var out = img
        if let g = laneGain[lane], g.count == 3 {
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g[0], y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g[1], z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g[2], w: 0)])
        }
        if let lg = laneGrade[lane] { out = lg.apply(to: out) }
        if let gg = globalGrade { out = gg.apply(to: out) }
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
        // A span pinned by hand in Studio beats who's speaking
        if let span = cameraSpan(at: t), let lane = span.lane { return (lane, span.start) }
        var current = switches.first ?? SpeakerSwitch(time: 0, lane: laneOrder.first ?? 1)
        for s in switches {
            if s.time > t + 1e-4 { break }
            current = s
        }
        return (current.lane, current.time)
    }

    // MARK: Frame

    /// Multicam: how to go from one camera to another (nil = hard cut). Fade: the previous and new frames are
    /// blended; smooth zoom: the new one comes in 4 % larger and settles. Applies to automatic and manual switches.
    var switchTransition: Transition? = nil

    func render(frames: [Int: CIImage], buffers: [Int: CVPixelBuffer] = [:], brollFrames: [CMPersistentTrackID: CIImage] = [:], time time: Double) -> CIImage {
        let now = renderFrame(frames: frames, buffers: buffers, brollFrames: brollFrames, time: time)
        guard let tr = switchTransition, tr.kind != .cut, tr.duration > 0.01,
              time >= contentStart, time < contentEnd else { return now }
        let t = time - contentStart
        let since = activeLane(at: t).since
        let span = cameraSpan(at: t)
        // Moment of the last switch: the speaker's, or the start of the manual span (even if it's template-only)
        let lastSpanEnd = cameraSpans.filter { $0.end <= t }.map(\.end).max() ?? -1
        let change = max(since, span?.start ?? -1, lastSpanEnd)
        let p = (t - change) / tr.duration
        guard change > 0.01, p >= 0, p < 1 else { return now }
        let full = CGRect(origin: .zero, size: renderSize)
        let e = p * p * (3 - 2 * p)   // smooth
        switch tr.kind {
        case .zoom:
            let z = 1 + 0.04 * (1 - e)
            let cx = full.midX, cy = full.midY
            return now.transformed(by: CGAffineTransform(translationX: cx, y: cy).scaledBy(x: z, y: z).translatedBy(x: -cx, y: -cy)).cropped(to: full)
        default:
            // Fade: the frame as it looked right before the switch, with the same current frames, blended with the new one
            let before = renderFrame(frames: frames, buffers: buffers, brollFrames: brollFrames, time: contentStart + change - 0.001)
            return now.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: before, kCIInputTimeKey: 1 - e]).cropped(to: full)
        }
    }

    private func renderFrame(frames: [Int: CIImage], buffers: [Int: CVPixelBuffer] = [:], brollFrames: [CMPersistentTrackID: CIImage] = [:], time time: Double) -> CIImage {
        let W = renderSize.width, H = renderSize.height
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.03)).cropped(to: full)
        // Intro / outro: the full image (uncropped) over a dark background, with a half-second fade
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
        let t = time - contentStart   // content times (subtitles, who's speaking, lower thirds…)
        var out: CIImage = background.map { fill($0, into: full, cropX: 0.5) }
            ?? CIImage(color: CIColor(red: 0.055, green: 0.055, blue: 0.07)).cropped(to: full)

        // Reels and square: automatic items (subtitles, sponsors, PiP b-roll, lower thirds, names) make room
        // so as not to cover the logo, manually placed layers or each other. Manually placed items don't move.
        let arrange = format == .vertical || format == .square
        let plan = arrange ? arrangement(at: t, brollFrames: brollFrames) : nil
        var spots = plan?.layout ?? FrameLayout(W: W, H: H, gap: 0)

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
            // Audiogram: symmetric bars from the center following the speaker's voice; each bar further
            // out shows the level from slightly earlier, so the wave «travels» from the center
            if !audiogram.isEmpty {
                let bars = 31, gap = W * 0.006
                let bw = (W * 0.72 - gap * CGFloat(bars - 1)) / CGFloat(bars)
                let baseY = H * 0.14, maxH = H * 0.11
                let accent = CIColor(red: 0.957, green: 0.780, blue: 0.439)
                for k in 0..<bars {
                    let d = abs(k - bars / 2)
                    let lvl = voiceLevel(active, at: max(0, t - Double(d) * 0.06))
                    let h = max(bw * 0.6, maxH * lvl * (1 - CGFloat(d) / CGFloat(bars)))
                    let x = (W - W * 0.72) / 2 + CGFloat(k) * (bw + gap)
                    let bar = CIImage(color: accent).cropped(to: CGRect(x: x, y: baseY - h / 2, width: bw, height: h))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55 + 0.45 * lvl)])
                    out = bar.composited(over: out)
                }
            }
        } else {
            let resolved = resolve(cameraSpan(at: t)?.template ?? layout, count: visible.count)
            let mainLane: Int = {
                // PiP with "siempre la primera persona": the large one is the first lane and the PiP switches
                if resolved == .pip, !options.pipFollowSpeaker, let first = visible.first { return first }
                return main ?? visible[0]
            }()
            let rects = panels(for: resolved, lanes: visible, main: mainLane, speaking: main ?? visible[0], in: full, frames: frames)
            for (lane, rect, border) in rects {
                guard var frame = frames[lane] else { continue }
                // «Fondo del podcast»: the person is cut out and behind them goes the SAME background that surrounds the
                // boxes, in its place on screen. Previously another copy of the background was put inside the box and
                // a strip or seam was visible where they didn't match.
                var cutout: CIImage?
                if let vb = virtualBG[lane], let pb = buffers[lane] {
                    if vb.mode == .podcast, background != nil {
                        cutout = personMask(pb, extent: frame.extent, lane: lane, time: time)
                        if let m = cutout {
                            let g = greenScreen(frame, mask: m, lane: lane, time: time)
                            frame = g.frame
                            cutout = g.mask
                        }
                    } else {
                        frame = replacedBackground(frame, buffer: pb, lane: lane, time: time)
                    }
                }
                // With a mask: the camera color goes only inside; outside the frame stays without that color (maybe darkened)
                var unmasked: CIImage? = laneMask[lane] != nil ? frame : nil
                if let u = unmasked, laneGain[lane] != nil || globalGrade != nil || colorLook != "none" {
                    // what isn't from this camera (match cameras, whole track, simple look) does go on the whole frame
                    var g = u
                    if let gain = laneGain[lane], gain.count == 3 {
                        g = g.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: gain[0], y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain[1], z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: gain[2], w: 0)])
                    }
                    if let gg = globalGrade { g = gg.apply(to: g) }
                    unmasked = g
                }
                if colorLook != "none" || laneGain[lane] != nil || laneGrade[lane] != nil || globalGrade != nil { frame = colored(frame, lane: lane) }
                if mirror[lane] == true {
                    // Horizontal mirror, keeping the frame where it was
                    let e = frame.extent
                    let flip = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -(e.minX * 2 + e.width), y: 0)
                    frame = frame.transformed(by: flip)
                    cutout = cutout?.transformed(by: flip)
                    unmasked = unmasked?.transformed(by: flip)
                }
                // Punch-in: the person comes slightly closer when their voice rises; a somewhat larger box is filled and cropped
                let z = punch(lane, at: t)
                let zRect = z > 1.001 ? rect.insetBy(dx: -rect.width * (z - 1) / 2, dy: -rect.height * (z - 1) / 2) : rect
                var panel = fill(frame, into: zRect, cropX: cropX[lane] ?? 0.5).cropped(to: rect)
                if let m = laneMask[lane], let u = unmasked {
                    var outside = fill(u, into: zRect, cropX: cropX[lane] ?? 0.5).cropped(to: rect)
                    if m.dimOutside > 0.001 { outside = outside.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -3 * m.dimOutside]).cropped(to: rect) }
                    panel = panel.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: outside, kCIInputMaskImageKey: maskImage(m, in: rect, at: t)]).cropped(to: rect)
                }
                if let cutout, let bg = background {
                    let behind = fill(bg, into: full, cropX: 0.5).cropped(to: rect)
                    let m = fill(cutout, into: zRect, cropX: cropX[lane] ?? 0.5).cropped(to: rect)
                    panel = panel.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: behind, kCIInputMaskImageKey: m]).cropped(to: rect)
                }
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
                    if arrange {
                        let want = CGRect(x: rect.minX + margin, y: y, width: tag.extent.width, height: tag.extent.height)
                        let got = spots.place(want, minY: rect.minY, maxY: rect.maxY)
                        spots.reserve(got)
                        y = got.minY
                    }
                    out = tag.transformed(by: .init(translationX: rect.minX + margin, y: y)).composited(over: out)
                }
            }
        }

        // B-roll: covers the people (logo, sponsors, layers and subtitles go on top)
        for (bi, b) in brolls.enumerated() where t >= b.start && t < b.end {
            var pic: CIImage? = b.image
            if let tid = b.trackID { pic = brollFrames[tid].map { oriented($0, b.transform) } }
            if let g = b.grade, let p = pic { pic = g.apply(to: p) }
            if let gg = globalGrade, let p = pic { pic = gg.apply(to: p) }
            guard let pic else { continue }
            // In: Studio's transition if any (cut, fade, to black, slide, zoom); otherwise a short fade
            let trIn = b.transition
            let inDur = trIn.map { max(0.001, $0.duration) } ?? 0.35
            let kIn = CGFloat(min(1, (t - b.start) / inDur))
            let kOut = CGFloat(min(1, (b.end - t) / 0.35))
            let k = trIn == nil ? min(kIn, kOut) : kOut            // the usual fade, or only the out
            var img: CIImage
            if b.placement == "pipLeft" || b.placement == "pipRight" {
                // PiP at the bottom, framed: doesn't cover the people
                // The PiP takes the video's shape (not cropped): max width 28 % / 38 %, max height 30 %
                let e = pic.extent
                let ar = e.width > 0 ? e.height / e.width : 9.0 / 16.0
                var w = W * (format.isVertical ? 0.38 : 0.28)
                var h = w * ar
                if h > H * 0.3 { h = H * 0.3; w = h / ar }
                let m = min(W, H) * 0.035
                let bottom = plan?.pipY[bi] ?? (format.isVertical ? H * 0.22 : m)
                let rect = CGRect(x: b.placement == "pipLeft" ? m : W - w - m, y: bottom, width: w, height: h)
                let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect.insetBy(dx: -4, dy: -4))
                img = (b.fill ? fill(pic, into: rect, cropX: 0.5) : fit(pic, into: rect).composited(over: CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.03)).cropped(to: rect)))
                    .composited(over: border)
                if k < 1 {
                    // Enters growing from its corner
                    let s = 0.85 + 0.15 * k
                    let cx = rect.midX, cy = rect.midY
                    img = img.transformed(by: CGAffineTransform(translationX: -cx, y: -cy).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: cx, y: cy)))
                }
            } else {
                img = b.fill ? fill(pic, into: full, cropX: 0.5) : fit(pic, into: full).composited(over: dark)
            }
            if let tr = trIn, kIn < 1 {
                let e = CGFloat(1 - pow(1 - Double(kIn), 3))      // eases out
                switch tr.kind {
                case .cut: break
                case .fade:
                    img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: kIn)])
                case .black:
                    // First half: what's underneath goes to black; second: the clip appears from black
                    if kIn < 0.5 {
                        img = dark.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: kIn * 2)])
                    } else {
                        img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: (kIn - 0.5) * 2)]).composited(over: dark)
                    }
                case .slide:
                    img = img.transformed(by: .init(translationX: -W * (1 - e), y: 0))
                case .zoom:
                    let s = 0.8 + 0.2 * e
                    let cx = img.extent.midX, cy = img.extent.midY
                    img = img.transformed(by: CGAffineTransform(translationX: -cx, y: -cy).concatenating(.init(scaleX: s, y: s)).concatenating(.init(translationX: cx, y: cy)))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: kIn)])
                }
            }
            if k < 1 { img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: k)]) }
            out = img.composited(over: out)
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
                let y = plan?.sponsorY[i] ?? (format.isVertical ? H * 0.62 : H - img.extent.height - m - (logo != nil ? min(W, H) * 0.11 : 0))
                out = img.transformed(by: .init(translationX: x, y: y)).composited(over: out)
            }
        }

        // Director lower thirds: bottom left, enter from the left and leave the same way
        var cintilloTop: CGFloat = 0
        for (ci, c) in cintillos.enumerated() where t >= c.start && t < c.end {
            let img = c.image
            let m = min(W, H) * 0.04
            let y = plan?.cintilloY[ci] ?? max(format.isVertical ? H * 0.30 : m, cintilloTop > 0 ? cintilloTop + m * 0.4 : 0)
            let tin = t - c.start, tout = c.end - t
            var placed: CIImage
            if tout < 0.3 {
                // Out: goes left with a fade (0.3 s)
                let q = CGFloat(tout / 0.3)
                let k = 1 - pow(1 - q, 3)
                let x = m - (img.extent.width + m) * (1 - k)
                placed = img.transformed(by: .init(translationX: x, y: y))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: k)])
            } else if tin < 0.9, let base = c.base {
                // Enters in three steps: 0–0.15 s the logo with a bounce; 0.15–0.5 s the bars unfold from the logo; 0.5–0.9 s the text appears
                let w = img.extent.width, h = img.extent.height
                var layer: CIImage
                if tin < 0.15 {
                    let k = CGFloat(tin / 0.15)
                    let sc = 0.6 + 0.5 * k - 0.1 * k * k      // goes from 0.6 to 1.0 with a small bounce
                    let logoPart = c.logoW > 0 ? base.cropped(to: CGRect(x: 0, y: 0, width: c.logoW, height: h)) : base.cropped(to: CGRect(x: 0, y: 0, width: min(w, h * 0.9), height: h))
                    let cx = logoPart.extent.midX, cy = logoPart.extent.midY
                    layer = logoPart.transformed(by: CGAffineTransform(translationX: -cx, y: -cy).concatenating(.init(scaleX: sc, y: sc)).concatenating(.init(translationX: cx, y: cy)))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: k)])
                } else if tin < 0.5 {
                    let k = CGFloat((tin - 0.15) / 0.35)
                    let e = 1 - pow(1 - k, 3)
                    let reveal = c.logoW + (w - c.logoW) * e
                    layer = base.cropped(to: CGRect(x: 0, y: 0, width: reveal, height: h))
                } else {
                    let k = CGFloat((tin - 0.5) / 0.4)
                    let text = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: k)])
                    layer = text.composited(over: base)
                }
                placed = layer.transformed(by: .init(translationX: m, y: y))
            } else if tin < 0.4 {
                // No base layer (old lower thirds): slides in
                let k = CGFloat(1 - pow(1 - tin / 0.4, 3))
                placed = img.transformed(by: .init(translationX: m - (img.extent.width + m) * (1 - k), y: y))
            } else {
                placed = img.transformed(by: .init(translationX: m, y: y))
            }
            out = placed.composited(over: out)
            cintilloTop = max(cintilloTop, y + img.extent.height)
        }

        // User layers: above the video and lower thirds, below the subtitles
        for c in overlays where t >= c.start && t < c.end {
            let r = overlayRect(c, at: t)
            var img = c.image.transformed(by: .init(translationX: -c.image.extent.minX, y: -c.image.extent.minY))
            // Studio · Video: size, rotation and opacity by keyframes (overlayRect already resolved the position)
            if let a = c.anim, !a.isEmpty {
                let s = r.width / max(1, c.image.extent.width)
                let rot = a.value(LayerAnimation.rotation, at: t) ?? 0
                if abs(s - 1) > 1e-4 || abs(rot) > 1e-4 {
                    let w = c.image.extent.width, h = c.image.extent.height
                    img = img.transformed(by: CGAffineTransform(translationX: -w / 2, y: -h / 2)
                        .concatenating(.init(scaleX: s, y: s))
                        .concatenating(.init(rotationAngle: CGFloat(-rot * .pi / 180)))
                        .concatenating(.init(translationX: r.width / 2, y: r.height / 2)))
                }
                if let o = a.value(LayerAnimation.opacity, at: t), o < 1 {
                    img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, o)))])
                }
            }
            if c.enter != nil || c.exit != nil {
                // Studio · Video: chosen in and out
                if let en = c.enter, t - c.start < en.duration {
                    img = Self.motion(img, kind: en.kind, k: (t - c.start) / max(0.001, en.duration), r: r, H: H)
                } else if let ex = c.exit, c.end - t < ex.duration {
                    img = Self.motion(img, kind: ex.kind, k: (c.end - t) / max(0.001, ex.duration), r: r, H: H)
                } else if c.animate {
                    // Only one side chosen: the other uses the usual fade
                    let k = c.enter == nil ? min(1, (t - c.start) / 0.3) : min(1, (c.end - t) / 0.3)
                    if k < 1 { img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(k))]) }
                }
            } else if c.animate {
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
                var x = (W - img.extent.width) / 2
                var y: CGFloat
                switch style.position {
                case .bottom: y = max(format.isVertical ? H * 0.20 : H * 0.07, cintilloTop > 0 && !format.isVertical ? cintilloTop + H * 0.03 : 0)
                case .center: y = (H - img.extent.height) / 2 - (format.isVertical ? H * 0.05 : 0)
                case .top: y = H - img.extent.height - H * (format.isVertical ? 0.14 : 0.07)
                }
                if let fx = style.freeX, let fy = style.freeY {
                    // Free position (dragged over the preview): center in frame fractions, without leaving it
                    x = min(max(0, CGFloat(fx) * W - img.extent.width / 2), max(0, W - img.extent.width))
                    y = min(max(0, (1 - CGFloat(fy)) * H - img.extent.height / 2), max(0, H - img.extent.height))
                } else if let band = plan?.captionBand {
                    // Its strip (may have shifted so as not to cover a manually placed layer)
                    switch style.position {
                    case .bottom: y = band.minY
                    case .top: y = band.maxY - img.extent.height
                    case .center: y = band.midY - img.extent.height / 2
                    }
                }
                out = img.transformed(by: .init(translationX: x, y: y)).composited(over: out)
            }
        }
        return out.cropped(to: full)
    }

    // MARK: Arrangement (reels and square)

    /// Subtitle font size.
    func captionFontSize() -> CGFloat {
        let factor: CGFloat
        switch style.size {
        case .small: factor = format.isVertical ? 0.058 : 0.045
        case .medium: factor = format.isVertical ? 0.075 : 0.057
        case .large: factor = format.isVertical ? 0.095 : 0.072
        }
        return min(renderSize.width, renderSize.height) * factor
    }

    struct Arrangement {
        var layout: FrameLayout
        var captionBand: CGRect?
        var sponsorY: [Int: CGFloat] = [:]
        var pipY: [Int: CGFloat] = [:]
        var cintilloY: [Int: CGFloat] = [:]
    }

    /// Where each automatic item goes at instant `t`, in order of importance: fixed things first (logo, manually placed
    /// layers, dragged subtitles), then subtitles, sponsors, PiP b-roll and lower thirds.
    /// Each takes its usual place if free; otherwise, the nearest free place (moves up before down).
    /// Subtitles always reserve their strip (two lines), so nothing jumps when the phrase changes.
    func arrangement(at t: Double, brollFrames: [CMPersistentTrackID: CIImage]) -> Arrangement {
        let W = renderSize.width, H = renderSize.height
        let unit = min(W, H)
        var a = Arrangement(layout: FrameLayout(W: W, H: H, gap: unit * 0.015))
        // Fixed: logo at top right
        if let logo {
            let h = unit * 0.085, w = logo.extent.width * h / max(1, logo.extent.height), m = unit * 0.03
            a.layout.reserve(CGRect(x: W - w - m, y: H - h - m, width: w, height: h))
        }
        // Fixed: manually placed layers
        for c in overlays where t >= c.start && t < c.end { a.layout.reserve(overlayRect(c, at: t)) }
        // Subtitles
        if style.enabled, !captions.isEmpty {
            let bandH = captionFontSize() * 2.6, bandW = W * 0.86
            if let fx = style.freeX, let fy = style.freeY {
                a.layout.reserve(CGRect(x: CGFloat(fx) * W - bandW / 2, y: (1 - CGFloat(fy)) * H - bandH / 2, width: bandW, height: bandH))
            } else {
                let y: CGFloat
                switch style.position {
                case .bottom: y = format.isVertical ? H * 0.20 : H * 0.07
                case .top: y = H - H * (format.isVertical ? 0.14 : 0.07) - bandH
                case .center: y = H / 2 - (format.isVertical ? H * 0.05 : 0) - bandH / 2
                }
                let band = a.layout.place(CGRect(x: (W - bandW) / 2, y: y, width: bandW, height: bandH),
                                          minY: H * 0.04, maxY: H * 0.96, preferUp: style.position != .top)
                a.layout.reserve(band)
                a.captionBand = band
            }
        }
        // Sponsors (on the right)
        let m3 = unit * 0.03
        for (i, card) in sponsorCards.enumerated() where t >= card.start && t < card.end {
            guard let img = cached("sponsor-\(i)-\(Int(W))", { sponsorImage(card) }) else { continue }
            let y0 = format.isVertical ? H * 0.62 : H - img.extent.height - m3 - (logo != nil ? unit * 0.11 : 0)
            let r = a.layout.place(CGRect(x: W - m3 - img.extent.width, y: y0, width: img.extent.width, height: img.extent.height))
            a.layout.reserve(r)
            a.sponsorY[i] = r.minY
        }
        // PiP b-roll (bottom)
        for (i, b) in brolls.enumerated() where t >= b.start && t < b.end && (b.placement == "pipLeft" || b.placement == "pipRight") {
            var pic: CIImage? = b.image
            if let tid = b.trackID { pic = brollFrames[tid].map { oriented($0, b.transform) } }
            if let g = b.grade, let p = pic { pic = g.apply(to: p) }
            if let gg = globalGrade, let p = pic { pic = gg.apply(to: p) }
            guard let e = pic?.extent else { continue }
            let ar = e.width > 0 ? e.height / e.width : 9.0 / 16.0
            var w = W * (format.isVertical ? 0.38 : 0.28)
            var h = w * ar
            if h > H * 0.3 { h = H * 0.3; w = h / ar }
            let m = unit * 0.035
            let r = a.layout.place(CGRect(x: b.placement == "pipLeft" ? m : W - w - m, y: format.isVertical ? H * 0.22 : m, width: w, height: h),
                                   minY: m, maxY: H - m)
            a.layout.reserve(r)
            a.pipY[i] = r.minY
        }
        // Lower thirds (on the left, stacked)
        let m4 = unit * 0.04
        for (i, c) in cintillos.enumerated() where t >= c.start && t < c.end {
            let e = c.image.extent
            let r = a.layout.place(CGRect(x: m4, y: format.isVertical ? H * 0.30 : m4, width: e.width, height: e.height),
                                   minY: m4, maxY: H - m4)
            a.layout.reserve(r)
            a.cintilloY[i] = r.minY
        }
        return a
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
        if count <= 1 && l != .studio { return .solo }   // with 1 person, "Quien habla" (and its studio frame if active)
        switch l {
        case .auto:
            switch format {
            case .vertical, .square: return .solo
            default: return count == 2 ? .sideBySide : .grid
            }
        default: return l
        }
    }

    /// `main` = who's shown large; `speaking` = who's speaking now (to pick the PiP when they differ).
    private func panels(for layout: LayoutTemplate, lanes: [Int], main: Int, speaking: Int, in full: CGRect,
                        frames: [Int: CIImage] = [:])
        -> [(lane: Int, rect: CGRect, border: Bool)] {
        let W = full.width, H = full.height
        let others = lanes.filter { $0 != main }
        switch layout {
        case .solo, .auto:
            if options.soloStudio {
                // A single framed box over the podcast background: the video fits whole (uncropped),
                // so the background fills what's left above/below or on the sides.
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
                // In landscape a full-width strip would crop each face to a sliver: each video keeps
                // its shape, centered in its strip, framed, and the podcast background fills the sides.
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
                // Speaker large on top; the others in a row of small tiles below
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
            // PiP: the first one NOT shown large; if several, prefer the speaker (if not the large one)
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

    /// Applies the video metadata rotation (preferredTransform, top-left origin)
    /// to a Core Image image (bottom-left origin) and leaves its origin at (0, 0).
    func oriented(_ img: CIImage, _ t: CGAffineTransform) -> CIImage {
        guard !t.isIdentity else { return img }
        let e = img.extent
        let flip = CGAffineTransform(scaleX: 1, y: -1).concatenating(.init(translationX: 0, y: e.height))
        var out = img.transformed(by: flip).transformed(by: t)
        let e2 = out.extent
        let unflip = CGAffineTransform(scaleX: 1, y: -1).concatenating(.init(translationX: 0, y: e2.height + 2 * e2.minY))
        out = out.transformed(by: unflip)
        let e3 = out.extent
        return out.transformed(by: .init(translationX: -e3.minX, y: -e3.minY))
    }

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
            + scene.brolls.compactMap { $0.trackID }.map { NSNumber(value: $0) }
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
                // Calm mode: if the Mac is hot, go slower instead of forcing the fans
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
                var brollFrames: [CMPersistentTrackID: CIImage] = [:]
                for b in scene.brolls {
                    if let tid = b.trackID, let pb = request.sourceFrame(byTrackID: tid) { brollFrames[tid] = CIImage(cvPixelBuffer: pb) }
                }
                let image = scene.render(frames: frames, buffers: buffers, brollFrames: brollFrames, time: request.compositionTime.seconds)
                Self.ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: scene.renderSize), colorSpace: self.colorSpace)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }
}


/// Occupied places in a frame (Core Image coordinates, y up), to arrange automatic items without covering anything.
struct FrameLayout {
    let W: CGFloat, H: CGFloat, gap: CGFloat
    var taken: [CGRect] = []

    mutating func reserve(_ r: CGRect) { taken.append(r) }

    func isFree(_ r: CGRect) -> Bool { !taken.contains { $0.insetBy(dx: -gap, dy: -gap).intersects(r) } }

    /// The nearest free place moving only vertically, between `minY` and `maxY` (prefers moving up).
    /// If none is free, returns the original: better to overlap than to disappear.
    func place(_ r: CGRect, minY: CGFloat = 0, maxY: CGFloat? = nil, preferUp: Bool = true) -> CGRect {
        if isFree(r) { return r }
        let top = (maxY ?? H) - r.height
        var ys: [CGFloat] = []
        for o in taken where o.maxX + gap > r.minX && o.minX - gap < r.maxX {
            ys.append(o.maxY + gap)
            ys.append(o.minY - gap - r.height)
        }
        func cost(_ y: CGFloat) -> CGFloat {
            let d = y - r.minY
            return abs(d) * ((d > 0) == preferUp ? 1 : 1.6)
        }
        for y in ys.filter({ $0 >= minY && $0 <= top }).sorted(by: { cost($0) < cost($1) }) {
            let c = CGRect(x: r.minX, y: y, width: r.width, height: r.height)
            if isFree(c) { return c }
        }
        return r
    }
}
