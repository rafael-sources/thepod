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
    /// Solo en la vista previa: lo que suena de cada persona (id de pista → medidor), para el medidor del timeline.
    var meters: [Int: ChainTap] = [:]
    /// Solo en la vista previa: volumen que la mezcla le da a cada persona en cada instante del video (0…).
    var gains: [Int: (Double) -> Double] = [:]

    /// Lo que suena de una persona en el instante `t` del video, en dB (nil si no está sonando ahora).
    func levelDB(lane: Int, at t: Double) -> Double? {
        guard let db = meters[lane]?.recent() else { return nil }
        let g = gains[lane]?(t) ?? 1
        guard g > 0.0001 else { return -120 }
        return Double(db) + 20 * log10(g)
    }

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
            if ProcessInfo.processInfo.environment["THEPOD_DEBUG"] != nil {
                NSLog("envelope track %d: %@", p.trackID, pts.map { String(format: "%.2f→%.2f", $0, v($0)) }.joined(separator: " "))
            }
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
        // La puerta: tramos abiertos por persona; fuera de ellos baja `gateDB`. Sube en 0,1 s ANTES de que hable
        // (no se come la primera sílaba) y baja en 0,5 s después de la espera (sin cortes bruscos).
        let gateAttack = 0.1, gateRelease = 0.5
        let gateLow = pow(10, -project.fix.gateDB / 20)
        let openings: [Int: [(start: Double, end: Double)]] = (gate && energy != nil)
            ? AudioAnalysis.gateOpenings(project: project, energy: energy!, keep: keep).mapValues { $0.map { (introDur + $0.start, introDur + $0.end) } }
            : [:]
        func gateGain(_ lane: Int, _ t: Double) -> Double {
            guard let tramos = openings[lane] else { return 1 }
            var g = gateLow
            for s in tramos {
                if t >= s.start && t <= s.end { return 1 }
                if t < s.start - gateAttack { break }
                if t < s.start { g = max(g, gateLow + (1 - gateLow) * (1 - (s.start - t) / gateAttack)) }
                else if t - s.end < gateRelease { g = max(g, 1 - (1 - gateLow) * (t - s.end) / gateRelease) }
            }
            return g
        }
        func gatePoints(_ lane: Int) -> [Double] {
            (openings[lane] ?? []).flatMap { [$0.start - gateAttack, $0.start, $0.end, $0.end + gateRelease] }
        }

        // Pitidos (palabras sensibles): la persona se calla en ese tramo y suena un tono encima
        let bleepOut: [(lane: Int, start: Double, end: Double)] = project.bleeps.compactMap { b in
            guard let a = EditEngine.toOutput(b.start, keep: keep) else { return nil }
            let z = EditEngine.toOutput(b.end, keep: keep) ?? (a + (b.end - b.start))
            guard z > a else { return nil }
            // Un poco más ancho que la palabra: la transcripción puede ir corrida unas décimas
            return (b.lane, introDur + a - 0.10, introDur + z + 0.12)
        }
        /// Puntos de la línea de volumen de una persona, en tiempo del video final (los que caen en lo que se exporta)
        func automationPoints(_ lane: Lane) -> [Double] {
            lane.volumePoints.compactMap { pt in EditEngine.toOutput(pt.t, keep: keep).map { introDur + $0 } }
                .flatMap { [$0 - 0.001, $0, $0 + 0.001] }
        }
        func automationGain(_ lane: Lane, _ t: Double) -> Double {
            guard lane.hasAutomation else { return 1 }
            let tl = EditEngine.toTimeline(max(0, t - introDur), keep: keep)
            return pow(10, lane.automationDB(at: tl) / 20)
        }
        // El pitido calla a TODAS las personas en ese tramo: la palabra también se cuela por el micrófono de los demás.
        // Inclusivo en el fin: así la rampa start→end se queda en 0 y la de end→end+0.02 vuelve a subir
        // (antes el fin valía 1 y la voz subía en rampa durante toda la palabra: se oía bajito con el pitido).
        func bleepPoints(_ lane: Int) -> [Double] { bleepOut.flatMap { [$0.start - 0.02, $0.start, $0.end, $0.end + 0.02] } }
        func inBleep(_ lane: Int, _ t: Double) -> Bool { bleepOut.contains { t >= $0.start && t <= $0.end } }

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
        var meters: [Int: ChainTap] = [:]
        var gains: [Int: (Double) -> Double] = [:]
        for lane in project.lanes {
            var vTrack: AVMutableCompositionTrack?
            var aTrack: AVMutableCompositionTrack?
            var laneSpan: (start: Double, end: Double)?
            let audible = project.laneAudible(lane)
            var laneBase = audible ? lane.volume : 0
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
                    // El ecualizador, «voz pareja» y «menos siseo» ya no generan archivos: van en la cadena de
                    // voz en tiempo real (ChainTap), igual en la vista previa que en el export.
                    let audioAsset = asset(audioRel)
                    if let src = try await audioAsset.loadTracks(withMediaType: .audio).first {
                        let aDur = try await audioAsset.load(.duration).seconds
                        if aTrack == nil { aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        if let span = try place(track: aTrack!, source: src, sourceDuration: aDur,
                                                tlStart: placed.tlStart, srcIn: placed.clip.srcIn, length: placed.clip.length) {
                            laneSpan = laneSpan.map { (min($0.start, span.start), max($0.end, span.end)) } ?? span
                            laneBase = audible ? lane.volume * placed.clip.volume : 0
                        }
                    }
                }
            }
            if let aTrack, let span = laneSpan {
                let p = AVMutableAudioMixInputParameters(track: aTrack)
                let id = lane.id
                if ProcessInfo.processInfo.environment["THEPOD_DEBUG"] != nil {
                    NSLog("lane %d %@ audible=%d base=%.2f span=%.2f-%.2f track=%d", id, lane.name, audible ? 1 : 0, laneBase, span.start, span.end, aTrack.trackID)
                }
                let factor: (Double) -> Double = { t in
                    var f = fadeFactor(t, span: span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut)
                    if gate { f *= gateGain(id, t) }
                    f *= automationGain(lane, t)
                    if inBleep(id, t) { f = 0 }
                    return f
                }
                applyEnvelope(p, base: laneBase, span: span,
                              points: fadePoints(span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut) + (gate ? gatePoints(id) : []) + bleepPoints(id) + automationPoints(lane),
                              factor: factor)
                // Cadena de voz de la persona (EQ, voz pareja, siseo, limitador) antes del volumen de la mezcla.
                // En la vista previa además mide el nivel para el medidor; como escucha ANTES del volumen,
                // se le suma la misma curva al leerlo.
                let chainTap = ChainTap(laneId: id, settings: lane.effectiveChain)
                if let proc = chainTap.makeProcessor() { p.audioTapProcessor = proc; meters[id] = chainTap }
                if preview {
                    let base = laneBase
                    gains[id] = { t in t >= span.start && t <= span.end ? base * factor(t) : 0 }
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
        for var b in project.brolls where b.duration > 0.1 {
            b.duration = min(b.duration, BRollClip.maxSeconds)
            let o = Self.outputStart(b.start, keep: keep)
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
                // Videos de teléfono vienen grabados "acostados" con una rotación en los metadatos: se aplica al dibujar
                let xf = (try? await v.load(.preferredTransform)) ?? .identity
                brollScene.append(RenderScene.BRoll(trackID: track.trackID, image: nil, start: start, end: start + len, fill: b.fill, placement: b.placement, transform: xf))
            } else {
                guard let img = CIImage(contentsOf: ProjectStore.url(b.file, in: project.id), options: [.applyOrientationProperty: true]) else { continue }
                brollScene.append(RenderScene.BRoll(trackID: nil, image: img, start: start, end: end, fill: b.fill, placement: b.placement))
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

        // Cintillos: se dibujan ahora (también sirven para poner sus sonidos en la mezcla)
        let cintilloCardsBuilt = (wantVideo && project.showCintillos)
            ? Self.cintilloCards(project: project, keep: keep, renderSize: format.renderSize, vertical: format.isVertical) : []
        if !cintilloCardsBuilt.isEmpty {
            await Self.cintilloSounds(cards: cintilloCardsBuilt, shift: introDur, comp: comp, mixParams: &mixParams)
        }

        // Pitidos encima de las palabras sensibles (también en el MP3)
        if !bleepOut.isEmpty, let tone = await bleepAsset(slug: project.id), let toneTrack = try? await tone.loadTracks(withMediaType: .audio).first {
            let toneDur = (try? await tone.load(.duration).seconds) ?? 0
            for b in bleepOut {
                let len = min(toneDur, b.end - b.start)
                guard len > 0.05 else { continue }
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                do { try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(len)), of: toneTrack, at: cm(b.start)) }
                catch { comp.removeTrack(track); continue }
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(0.5, at: .zero)       // −6 dB: se nota bien sin lastimar
                mixParams.append(p)
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams
        if ProcessInfo.processInfo.environment["THEPOD_DEBUG"] != nil {
            let ids = comp.tracks(withMediaType: .audio).map { t in "\(t.trackID):" + t.segments.map { ($0.sourceURL?.lastPathComponent ?? "?") + "@\($0.timeMapping.target.start.seconds)+\($0.timeMapping.target.duration.seconds)" }.joined(separator: "|") }
            NSLog("audio tracks %@ · mix %@", ids.joined(separator: ","), mixParams.map { "\($0.trackID)" }.joined(separator: ","))
        }

        var videoComposition: AVMutableVideoComposition?
        var scene: RenderScene?
        if wantVideo {
            let captionsOn = captionsOverride ?? project.captionStyle.enabled
            var style = project.captionStyle
            style.enabled = captionsOn && !project.words.isEmpty
            let captions = style.enabled
                ? EditEngine.captionLines(words: project.captionWords, keep: keep, vertical: format.isVertical, uppercase: style.uppercase)
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
                logo: project.showLogo ? project.logoFile.flatMap { ImageFile.ciImage(ProjectStore.url($0, in: project.id)) } : nil,
                background: (project.showBackground ? project.backgroundFile : nil).flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id)) }
                    .map { img in
                        img.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08])
                    },
                title: project.name,
                sponsorCards: project.showSponsors ? project.sponsorAppearances().compactMap { a in
                    // map to output time; if the moment was cut, show it at the next kept instant
                    guard let o = Self.outputStart(a.start, keep: keep) else { return nil }
                    return RenderScene.SponsorCard(start: o, end: o + (a.end - a.start), name: a.sponsor.name, copy: a.sponsor.copy,
                                                   logo: a.sponsor.logoFile.flatMap { ImageFile.ciImage(ProjectStore.url($0, in: project.id)) })
                } : [],
                photos: Dictionary(uniqueKeysWithValues: project.lanes.compactMap { lane in
                    project.participant(forLane: lane.id)?.photoFile
                        .flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id)) }
                        .map { (lane.id, $0) }
                }),
                options: project.layoutOptions,
                mirror: project.laneMirror)
            if project.showCintillos { s.cintillos = cintilloCardsBuilt }
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

        var built = BuiltComposition(asset: comp, videoComposition: videoComposition, audioMix: mix,
                                     keep: keep, duration: contentEnd + outroDur, scene: scene, introDuration: introDur)
        built.meters = meters
        built.gains = gains
        return built
    }

    /// Un archivo de silencio (lo genera ffmpeg una vez por proyecto) para alargar el video bajo el cierre.
    /// Tono de 1 kHz (10 s) para tapar palabras; lo genera ffmpeg una vez por proyecto.
    static func bleepAsset(slug: String) async -> AVURLAsset? {
        let url = ProjectStore.cacheFolder(for: slug).appendingPathComponent("pitido.m4a")
        if FileManager.default.fileExists(atPath: url.path) { return AVURLAsset(url: url) }
        guard FFmpeg.isAvailable else { return nil }
        do {
            _ = try await FFmpeg.run(["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000", "-t", "10",
                                      "-af", "volume=-6dB", "-c:a", "aac", "-b:a", "64k", url.path])
        } catch { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? AVURLAsset(url: url) : nil
    }

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

    /// Dónde cae en el video final algo que empieza en `t` (tiempo del episodio): si `t` está dentro de un corte,
    /// se corre al siguiente tramo que sí queda; si está fuera de lo que se exporta (un trozo, un reel), nil.
    static func outputStart(_ t: Double, keep: [EditEngine.Span]) -> Double? {
        if let o = EditEngine.toOutput(t, keep: keep) { return o }
        guard let first = keep.first, let last = keep.last, t >= first.start, t <= last.end else { return nil }
        return keep.firstIndex { $0.start >= t }.map { EditEngine.outputDuration(Array(keep.prefix($0))) }
    }

    /// Dibuja cada capa una vez, al tamaño del video, y la ubica en el tiempo del video editado.
    static func overlayCards(project: Project, keep: [EditEngine.Span], renderSize: CGSize) -> [RenderScene.OverlayCard] {
        let W = renderSize.width, H = renderSize.height
        let base = min(W, H)
        return project.overlays.compactMap { o -> RenderScene.OverlayCard? in
            let start = Self.outputStart(o.start, keep: keep)
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
        // Color del podcast: el que más se repite en el logo (si hay); si no, el de cada tipo
        let podcastColor = project.logoFile.flatMap { ImageFile.nsImage(ProjectStore.url($0, in: project.id)) }.flatMap { dominantColor($0) }
        return project.cintillos.compactMap { c -> RenderScene.CintilloCard? in
            guard let o = Self.outputStart(c.start, keep: keep) else { return nil }
            let logoImage = c.logoFile.flatMap { ImageFile.nsImage(ProjectStore.url($0, in: project.id)) }
            let logo = logoImage.flatMap { ImageFile.cgImage($0) }
            let kindColor: NSColor = {
                switch c.kind {
                case "sponsor": return NSColor(srgbRed: 0.70, green: 0.45, blue: 1.0, alpha: 1)
                case "banner": return NSColor(srgbRed: 0.84, green: 0.27, blue: 0.27, alpha: 1)
                case "segment": return NSColor(srgbRed: 0.40, green: 0.56, blue: 0.90, alpha: 1)
                default: return NSColor(srgbRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)
                }
            }()
            // Color: el elegido; si no, el del logo del sponsor (estilo sponsor), el del podcast, o el del tipo
            let sponsorColor = (c.style == "sponsor") ? logoImage.flatMap { dominantColor($0) } : nil
            let accent = c.color.flatMap { TextRenderer.color($0) } ?? sponsorColor ?? (c.fromDirector ? kindColor : (podcastColor ?? kindColor))
            let art: TextRenderer.CintilloArt?
            switch c.style {
            case "clean": art = TextRenderer.cintilloClean(title: c.title, text: c.text, accent: accent, width: width, height: height * 1.15)
            case "sponsor": art = TextRenderer.cintilloSponsor(title: c.title, text: c.text, tag: c.tagText, accent: accent, logo: logo, width: width * 0.95, height: height * 1.3)
            default: art = TextRenderer.cintilloNews(title: c.title, text: c.text, tag: c.tagText, accent: accent, logo: logo, width: width, height: height)
            }
            if art == nil { NSLog("cintillo \(c.id) estilo \(c.style): no se pudo dibujar") }
            guard let art else { return nil }
            if ProcessInfo.processInfo.environment["THEPOD_DEBUG"] != nil { NSLog("cintillo \(c.id) \(c.style) o=\(o) dur=\(c.duration) size=\(art.full.extent)") }
            return RenderScene.CintilloCard(start: o, end: o + c.duration, image: art.full, base: art.base, logoW: art.logoW, style: c.style, sound: c.sound)
        }
    }

    /// El color que domina en una imagen (saturado; evita blancos, negros y grises).
    static func dominantColor(_ img: NSImage) -> NSColor? {
        guard let cg = ImageFile.cgImage(img) else { return nil }
        let w = 24, h = 24
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var buckets: [Int: (n: Int, r: Double, g: Double, b: Double)] = [:]
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Double(data[i + 3]) / 255; guard a > 0.5 else { continue }
            let r = Double(data[i]) / 255 / a, g = Double(data[i + 1]) / 255 / a, b = Double(data[i + 2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            guard sat > 0.35, mx > 0.25, mx < 0.97 else { continue }
            let key = Int(r * 4) * 25 + Int(g * 4) * 5 + Int(b * 4)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.n += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        guard let best = buckets.values.max(by: { $0.n < $1.n }), best.n >= 6 else { return nil }
        return NSColor(srgbRed: best.r / Double(best.n), green: best.g / Double(best.n), blue: best.b / Double(best.n), alpha: 1)
    }

    /// Sonidos de los cintillos (whoosh bajo al entrar y un toque al salir), como pistas de audio.
    static func cintilloSounds(cards: [RenderScene.CintilloCard], shift: Double, comp: AVMutableComposition, mixParams: inout [AVMutableAudioMixInputParameters]) async {
        guard let inURL = Bundle.main.url(forResource: "cintillo-in", withExtension: "wav", subdirectory: "Sounds") ?? Bundle.main.url(forResource: "cintillo-in", withExtension: "wav"),
              let outURL = Bundle.main.url(forResource: "cintillo-out", withExtension: "wav", subdirectory: "Sounds") ?? Bundle.main.url(forResource: "cintillo-out", withExtension: "wav"),
              let inTrack = try? await AVURLAsset(url: inURL).loadTracks(withMediaType: .audio).first,
              let outTrack = try? await AVURLAsset(url: outURL).loadTracks(withMediaType: .audio).first else { return }
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 90_000) }
        let level: Float = 0.063   // −24 dB
        for card in cards where card.sound {
            let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(0.6)), of: inTrack, at: cm(shift + card.start))
                if card.end - card.start > 1.2 { try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(0.35)), of: outTrack, at: cm(shift + card.end - 0.3)) }
            } catch { comp.removeTrack(track); continue }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(level, at: .zero)
            mixParams.append(p)
        }
    }
}
