import AVFoundation
import CoreImage
import AppKit

/// Builds one AVFoundation composition from the project's edit decisions.
/// The SAME composition drives the live preview (AVPlayer) and the final export,
/// so what the user sees is exactly what gets rendered.
struct BuiltComposition {
    let asset: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVMutableAudioMix
    let keep: [EditEngine.Span]
    let duration: Double
    let scene: RenderScene?
    /// Segundos de intro antes del contenido (0 si no hay). El cierre va después del contenido.
    var introDuration: Double = 0

    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

enum CompositionBuilder {
    enum Failure: LocalizedError {
        case empty
        var errorDescription: String? { "No hay nada que reproducir: todo el rango quedó cortado o no hay pistas." }
    }

    static func build(project: Project, format: ExportFormat, window: EditEngine.Span? = nil,
                      energy: EnergyMap?, layoutOverride: LayoutTemplate? = nil,
                      captionsOverride: Bool? = nil, preview: Bool = false) async throws -> BuiltComposition {
        let keep = EditEngine.keepRanges(duration: project.duration, cuts: project.cuts, window: window)
        let outDuration = EditEngine.outputDuration(keep)
        guard outDuration > 0.1 else { throw Failure.empty }
        // Intro y cierre (solo en el video completo, no en trozos ni reels)
        let wantVideoBumpers = format != .audio && window == nil
        let intro = wantVideoBumpers ? project.intro : nil
        let outro = wantVideoBumpers ? project.outro : nil
        let introDur = intro.map { max(1, $0.seconds) } ?? 0
        let outroDur = outro.map { max(1, $0.seconds) } ?? 0
        let contentEnd = introDur + outDuration

        let comp = AVMutableComposition()
        var mixParams: [AVMutableAudioMixInputParameters] = []
        var videoTrackIDs: [Int: CMPersistentTrackID] = [:]
        var assets: [String: AVURLAsset] = [:]
        func asset(_ rel: String) -> AVURLAsset {
            if let a = assets[rel] { return a }
            let a = AVURLAsset(url: ProjectStore.url(rel, in: project.id), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[rel] = a
            return a
        }
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 90_000) }

        /// Places [tlStart, tlStart+len) of a source onto `track`, skipping whatever falls in cuts.
        /// Devuelve el tramo [inicio, fin) en tiempo de salida que ocupó lo colocado (para los fades).
        @discardableResult
        func place(track: AVMutableCompositionTrack, source: AVAssetTrack, sourceDuration: Double,
                   tlStart: Double, srcIn: Double, length: Double) throws -> (start: Double, end: Double)? {
            var cursor = 0.0
            var outStart: Double?, outEnd: Double?
            for k in keep {
                let a = max(k.start, tlStart), b = min(k.end, tlStart + length)
                if b - a > 0.01 {
                    let src = srcIn + (a - tlStart)
                    let len = min(b - a, max(0, sourceDuration - src))
                    if len > 0.01 {
                        let at = introDur + cursor + (a - k.start)
                        try track.insertTimeRange(CMTimeRange(start: cm(src), duration: cm(len)), of: source, at: cm(at))
                        if outStart == nil { outStart = at }
                        outEnd = at + len
                    }
                }
                cursor += k.end - k.start
            }
            guard let outStart, let outEnd else { return nil }
            return (outStart, outEnd)
        }
        /// Curva de volumen de una pista: el producto de varios factores (fades, auto-silencio, bajar bajo la voz)
        /// convertido en rampas consecutivas que no se pisan (AVFoundation ignora rampas superpuestas).
        func applyEnvelope(_ p: AVMutableAudioMixInputParameters, base: Double, span: (start: Double, end: Double),
                           points: [Double], factor: (Double) -> Double) {
            var pts = ([span.start, span.end] + points.filter { $0 > span.start && $0 < span.end }).sorted()
            pts = pts.reduce(into: [Double]()) { acc, t in if let l = acc.last, t - l < 0.004 { return }; acc.append(t) }
            func v(_ t: Double) -> Float { Float(max(0, base * factor(t))) }
            p.setVolume(v(span.start), at: .zero)
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                let va = v(a), vb = v(b)
                if abs(va - vb) < 0.0005 { continue }
                p.setVolumeRamp(fromStartVolume: va, toEndVolume: vb, timeRange: CMTimeRange(start: cm(a), duration: cm(b - a)))
            }
        }
        func fadeFactor(_ t: Double, span: (start: Double, end: Double), fadeIn: Double, fadeOut: Double) -> Double {
            let len = span.end - span.start
            let fi = min(fadeIn, len / 2), fo = min(fadeOut, len / 2)
            var f = 1.0
            if fi > 0.01 { f *= min(1, max(0, (t - span.start) / fi)) }
            if fo > 0.01 { f *= min(1, max(0, (span.end - t) / fo)) }
            return f
        }
        func fadePoints(_ span: (start: Double, end: Double), fadeIn: Double, fadeOut: Double) -> [Double] {
            [span.start + min(fadeIn, (span.end - span.start) / 2), span.end - min(fadeOut, (span.end - span.start) / 2)]
        }

        // Quién habla (en tiempo de salida): lo usa el diseño y la puerta por persona
        let switches = AudioAnalysis.speakerSwitches(project: project, energy: energy, keep: keep)
        let gate = project.fix.gateOthers && project.lanes.count > 1 && energy != nil && switches.count > 1
        /// Quién habla en el instante `t` del video final (con intro incluido).
        func speaker(at t: Double) -> Int? {
            var cur = switches.first?.lane
            for sw in switches { if introDur + sw.time <= t { cur = sw.lane } else { break } }
            return cur
        }
        let gatePoints: [Double] = switches.dropFirst().flatMap { [introDur + $0.time - 0.05, introDur + $0.time + 0.10] }

        /// Tramos (tiempo del video final) en que alguien habla: para bajar la música bajo la voz.
        let speech: [(start: Double, end: Double)] = {
            guard let energy else { return [] }
            let comb = energy.combined
            guard !comb.isEmpty else { return [] }
            var segs: [(start: Double, end: Double)] = []
            var cursor = 0.0
            for r in keep {
                var t = r.start
                while t < r.end {
                    let i = Int(t / EnergyMap.hop)
                    if i >= 0, i < comb.count, comb[i] > -40 {
                        let o = introDur + cursor + (t - r.start)
                        if let last = segs.last, o - last.end < 1.0 { segs[segs.count - 1].end = o + EnergyMap.hop }
                        else { segs.append((o, o + EnergyMap.hop)) }
                    }
                    t += EnergyMap.hop
                }
                cursor += r.end - r.start
            }
            return segs.filter { $0.end - $0.start >= 0.3 }
        }()
        func inSpeech(_ t: Double) -> Bool {
            var lo = 0, hi = speech.count - 1
            while lo <= hi {
                let m = (lo + hi) / 2
                if t < speech[m].start { hi = m - 1 } else if t > speech[m].end { lo = m + 1 } else { return true }
            }
            return false
        }
        let duckPoints: [Double] = speech.flatMap { [$0.start - 0.3, $0.start, $0.end, $0.end + 0.8] }

        let wantVideo = format != .audio
        for lane in project.lanes {
            var vTrack: AVMutableCompositionTrack?
            var aTrack: AVMutableCompositionTrack?
            var laneSpan: (start: Double, end: Double)?
            var laneBase = lane.volume
            for placed in lane.placed {
                guard let media = project.mediaItem(placed.clip.mediaId) else { continue }
                let videoAsset = asset(media.file)
                let srcDuration = try await videoAsset.load(.duration).seconds
                if wantVideo, media.hasVideo, let src = try await videoAsset.loadTracks(withMediaType: .video).first {
                    if vTrack == nil { vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    try place(track: vTrack!, source: src, sourceDuration: srcDuration,
                              tlStart: placed.tlStart, srcIn: placed.clip.srcIn, length: placed.clip.length)
                }
                if media.hasAudio {
                    var audioRel = (project.enhanceAudio ? media.enhancedAudioFile : nil) ?? media.file
                    if !FileManager.default.fileExists(atPath: ProjectStore.url(audioRel, in: project.id).path) { audioRel = media.file }
                    // Ecualizador de la persona: archivo ya procesado con la misma configuración y la misma base
                    if !lane.eq.isFlat, let eqRel = media.eqAudioFile,
                       eqRel == AudioAnalysis.eqRel(mediaId: media.id, base: audioRel, eq: lane.eq),
                       FileManager.default.fileExists(atPath: ProjectStore.url(eqRel, in: project.id).path) {
                        audioRel = eqRel
                    }
                    let audioAsset = asset(audioRel)
                    if let src = try await audioAsset.loadTracks(withMediaType: .audio).first {
                        let aDur = try await audioAsset.load(.duration).seconds
                        if aTrack == nil { aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        if let span = try place(track: aTrack!, source: src, sourceDuration: aDur,
                                                tlStart: placed.tlStart, srcIn: placed.clip.srcIn, length: placed.clip.length) {
                            laneSpan = laneSpan.map { (min($0.start, span.start), max($0.end, span.end)) } ?? span
                            laneBase = lane.volume * placed.clip.volume
                        }
                    }
                }
            }
            if let aTrack, let span = laneSpan {
                let p = AVMutableAudioMixInputParameters(track: aTrack)
                let id = lane.id
                applyEnvelope(p, base: laneBase, span: span,
                              points: fadePoints(span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut) + (gate ? gatePoints : [])) { t in
                    var f = fadeFactor(t, span: span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut)
                    if gate, let who = speaker(at: t), who != id { f *= 0.125 }
                    return f
                }
                mixParams.append(p)
            }
            if let vTrack { videoTrackIDs[lane.id] = vTrack.trackID }
        }

        // Music / SFX lane
        var sfxTracks: [(track: AVMutableCompositionTrack, busyUntil: Double)] = []
        for clip in project.audioLane.sorted(by: { $0.tlStart < $1.tlStart }) {
            guard let media = project.mediaItem(clip.mediaId) else { continue }
            let a = asset(media.file)
            guard let src = try await a.loadTracks(withMediaType: .audio).first else { continue }
            let dur = try await a.load(.duration).seconds
            let len = clip.srcOut - clip.srcIn
            // Cada música/efecto con su propia pista: así cada uno tiene su volumen y sus fades.
            // Si no cae dentro de lo que se exporta (p. ej. un trozo), la pista vacía se quita: AVFoundation falla con pistas sin nada.
            let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            var span: (start: Double, end: Double)?
            if clip.loop, len > 0.5 {
                // En bucle: se repite pegada hasta el final del episodio (los cortes se aplican igual a cada vuelta)
                var at = clip.tlStart
                while at < project.duration - 0.05 {
                    if let s = try place(track: track, source: src, sourceDuration: dur, tlStart: at, srcIn: clip.srcIn, length: len) {
                        span = (span?.start ?? s.start, max(span?.end ?? 0, s.end))
                    }
                    at += len
                }
            } else {
                span = try place(track: track, source: src, sourceDuration: dur, tlStart: clip.tlStart, srcIn: clip.srcIn, length: len)
            }
            guard let span else { comp.removeTrack(track); continue }
            sfxTracks.append((track, clip.tlStart + len))
            let p = AVMutableAudioMixInputParameters(track: track)
            let duck = clip.ducks && !speech.isEmpty
            let low = pow(10, -clip.duckDB / 20)
            // Si la música se corta al final del episodio (bucle o más larga que el video), que no termine de golpe
            let cutAtEnd = clip.loop || clip.tlStart + len > project.duration + 0.05
            let fadeOut = (cutAtEnd && clip.fadeOut == 0) ? 1.5 : clip.fadeOut
            applyEnvelope(p, base: clip.volume, span: span,
                          points: fadePoints(span, fadeIn: clip.fadeIn, fadeOut: fadeOut) + (duck ? duckPoints : [])) { t in
                var f = fadeFactor(t, span: span, fadeIn: clip.fadeIn, fadeOut: fadeOut)
                if duck, inSpeech(t) { f *= low }
                return f
            }
            mixParams.append(p)
        }

        // B-roll: cada video en su pista (se ve entero aunque cruce un corte; la voz sigue debajo)
        var brollScene: [RenderScene.BRoll] = []
        for b in project.brolls where b.duration > 0.1 {
            let o = EditEngine.toOutput(b.start, keep: keep)
                ?? keep.firstIndex { $0.start >= b.start }.map { EditEngine.outputDuration(Array(keep.prefix($0))) }
            guard let o, o < outDuration else { continue }
            let start = introDur + o
            let end = min(introDur + outDuration, start + b.duration)
            guard end - start > 0.1 else { continue }
            if b.isVideo {
                let a = asset(b.file)
                guard let v = try? await a.loadTracks(withMediaType: .video).first else { continue }
                let dur = (try? await a.load(.duration).seconds) ?? 0
                let srcIn = min(max(0, b.srcIn), max(0, dur - 0.1))
                let len = min(end - start, max(0, dur - srcIn))
                guard len > 0.1 else { continue }
                let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                do { try track.insertTimeRange(CMTimeRange(start: cm(srcIn), duration: cm(len)), of: v, at: cm(start)) }
                catch { comp.removeTrack(track); continue }
                if b.volume > 0.01, let at = try? await a.loadTracks(withMediaType: .audio).first {
                    let atrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                    try? atrack.insertTimeRange(CMTimeRange(start: cm(srcIn), duration: cm(len)), of: at, at: cm(start))
                    let p = AVMutableAudioMixInputParameters(track: atrack)
                    p.setVolume(Float(b.volume), at: .zero)
                    mixParams.append(p)
                }
                brollScene.append(RenderScene.BRoll(trackID: track.trackID, image: nil, start: start, end: start + len, fill: b.fill))
            } else {
                guard let img = CIImage(contentsOf: ProjectStore.url(b.file, in: project.id), options: [.applyOrientationProperty: true]) else { continue }
                brollScene.append(RenderScene.BRoll(trackID: nil, image: img, start: start, end: end, fill: b.fill))
            }
        }

        // Música del intro/cierre y relleno para que el video dure hasta el final del cierre
        func bumperMusic(_ b: Bumper?, at start: Double, length: Double) async throws {
            guard let b, let rel = b.musicFile else { return }
            let a = asset(rel)
            guard let src = try await a.loadTracks(withMediaType: .audio).first else { return }
            let dur = try await a.load(.duration).seconds
            let len = min(length, dur)
            guard len > 0.1 else { return }
            let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(len)), of: src, at: cm(start))
            let p = AVMutableAudioMixInputParameters(track: track)
            let sp = (start: start, end: start + len)
            let fo = min(1.5, len / 3)
            applyEnvelope(p, base: b.musicVolume, span: sp, points: fadePoints(sp, fadeIn: 0.3, fadeOut: fo)) { t in
                fadeFactor(t, span: sp, fadeIn: 0.3, fadeOut: fo)
            }
            mixParams.append(p)
        }
        try await bumperMusic(intro, at: 0, length: introDur)
        try await bumperMusic(outro, at: contentEnd, length: outroDur)
        if outroDur > 0 {
            // Un hueco vacío no alarga el video: metemos silencio real bajo el cierre para que dure hasta el final.
            if let silence = await Self.silenceAsset(slug: project.id, seconds: outroDur + 1),
               let src = try? await silence.loadTracks(withMediaType: .audio).first {
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try? track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(outroDur)), of: src, at: cm(contentEnd))
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(0, at: .zero)
                mixParams.append(p)
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams

        var videoComposition: AVMutableVideoComposition?
        var scene: RenderScene?
        if wantVideo {
            let captionsOn = captionsOverride ?? project.captionStyle.enabled
            var style = project.captionStyle
            style.enabled = captionsOn && !project.words.isEmpty
            let captions = style.enabled
                ? EditEngine.captionLines(words: project.words, keep: keep, vertical: format.isVertical, uppercase: style.uppercase)
                : []
            var names: [Int: (name: String, handle: String?)] = [:]
            for lane in project.lanes {
                names[lane.id] = (project.laneName(lane.id), project.participant(forLane: lane.id)?.handle)
            }
            let s = RenderScene(
                renderSize: format.renderSize, format: format,
                layout: layoutOverride ?? project.layout,
                laneOrder: project.lanesOnScreen.map(\.id), trackIDs: videoTrackIDs,
                captions: captions, style: style,
                switches: switches,
                names: names, showNames: project.showNames,
                cropX: project.laneCrop,
                logo: project.showLogo ? project.logoFile.flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id)) } : nil,
                background: (project.showBackground ? project.backgroundFile : nil).flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id)) }
                    .map { img in
                        img.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08])
                    },
                title: project.name,
                sponsorCards: project.showSponsors ? project.sponsorAppearances().compactMap { a in
                    // map to output time; if the moment was cut, show it at the next kept instant
                    let o = EditEngine.toOutput(a.start, keep: keep)
                        ?? keep.firstIndex { $0.start >= a.start }.map { EditEngine.outputDuration(Array(keep.prefix($0))) }
                    guard let o else { return nil }
                    return RenderScene.SponsorCard(start: o, end: o + (a.end - a.start), name: a.sponsor.name, copy: a.sponsor.copy,
                                                   logo: a.sponsor.logoFile.flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id)) })
                } : [],
                photos: Dictionary(uniqueKeysWithValues: project.lanes.compactMap { lane in
                    project.participant(forLane: lane.id)?.photoFile
                        .flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id)) }
                        .map { (lane.id, $0) }
                }),
                options: project.layoutOptions,
                mirror: project.laneMirror)
            if project.showCintillos {
                s.cintillos = Self.cintilloCards(project: project, keep: keep, renderSize: format.renderSize, vertical: format.isVertical)
            }
            s.overlays = Self.overlayCards(project: project, keep: keep, renderSize: format.renderSize)
            s.fastSegmentation = preview
            s.brolls = brollScene
            for (lane, vb) in project.laneBackground {
                s.virtualBG[lane] = RenderScene.VirtualBG(
                    mode: vb.mode, blur: vb.blur, color: TextRenderer.color(vb.color).map { CIColor(color: $0) ?? .black } ?? .black,
                    image: vb.mode == .image ? vb.imageFile.flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id), options: [.applyOrientationProperty: true]) } : nil)
            }
            s.colorLook = project.colorLook
            if project.matchColors { s.laneGain = project.laneColorGain }
            s.contentStart = introDur
            s.contentEnd = contentEnd
            s.introImage = intro.flatMap { CIImage(contentsOf: ProjectStore.url($0.imageFile, in: project.id)) }
            s.outroImage = outro.flatMap { CIImage(contentsOf: ProjectStore.url($0.imageFile, in: project.id)) }
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = PodCompositor.self
            vc.renderSize = format.renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.instructions = [PodInstruction(timeRange: CMTimeRange(start: .zero, duration: cm(contentEnd + outroDur)), scene: s)]
            videoComposition = vc
            scene = s
        }

        return BuiltComposition(asset: comp, videoComposition: videoComposition, audioMix: mix,
                                keep: keep, duration: contentEnd + outroDur, scene: scene, introDuration: introDur)
    }

    /// Un archivo de silencio (lo genera ffmpeg una vez por proyecto) para alargar el video bajo el cierre.
    static func silenceAsset(slug: String, seconds: Double) async -> AVURLAsset? {
        let url = ProjectStore.cacheFolder(for: slug).appendingPathComponent("silencio.m4a")
        let need = max(20, ceil(seconds))
        if let a = Optional(AVURLAsset(url: url)), FileManager.default.fileExists(atPath: url.path),
           let d = try? await a.load(.duration).seconds, d >= seconds { return a }
        guard FFmpeg.isAvailable else { return nil }
        try? FileManager.default.removeItem(at: url)
        do {
            _ = try await FFmpeg.run(["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", String(Int(need)), "-c:a", "aac", "-b:a", "32k", url.path])
        } catch { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? AVURLAsset(url: url) : nil
    }

    private static let overlayContext = CIContext()

    /// Dibuja cada capa una vez, al tamaño del video, y la ubica en el tiempo del video editado.
    static func overlayCards(project: Project, keep: [EditEngine.Span], renderSize: CGSize) -> [RenderScene.OverlayCard] {
        let W = renderSize.width, H = renderSize.height
        let base = min(W, H)
        return project.overlays.compactMap { o in
            let start = EditEngine.toOutput(o.start, keep: keep)
                ?? keep.firstIndex { $0.start >= o.start }.map { EditEngine.outputDuration(Array(keep.prefix($0))) }
            guard let start, o.duration > 0 else { return nil }
            let k = CGFloat(max(0.2, min(4, o.scale)))
            let img: CIImage?
            switch o.kind {
            case .text:
                img = TextRenderer.overlayText(o.text, style: o.style, color: o.color, fontSize: base * 0.07 * k, maxWidth: W * 0.9)
            case .sticker:
                img = TextRenderer.sticker(o.text, fontSize: base * 0.16 * k)
            case .image:
                img = o.imageFile.flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id), options: [.applyOrientationProperty: true]) }
                    .flatMap { pic -> CIImage? in
                        // Cabe en un cuadrado de un tercio del lado corto (× tamaño), sin salirse del cuadro.
                        // Se dibuja una sola vez a su tamaño final para no decodificar la foto en cada cuadro.
                        let e = pic.extent
                        guard e.width > 0, e.height > 0 else { return nil }
                        let sc = min(base * 0.34 * k / max(e.width, e.height), W * 0.95 / e.width, H * 0.95 / e.height)
                        let scaled = pic.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
                        guard let cg = overlayContext.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
                        return CIImage(cgImage: cg)
                    }
            }
            guard let img else { return nil }
            return RenderScene.OverlayCard(id: o.id, start: start, end: start + o.duration, image: img,
                                           cx: o.x, cy: o.y, animate: o.animate)
        }
    }

    /// Dibuja cada cintillo una vez, al tamaño del video, y lo ubica en el tiempo del video editado.
    static func cintilloCards(project: Project, keep: [EditEngine.Span], renderSize: CGSize, vertical: Bool) -> [RenderScene.CintilloCard] {
        let W = renderSize.width, H = renderSize.height
        let width = vertical ? W * 0.92 : min(W * 0.6, H * 1.25)
        let height = vertical ? H * 0.075 : H * 0.12
        return project.cintillos.compactMap { c in
            let o = EditEngine.toOutput(c.start, keep: keep)
                ?? keep.firstIndex { $0.start >= c.start }.map { EditEngine.outputDuration(Array(keep.prefix($0))) }
            guard let o else { return nil }
            let logo = c.logoFile.flatMap { NSImage(contentsOf: ProjectStore.url($0, in: project.id)) }?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            let (tag, accent): (String, NSColor) = {
                switch c.kind {
                case "sponsor": return ("PATROCINA", NSColor(srgbRed: 0.70, green: 0.45, blue: 1.0, alpha: 1))
                case "banner": return ("AHORA", NSColor(srgbRed: 1.0, green: 0.30, blue: 0.30, alpha: 1))
                case "segment": return ("SEGMENTO", NSColor(srgbRed: 0.40, green: 0.62, blue: 1.0, alpha: 1))
                default: return ("COMENTARIO", NSColor(srgbRed: 0.35, green: 0.85, blue: 0.55, alpha: 1))
                }
            }()
            guard let img = TextRenderer.cintillo(title: c.title, text: c.text, tag: tag, accent: accent, logo: logo,
                                                  width: width, height: height) else { return nil }
            return RenderScene.CintilloCard(start: o, end: o + c.duration, image: img)
        }
    }
}
