import SwiftUI
import AppKit

/// thePod logo set (command line only: `--brand-kit <folder>`).
/// Generates transparent PNGs in several sizes and a vector PDF of each shape.
enum BrandKit {
    static let blue = Color(red: 0.353, green: 0.545, blue: 1.0)      // #5A8BFF prePod
    static let red = Color(red: 1.0, green: 0.231, blue: 0.231)       // #FF3B3B prodPod
    static let yellow = Color(red: 0.957, green: 0.780, blue: 0.439)  // #F4C770 postPod
    static let teal = Color(red: 0.078, green: 0.722, blue: 0.651)    // #14B8A6 amaPod
    static let dark = Color(red: 0.102, green: 0.082, blue: 0.063)    // #1A1510
    static let cream = Color(red: 0.937, green: 0.890, blue: 0.816)   // #EFE3D0

    /// The four-quarter disc. `icons` uses the tiles with icons; otherwise plain quarters.
    /// `mono` paints it a single color.
    struct Disc: View {
        var size: CGFloat
        var icons = false
        var mono: Color? = nil
        var body: some View {
            let gap = size * 0.03
            let q = (size - gap) / 2
            ZStack {
                if icons && mono == nil {
                    Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                        GridRow { tile("prepod", q, 1, 1); tile("prodpod", q, -1, 1) }
                        GridRow { tile("postpod", q, 1, -1); tile("amapod", q, -1, -1) }
                    }
                } else {
                    Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                        GridRow { quarter(mono ?? blue, q, .topLeft); quarter(mono ?? red, q, .topRight) }
                        GridRow { quarter(mono ?? yellow, q, .bottomLeft); quarter(mono ?? teal, q, .bottomRight) }
                    }
                }
            }
            .frame(width: size, height: size)
        }
        /// The tiles come with a transparent margin (the drawing takes 68.75 % flush to the inner corner):
        /// they're enlarged and shifted so the disc fills the tile.
        private func tile(_ n: String, _ s: CGFloat, _ sx: CGFloat, _ sy: CGFloat) -> some View {
            let f = s / 0.6875
            return Image("tile-" + n).resizable().interpolation(.high).frame(width: f, height: f)
                .offset(x: sx * (s - f) / 2, y: sy * (s - f) / 2)
                .frame(width: s, height: s).clipped()
        }
        private func quarter(_ c: Color, _ s: CGFloat, _ corner: UIRectCornerLike) -> some View {
            // A circle twice the size, centered on the corner facing the disc's center, clipped to the tile.
            let dx: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? s / 2 : -s / 2
            let dy: CGFloat = (corner == .topLeft || corner == .topRight) ? s / 2 : -s / 2
            return Circle().fill(c).frame(width: s * 2, height: s * 2).offset(x: dx, y: dy)
                .frame(width: s, height: s).clipped()
        }
    }

    enum UIRectCornerLike { case topLeft, topRight, bottomLeft, bottomRight }

    /// The eight stars in an arc over the disc (same geometry as the intro).
    struct Stars: View {
        var discSize: CGFloat
        var color: Color = .white
        var body: some View {
            // In the app: ~140 pt disc, stars 132 pt from the center, arc 26 pt higher
            let radius = discSize * 0.94
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let angle = Angle.degrees(162 - Double(i) * (144.0 / 7))
                    Image(systemName: "star.fill")
                        .font(.system(size: discSize * 0.11, weight: .bold))
                        .foregroundStyle(color)
                        .offset(x: cos(angle.radians) * radius, y: -sin(angle.radians) * radius + discSize * 0.18)
                }
            }
        }
    }

    struct Wordmark: View {
        var size: CGFloat
        var color: Color
        var body: some View {
            Text("thePod").font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(color)
                .lineLimit(1).fixedSize()
        }
    }

    // MARK: Shapes

    @MainActor
    static func views() -> [(String, AnyView, CGFloat, CGFloat)] {
        let s: CGFloat = 440           // disc size on the 512 base
        let sq: CGFloat = 512, wide: CGFloat = 1024, tall: CGFloat = 640
        func box(_ w: CGFloat, _ h: CGFloat, _ v: some View) -> AnyView { AnyView(v.frame(width: w, height: h)) }
        return [
            ("01-disco", box(sq, sq, Disc(size: s)), sq, sq),
            ("02-disco-iconos", box(sq, sq, Disc(size: s, icons: true)), sq, sq),
            ("03-disco-estrellas", box(sq, sq, ZStack { Disc(size: s * 0.5, icons: true).offset(y: s * 0.12); Stars(discSize: s * 0.5).offset(y: s * 0.12) }), sq, sq),
            ("03b-disco-estrellas-doradas", box(sq, sq, ZStack { Disc(size: s * 0.5, icons: true).offset(y: s * 0.12); Stars(discSize: s * 0.5, color: yellow).offset(y: s * 0.12) }), sq, sq),
            ("04-horizontal", box(wide, sq, HStack(spacing: s * 0.16) { Disc(size: s * 0.7); Wordmark(size: s * 0.4, color: cream) }), wide, sq),
            ("05-horizontal-oscuro", box(wide, sq, HStack(spacing: s * 0.16) { Disc(size: s * 0.7); Wordmark(size: s * 0.4, color: dark) }), wide, sq),
            ("06-vertical", box(sq, tall, VStack(spacing: s * 0.1) { Disc(size: s * 0.7, icons: true); Wordmark(size: s * 0.3, color: cream) }), sq, tall),
            ("07-vertical-oscuro", box(sq, tall, VStack(spacing: s * 0.1) { Disc(size: s * 0.7, icons: true); Wordmark(size: s * 0.3, color: dark) }), sq, tall),
            ("08-mono-blanco", box(wide, sq, HStack(spacing: s * 0.16) { Disc(size: s * 0.7, mono: .white); Wordmark(size: s * 0.4, color: .white) }), wide, sq),
            ("09-mono-negro", box(wide, sq, HStack(spacing: s * 0.16) { Disc(size: s * 0.7, mono: dark); Wordmark(size: s * 0.4, color: dark) }), wide, sq),
            ("10-disco-mono-blanco", box(sq, sq, Disc(size: s, mono: .white)), sq, sq),
            ("11-avatar-redondo", box(sq, sq, ZStack { Circle().fill(dark); Disc(size: s * 0.62) }.frame(width: sq, height: sq)), sq, sq),
            ("12-avatar-cuadrado", box(sq, sq, ZStack { RoundedRectangle(cornerRadius: sq * 0.22).fill(dark); Disc(size: s * 0.62) }.frame(width: sq, height: sq)), sq, sq),
            ("13-estrellas-oscuro", box(sq, sq, ZStack { RoundedRectangle(cornerRadius: sq * 0.22).fill(dark)
                                                   Disc(size: s * 0.46, icons: true).offset(y: s * 0.1); Stars(discSize: s * 0.46).offset(y: s * 0.1) }
                                          .frame(width: sq, height: sq)), sq, sq),
        ]
    }

    /// Writes PNG (1024, 512, 256) and PDF of each shape into `dir`.
    @MainActor
    static func export(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, v, w, _) in views() {
            let r = ImageRenderer(content: v)
            r.isOpaque = false
            for scale in [2.0, 1.0, 0.5] {
                r.scale = scale
                if let cg = r.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(Int(w * scale)).png"))
                }
            }
            r.scale = 1
            let pdf = dir.appendingPathComponent("\(name).pdf")
            r.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) else { return }
                ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
            }
            print("logo \(name)")
        }
    }
}


// MARK: - The intro as a function of time (to export GIF and video frame by frame)

/// Same choreography as IntroView, but without SwiftUI animations: everything comes from `t` (seconds).
struct IntroFrame: View {
    var t: Double
    var transparent = false
    var light = false                // for light backgrounds: golden stars and dark name
    var scale: CGFloat = 1           // 1 = the app size (300 pt disc)

    private static let noteTimes: [Double] = [0.02, 0.68, 0.46, 0.24]   // pre, prod, post, ama (tile order)
    private static let bloom = 1.164

    private func easeOut(_ x: Double) -> Double { let u = min(1, max(0, x)); return 1 - pow(1 - u, 3) }
    private func easeIn(_ x: Double) -> Double { let u = min(1, max(0, x)); return u * u }
    private func easeInOut(_ x: Double) -> Double { let u = min(1, max(0, x)); return u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2 }
    /// Spring with a short bounce (similar to .spring(response 0.32, damping 0.55)).
    private func spring(_ x: Double) -> Double {
        let u = min(1, max(0, x))
        return 1 - exp(-6.5 * u) * cos(10 * u)
    }

    var body: some View {
        let b = Self.bloom
        let allOn = t >= b + 0.05
        let nameA = easeIn((t - (b + 0.05)) / 0.4)
        let tw = t >= b + 0.05 && t < b + 0.5 ? easeInOut((t - (b + 0.05)) / 0.25) : (t >= b + 0.5 ? 1 - easeInOut((t - (b + 0.5)) / 0.25) : 0)
        let starsOut = allOn ? 8 : Self.noteTimes.filter { t >= $0 }.count * 2
        let order = [0, 7, 1, 6, 2, 5, 3, 4]
        ZStack {
            if !transparent { Color(red: 0.102, green: 0.082, blue: 0.063) }
            VStack(spacing: 28 * scale) {
                ZStack {
                    Grid(horizontalSpacing: 8 * scale, verticalSpacing: 8 * scale) {
                        GridRow { tile(0); tile(1) }
                        GridRow { tile(2); tile(3) }
                    }
                    ForEach(0..<8, id: \.self) { i in
                        let angle = Angle.degrees(162 - Double(i) * (144.0 / 7))
                        let k = order.firstIndex(of: i) ?? 8
                        let noteIdx = k / 2
                        let noteT = allOn ? b + 0.05 : [0.02, 0.24, 0.46, 0.68][min(3, noteIdx)]
                        let on = k < starsOut
                        let u = on ? spring((t - noteT) / 0.45) : 0
                        Image(systemName: "star.fill")
                            .font(.system(size: 15 * scale, weight: .bold))
                            .foregroundStyle(light ? BrandKit.yellow : .white)
                            .shadow(color: (light ? BrandKit.yellow : .white).opacity(0.45 + 0.45 * tw), radius: (4 + 5 * tw) * scale)
                            .scaleEffect(on ? CGFloat(0.2 + 0.8 * u) * CGFloat(1 + 0.18 * tw) : 0.2)
                            .opacity(on ? min(1, u * 1.5) : 0)
                            .offset(x: cos(angle.radians) * 132 * scale, y: (-sin(angle.radians) * 132 + 26) * scale)
                    }
                }
                .frame(width: 300 * scale, height: 236 * scale)
                Text("thePod")
                    .font(.system(size: 30 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(light ? BrandKit.dark : BrandKit.cream)
                    .opacity(nameA)
            }
        }
    }

    private func tile(_ i: Int) -> some View {
        let b = Self.bloom
        let noteT = Self.noteTimes[i]
        // Lights up with its note (0.18 s), turns off just before the bloom and they all come back together
        var on: Double = t >= noteT ? easeOut((t - noteT) / 0.18) : 0
        if t >= b - 0.04 { on = 1 - easeOut((t - (b - 0.04)) / 0.18) }
        if t >= b + 0.05 { on = easeOut((t - (b + 0.05)) / 0.18) }
        let op = 0.18 + 0.82 * on
        return Image("tile-" + ["prepod", "prodpod", "postpod", "amapod"][i])
            .resizable().interpolation(.high)
            .frame(width: 96 * scale, height: 96 * scale)
            .opacity(op)
            .scaleEffect(1 + 0.04 * on)
    }
}

extension BrandKit {
    /// Intro frames at `fps`, size w×h, with or without background.
    @MainActor
    static func introFrames(to dir: URL, w: CGFloat, h: CGFloat, alpha: Bool, light: Bool = false, fps: Double = 30, seconds: Double = 2.7) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scale = min(w, h) / 350
        let n = Int(seconds * fps)
        for i in 0..<n {
            let t = Double(i) / fps
            let r = ImageRenderer(content: IntroFrame(t: t, transparent: alpha, light: light, scale: scale).frame(width: w, height: h))
            r.isOpaque = !alpha
            r.scale = 1
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent(String(format: "f%04d.png", i)))
            }
        }
        print("frames \(n) at \(Int(fps)) fps")
    }
}
