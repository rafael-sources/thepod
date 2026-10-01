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
                      captionsOverride: Bool? = nil) async throws -> BuiltComposition {
        let keep = EditEngine.keepRanges(duration: project.duration, cuts: project.cuts, window: window)
        let outDuration = EditEngine.outputDuration(keep)
        guard outDuration > 0.1 else { throw Failure.empty }

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
                        let at = cursor + (a - k.start)
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
        /// Entrada y salida suaves sobre un tramo de salida.
        func fades(_ p: AVMutableAudioMixInputParameters, volume: Double, span: (start: Double, end: Double)?, fadeIn: Double, fadeOut: Double) {
            guard let span else { return }
            let v = Float(volume)
            let fi = min(fadeIn, (span.end - span.start) / 2), fo = min(fadeOut, (span.end - span.start) / 2)
            if fi > 0.01 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: cm(span.start), duration: cm(fi)))
            }
            if fo > 0.01 {
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: cm(span.end - fo), duration: cm(fo)))
            }
        }

        let wantVideo = format != .audio
        for lane in project.lanes {
            var vTrack: AVMutableCompositionTrack?
            var aTrack: AVMutableCompositionTrack?
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
                    let audioAsset = asset(audioRel)
                    if let src = try await audioAsset.loadTracks(withMediaType: .audio).first {
                        let aDur = try await audioAsset.load(.duration).seconds
                        if aTrack == nil { aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        let span = try place(track: aTrack!, source: src, sourceDuration: aDur,
                                             tlStart: placed.tlStart, srcIn: placed.clip.srcIn, length: placed.clip.length)
                        if let p = mixParams.first(where: { $0.trackID == aTrack!.trackID }) {
                            fades(p, volume: lane.volume * placed.clip.volume, span: span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut)
                        } else {
                            let p = AVMutableAudioMixInputParameters(track: aTrack!)
                            p.setVolume(Float(lane.volume * placed.clip.volume), at: .zero)
                            fades(p, volume: lane.volume * placed.clip.volume, span: span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut)
                            mixParams.append(p)
                        }
                    }
                }
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
            let span = try place(track: track, source: src, sourceDuration: dur, tlStart: clip.tlStart, srcIn: clip.srcIn, length: len)
            guard let span else { comp.removeTrack(track); continue }
            sfxTracks.append((track, clip.tlStart + len))
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(Float(clip.volume), at: .zero)
            fades(p, volume: clip.volume, span: span, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut)
            mixParams.append(p)
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
                laneOrder: project.lanes.map(\.id), trackIDs: videoTrackIDs,
                captions: captions, style: style,
                switches: AudioAnalysis.speakerSwitches(project: project, energy: energy, keep: keep),
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
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = PodCompositor.self
            vc.renderSize = format.renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.instructions = [PodInstruction(timeRange: CMTimeRange(start: .zero, duration: cm(outDuration)), scene: s)]
            videoComposition = vc
            scene = s
        }

        return BuiltComposition(asset: comp, videoComposition: videoComposition, audioMix: mix,
                                keep: keep, duration: outDuration, scene: scene)
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
