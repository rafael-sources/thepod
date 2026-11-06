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
    /// Intro seconds before the content (0 if none). The outro goes after the content.
    var introDuration: Double = 0
    /// Preview only: what each person sounds like (lane id → meter), for the timeline meter.
    var meters: [Int: ChainTap] = [:]
    /// Room tone: how many people received ambience fill (to show in the UI and the tests).
    var roomToneTracks = 0
    /// Preview only: volume the mix gives each person at each instant of the video (0…).
    var gains: [Int: (Double) -> Double] = [:]
    /// Preview only: the mix loudness (estimated by summing the tracks with their volume).
    var loudness: MixLoudness?

    /// What a person sounds like at instant `t` of the video, in dB (nil if not sounding now).
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
        var errorDescription: String? { String(localized: "No hay nada que reproducir: todo el rango quedó cortado o no hay pistas.") }
    }

    static func build(project: Project, format: ExportFormat, window: EditEngine.Span? = nil,
                      energy: EnergyMap?, layoutOverride: LayoutTemplate? = nil,
                      captionsOverride: Bool? = nil, preview: Bool = false) async throws -> BuiltComposition {
        let keep = EditEngine.keepRanges(duration: project.duration, cuts: project.cuts, window: window)
        let outDuration = EditEngine.outputDuration(keep)
        guard outDuration > 0.1 else { throw Failure.empty }
        // Intro and outro (only in the full video, not in chunks or reels)
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
            var url = ProjectStore.url(rel, in: project.id)
            // Preview: if there's a proxy (lightweight copy) of this recording, it's used; the export always goes to the original
            if preview, ProxyStore.enabled, let m = project.media.first(where: { $0.file == rel && $0.hasVideo }),
               ProxyStore.exists(mediaId: m.id, project: project.id) {
                url = ProxyStore.url(mediaId: m.id, project: project.id)
            }
            let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[rel] = a
            return a
        }
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 90_000) }

        /// Places [tlStart, tlStart+len) of a source onto `track`, skipping whatever falls in cuts.
        /// Returns the span [start, end) in output time occupied by what was placed (for the fades).
        @discardableResult
        func place(track: AVMutableCompositionTrack, source: AVAssetTrack, sourceDuration: Double,
                   tlStart: Double, srcIn: Double, length: Double, speed: Double = 1) throws -> (start: Double, end: Double)? {
            var cursor = 0.0
            var outStart: Double?, outEnd: Double?
            let speed = max(0.1, speed)
            for k in keep {
                let a = max(k.start, tlStart), b = min(k.end, tlStart + length)
                if b - a > 0.01 {
                    // With speed ≠ 1, each episode second consumes `speed` seconds of source
                    let src = srcIn + (a - tlStart) * speed
                    let srcLen = min((b - a) * speed, max(0, sourceDuration - src))
                    let len = srcLen / speed
                    if len > 0.01 {
                        let at = introDur + cursor + (a - k.start)
                        try track.insertTimeRange(CMTimeRange(start: cm(src), duration: cm(srcLen)), of: source, at: cm(at))
                        if speed != 1 { track.scaleTimeRange(CMTimeRange(start: cm(at), duration: cm(srcLen)), toDuration: cm(len)) }
                        if outStart == nil { outStart = at }
                        outEnd = at + len
                    }
                }
                cursor += k.end - k.start
            }
            guard let outStart, let outEnd else { return nil }
            return (outStart, outEnd)
        }
        /// A track's volume curve: the product of several factors (fades, auto-mute, ducking under the voice)
        /// turned into consecutive non-overlapping ramps (AVFoundation ignores overlapping ramps).
        // Preview: each track with its volume curve, to estimate the mix loudness
        var loudSources: [(p: AVMutableAudioMixInputParameters, gain: (Double) -> Double)] = []
        func applyEnvelope(_ p: AVMutableAudioMixInputParameters, base: Double, span: (start: Double, end: Double),
                           points: [Double], factor: @escaping (Double) -> Double) {
            if preview {
                loudSources.append((p, { t in t >= span.start && t <= span.end ? max(0, base * factor(t)) : 0 }))
            }
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
        /// `curved`: equal-power fades (sine), so two crossed clips don't dip in volume in the middle.
        func fadeFactor(_ t: Double, span: (start: Double, end: Double), fadeIn: Double, fadeOut: Double, curved: Bool = false) -> Double {
            let len = span.end - span.start
            let fi = min(fadeIn, len / 2), fo = min(fadeOut, len / 2)
            var f = 1.0
            let shape: (Double) -> Double = curved ? { sin($0 * .pi / 2) } : { $0 }
            if fi > 0.01 { f *= shape(min(1, max(0, (t - span.start) / fi))) }
            if fo > 0.01 { f *= shape(min(1, max(0, (span.end - t) / fo))) }
            return f
        }
        func fadePoints(_ span: (start: Double, end: Double), fadeIn: Double, fadeOut: Double, curved: Bool = false) -> [Double] {
            let fi = min(fadeIn, (span.end - span.start) / 2), fo = min(fadeOut, (span.end - span.start) / 2)
            var pts = [span.start + fi, span.end - fo]
            if curved {
                // The curve is approximated with quarter ramps
                for q in 1..<4 { pts.append(span.start + fi * Double(q) / 4); pts.append(span.end - fo * Double(q) / 4) }
            }
            return pts
        }

        // Who's speaking (in output time): used by the layout and the per-person gate
        let switches = AudioAnalysis.speakerSwitches(project: project, energy: energy, keep: keep)
        let gate = project.fix.gateOthers && project.lanes.count > 1 && energy != nil && switches.count > 1
        /// Who's speaking at instant `t` of the final video (intro included).
        func speaker(at t: Double) -> Int? {
            var cur = switches.first?.lane
            for sw in switches { if introDur + sw.time <= t { cur = sw.lane } else { break } }
            return cur
        }
        // The gate: open spans per person; outside them it drops by `gateDB`. Rises 0.1 s BEFORE they speak
        // (doesn't eat the first syllable) and drops over 0.5 s after the hold (no abrupt cuts).
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

        // Beeps (sensitive words): the person goes silent in that span and a tone plays on top
        let bleepOut: [(lane: Int, start: Double, end: Double)] = project.bleeps.compactMap { b in
            guard let a = EditEngine.toOutput(b.start, keep: keep) else { return nil }
            let z = EditEngine.toOutput(b.end, keep: keep) ?? (a + (b.end - b.start))
            guard z > a else { return nil }
            // A bit wider than the word: the transcript may be off by a few tenths
            return (b.lane, introDur + a - 0.10, introDur + z + 0.12)
        }
        /// Points on a person's volume line, in final video time (those within what's exported)
        func automationPoints(_ lane: Lane) -> [Double] {
            lane.volumePoints.compactMap { pt in EditEngine.toOutput(pt.t, keep: keep).map { introDur + $0 } }
                .flatMap { [$0 - 0.001, $0, $0 + 0.001] }
        }
        func automationGain(_ lane: Lane, _ t: Double) -> Double {
            guard lane.hasAutomation else { return 1 }
            let tl = EditEngine.toTimeline(max(0, t - introDur), keep: keep)
            return pow(10, lane.automationDB(at: tl) / 20)
        }
        // The beep silences EVERYONE in that span: the word also leaks into the others' microphones.
        // Inclusive at the end: that way the start→end ramp stays at 0 and the end→end+0.02 one rises again
        // (previously the end was 1 and the voice ramped up during the whole word: it was heard faintly with the beep).
        func bleepPoints(_ lane: Int) -> [Double] { bleepOut.flatMap { [$0.start - 0.02, $0.start, $0.end, $0.end + 0.02] } }
        func inBleep(_ lane: Int, _ t: Double) -> Bool { bleepOut.contains { t >= $0.start && t <= $0.end } }

        /// Spans (final video time) where someone speaks: to duck the music under the voice.
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
        // Room tone: cut joins (final video time) and how many ambience tracks were added
        let roomTone = project.fix.roomTone
        var joinTimes: [Double] = []
        do { var cursor = 0.0; for k in keep.dropLast() { cursor += k.end - k.start; joinTimes.append(introDur + cursor) } }
        var roomToneTracks = 0
        for lane in project.lanes {
            var vTrack: AVMutableCompositionTrack?
            var aTrack: AVMutableCompositionTrack?
            var laneSpan: (start: Double, end: Double)?
            let audible = project.laneAudible(lane)
            // Even voices by measurement: the gain matching this voice with the others (fixed, before everything else)
            let match = project.matchVoices ? pow(10, lane.matchGain / 20) : 1
            var laneBase = audible ? lane.volume * match : 0
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
                    // Pan: a mono recording can't be panned in the mix; a stereo copy (cached) is used
                    if project.conversationPan, abs(lane.pan) > 0.001,
                       let st = await Self.stereoCopy(project: project, relative: audioRel) { audioRel = st }
                    // The equalizer, «voz pareja» and «menos siseo» no longer generate files: they go in the
                    // real-time voice chain (ChainTap), the same in the preview as in the export.
                    let audioAsset = asset(audioRel)
                    if let src = try await audioAsset.loadTracks(withMediaType: .audio).first {
                        let aDur = try await audioAsset.load(.duration).seconds
                        if aTrack == nil { aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        if let span = try place(track: aTrack!, source: src, sourceDuration: aDur,
                                                tlStart: placed.tlStart, srcIn: placed.clip.srcIn, length: placed.clip.length) {
                            laneSpan = laneSpan.map { (min($0.start, span.start), max($0.end, span.end)) } ?? span
                            laneBase = audible ? lane.volume * placed.clip.volume * match : 0
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
                // Room tone: cut joins fade to zero 6 ms before and rise 6 ms after (no click)
                let joins: [Double] = roomTone ? joinTimes.filter { $0 > span.start + 0.02 && $0 < span.end - 0.02 } : []
                let factor: (Double) -> Double = { t in
                    var f = fadeFactor(t, span: span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut)
                    if gate { f *= gateGain(id, t) }
                    f *= automationGain(lane, t)
                    if inBleep(id, t) { f = 0 }
                    if !joins.isEmpty { f *= RoomTone.joinDip(t, joins: joins) }
                    return f
                }
                applyEnvelope(p, base: laneBase, span: span,
                              points: fadePoints(span, fadeIn: lane.fadeIn, fadeOut: lane.fadeOut) + (gate ? gatePoints(id) : []) + bleepPoints(id) + automationPoints(lane)
                                + joins.flatMap { [$0 - 0.006, $0, $0 + 0.006] },
                              factor: factor)
                // Room tone: this person's ambience where their track has nothing (before, after, under beeps)
                if roomTone, audible, let energy, let loopURL = RoomTone.loop(project: project, lane: lane, energy: energy) {
                    let dead = RoomTone.deadSpans(laneSpan: span, content: (introDur, contentEnd),
                                                  bleeps: bleepOut.filter { $0.lane == id }.map { ($0.start, $0.end) })
                    if !dead.isEmpty, let la = Optional(AVURLAsset(url: loopURL)), let lt = try? await la.loadTracks(withMediaType: .audio).first {
                        let loopDur = (try? await la.load(.duration).seconds) ?? RoomTone.loopSeconds
                        let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                        for d in dead {
                            var at = d.start
                            while at < d.end - 0.01 {
                                let len = min(loopDur, d.end - at)
                                try? track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(len)), of: lt, at: cm(at))
                                at += len
                            }
                        }
                        let rp = AVMutableAudioMixInputParameters(track: track)
                        rp.setVolume(Float(laneBase), at: .zero)
                        mixParams.append(rp)
                        roomToneTracks += 1
                    }
                }
                // The person's voice chain (EQ, even voice, sibilance, limiter) before the mix volume.
                // In the preview it also measures the level for the meter; since it listens BEFORE the volume,
                // the same curve is added when reading it.
                let chainTap = ChainTap(laneId: id, settings: lane.effectiveChain, keep: keep, introDuration: introDur)
                chainTap.pan = project.conversationPan ? lane.pan : 0
                if lane.declick { let d = DeClicker(); d.amount = Float(lane.declickAmount); chainTap.declick = d }
                if lane.noiseReduce, let prof = lane.noiseProfile, prof.count == NoiseReducer.bins {
                    let nr = NoiseReducer(); nr.profile = prof; nr.amount = Float(lane.noiseAmount); chainTap.noise = nr
                }
                if let proc = chainTap.makeProcessor() { p.audioTapProcessor = proc; chainTap.processor = proc; meters[id] = chainTap }
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
            let len = clip.length
            // Each music/effect clip on its own track: that way each has its own volume and fades.
            // If it doesn't fall within what's exported (e.g. a chunk), the empty track is removed: AVFoundation fails with empty tracks.
            let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            var span: (start: Double, end: Double)?
            if clip.loop, len > 0.5 {
                // Looped: repeated back-to-back until the end of the episode (cuts apply the same on every pass)
                var at = clip.tlStart
                while at < project.duration - 0.05 {
                    if let s = try place(track: track, source: src, sourceDuration: dur, tlStart: at, srcIn: clip.srcIn, length: len, speed: clip.speed) {
                        span = (span?.start ?? s.start, max(span?.end ?? 0, s.end))
                    }
                    at += len
                }
            } else {
                span = try place(track: track, source: src, sourceDuration: dur, tlStart: clip.tlStart, srcIn: clip.srcIn, length: len, speed: clip.speed)
            }
            guard let span else { comp.removeTrack(track); continue }
            sfxTracks.append((track, clip.tlStart + len))
            let p = AVMutableAudioMixInputParameters(track: track)
            if clip.speed != 1 { p.audioTimePitchAlgorithm = .spectral }   // stretch or compress without changing pitch
            let duck = clip.ducks && !speech.isEmpty
            let low = pow(10, -clip.duckDB / 20)
            // If the music is cut at the end of the episode (looped or longer than the video), don't let it end abruptly
            let cutAtEnd = clip.loop || clip.tlStart + len > project.duration + 0.05
            let fadeOut = (cutAtEnd && clip.fadeOut == 0) ? 1.5 : clip.fadeOut
            applyEnvelope(p, base: clip.volume, span: span,
                          points: fadePoints(span, fadeIn: clip.fadeIn, fadeOut: fadeOut, curved: clip.crossfade) + (duck ? duckPoints : [])) { t in
                var f = fadeFactor(t, span: span, fadeIn: clip.fadeIn, fadeOut: fadeOut, curved: clip.crossfade)
                if duck, inSpeech(t) { f *= low }
                return f
            }
            mixParams.append(p)
        }

        // B-roll: each video on its own track (shown whole even if it crosses a cut; the voice continues underneath)
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
                // On screen it takes `screen`; from the source it consumes what the speed (or ramp) says and, if that's
                // not enough, it's shortened on screen. With a ramp, 0.25 s chunks each with its own speed.
                var screen = end - start
                if b.sourceNeeded(screenLen: screen) > dur - srcIn {
                    // trim the screen time until the source suffices
                    var lo = 0.0, hi = screen
                    for _ in 0..<24 { let mid = (lo + hi) / 2; if b.sourceNeeded(screenLen: mid) > dur - srcIn { hi = mid } else { lo = mid } }
                    screen = lo
                }
                let segments = b.speedSegments(screenLen: screen)
                let len = segments.reduce(0) { $0 + $1.screen }
                guard len > 0.1 else { continue }
                let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                let atrack: AVMutableCompositionTrack? = (b.volume > 0.01) ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
                let asrc = atrack != nil ? try? await a.loadTracks(withMediaType: .audio).first : nil
                var stretched = false
                do {
                    var src = srcIn, at = start
                    for seg in segments {
                        try track.insertTimeRange(CMTimeRange(start: cm(src), duration: cm(seg.source)), of: v, at: cm(at))
                        if let atrack, let asrc { try? atrack.insertTimeRange(CMTimeRange(start: cm(src), duration: cm(seg.source)), of: asrc, at: cm(at)) }
                        if abs(seg.source - seg.screen) > 1e-6 {
                            track.scaleTimeRange(CMTimeRange(start: cm(at), duration: cm(seg.source)), toDuration: cm(seg.screen))
                            atrack?.scaleTimeRange(CMTimeRange(start: cm(at), duration: cm(seg.source)), toDuration: cm(seg.screen))
                            stretched = true
                        }
                        src += seg.source; at += seg.screen
                    }
                } catch { comp.removeTrack(track); if let atrack { comp.removeTrack(atrack) }; continue }
                if let atrack {
                    if asrc == nil { comp.removeTrack(atrack) } else {
                        let p = AVMutableAudioMixInputParameters(track: atrack)
                        if stretched { p.audioTimePitchAlgorithm = .spectral }
                        p.setVolume(Float(b.volume), at: .zero)
                        mixParams.append(p)
                    }
                }
                // Phone videos come recorded "lying down" with a rotation in the metadata: it's applied when drawing
                let xf = (try? await v.load(.preferredTransform)) ?? .identity
                brollScene.append(RenderScene.BRoll(trackID: track.trackID, image: nil, start: start, end: start + len, fill: b.fill, placement: b.placement, transform: xf, transition: b.transitionIn, grade: b.grade))
            } else {
                guard let img = CIImage(contentsOf: ProjectStore.url(b.file, in: project.id), options: [.applyOrientationProperty: true]) else { continue }
                brollScene.append(RenderScene.BRoll(trackID: nil, image: img, start: start, end: end, fill: b.fill, placement: b.placement, transition: b.transitionIn, grade: b.grade))
            }
        }

        // Intro/outro music and padding so the video lasts until the end of the outro
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
            // An empty gap doesn't lengthen the video: we put real silence under the outro so it lasts until the end.
            if let silence = await Self.silenceAsset(slug: project.id, seconds: outroDur + 1),
               let src = try? await silence.loadTracks(withMediaType: .audio).first {
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try? track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(outroDur)), of: src, at: cm(contentEnd))
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(0, at: .zero)
                mixParams.append(p)
            }
        }

        // Lower thirds: drawn now (also used to put their sounds in the mix)
        let cintilloCardsBuilt = (wantVideo && project.showCintillos)
            ? Self.cintilloCards(project: project, keep: keep, renderSize: format.renderSize, vertical: format.isVertical) : []
        if !cintilloCardsBuilt.isEmpty {
            await Self.cintilloSounds(cards: cintilloCardsBuilt, shift: introDur, comp: comp, mixParams: &mixParams)
        }

        // Beeps on top of sensitive words (also in the MP3)
        if !bleepOut.isEmpty, let tone = await bleepAsset(slug: project.id), let toneTrack = try? await tone.loadTracks(withMediaType: .audio).first {
            let toneDur = (try? await tone.load(.duration).seconds) ?? 0
            for b in bleepOut {
                let len = min(toneDur, b.end - b.start)
                guard len > 0.05 else { continue }
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                do { try track.insertTimeRange(CMTimeRange(start: .zero, duration: cm(len)), of: toneTrack, at: cm(b.start)) }
                catch { comp.removeTrack(track); continue }
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(0.5, at: .zero)       // −6 dB: clearly noticeable without hurting
                mixParams.append(p)
            }
        }

        var loudness: MixLoudness?
        if preview {
            let ml = MixLoudness()
            for src in loudSources {
                if let existing = src.p.audioTapProcessor, let chainTap = meters.values.first(where: { $0.processor === existing }) {
                    ml.add(chainTap, gain: src.gain)
                } else if src.p.audioTapProcessor == nil {
                    let m = MeterTap()
                    if let proc = m.makeProcessor() { src.p.audioTapProcessor = proc; ml.add(m, gain: src.gain) }
                }
            }
            loudness = ml
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
                switches: AudioAnalysis.cameraSwitches(switches, settings: project.studioVideo),
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
            // Studio · Video: manual camera spans, in final video content time
            s.switchTransition = project.studioVideo.switchTransition
            s.cameraSpans = project.studioVideo.cuts.compactMap { c in
                guard let a = Self.outputStart(c.start, keep: keep) else { return nil }
                let z = EditEngine.toOutput(c.end, keep: keep) ?? (a + (c.end - c.start))
                guard z > a + 0.05 else { return nil }
                return RenderScene.CameraSpan(start: a, end: z, lane: c.lane, template: c.template)
            }
            for (lane, vb) in project.laneBackground {
                s.virtualBG[lane] = RenderScene.VirtualBG(
                    mode: vb.mode, blur: vb.blur, color: TextRenderer.color(vb.color).map { CIColor(color: $0) ?? .black } ?? .black,
                    image: vb.mode == .image ? vb.imageFile.flatMap { CIImage(contentsOf: ProjectStore.url($0, in: project.id), options: [.applyOrientationProperty: true]) } : nil)
            }
            if project.layoutOptions.audiogram, let energy, project.lanesOnScreen.allSatisfy({ l in !(project.mediaItem(l.clips.first?.mediaId ?? -1)?.hasVideo ?? false) }) {
                for lane in project.lanes {
                    if let e = energy.lanes[lane.id] { s.audiogram[lane.id] = AudioAnalysis.audiogramCurve(energy: e, keep: keep) }
                }
            }
            if project.layoutOptions.punchIn, let energy {
                for lane in project.lanes {
                    if let e = energy.lanes[lane.id] { s.punchIn[lane.id] = AudioAnalysis.punchInCurve(energy: e, keep: keep) }
                }
            }
            s.colorLook = project.colorLook
            if project.matchColors { s.laneGain = project.laneColorGain }
            s.globalGrade = project.grade.flatMap { $0.isEmpty ? nil : $0 }
            for lane in project.lanes {
                if let g = lane.grade, !g.isEmpty { s.laneGrade[lane.id] = g }
                if var m = lane.mask {
                    m.animation = m.animation.map { $0.mapped { Self.outputStart($0, keep: keep) } }
                    s.laneMask[lane.id] = m
                }
            }
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

        if ProcessInfo.processInfo.environment["THEPOD_DEBUG"] != nil { NSLog("room tone: %d people with ambience · joins %d", roomToneTracks, joinTimes.count) }
        var built = BuiltComposition(asset: comp, videoComposition: videoComposition, audioMix: mix,
                                     keep: keep, duration: contentEnd + outroDur, scene: scene, introDuration: introDur)
        built.meters = meters
        built.roomToneTracks = roomToneTracks
        built.gains = gains
        built.loudness = loudness
        return built
    }

    /// Stereo copy (identical on both channels) of a mono audio, in the project cache; nil if already stereo
    /// or there's no ffmpeg. Returns the path relative to the project folder.
    static func stereoCopy(project: Project, relative: String) async -> String? {
        let src = ProjectStore.url(relative, in: project.id)
        guard let f = try? AVAudioFile(forReading: src) else { return nil }
        if f.processingFormat.channelCount >= 2 { return nil }
        let name = "estereo-" + ((relative as NSString).lastPathComponent as NSString).deletingPathExtension + ".m4a"
        let dst = ProjectStore.cacheFolder(for: project.id).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dst.path) {
            guard FFmpeg.isAvailable else { return nil }
            do { _ = try await FFmpeg.run(["-i", src.path, "-ac", "2", "-c:a", "aac", "-b:a", "256k", dst.path]) } catch { return nil }
        }
        return "cache/" + name
    }

    /// A silence file (ffmpeg generates it once per project) to lengthen the video under the outro.
    /// 1 kHz tone (10 s) to cover words; ffmpeg generates it once per project.
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

    /// Where something starting at `t` (episode time) lands in the final video: if `t` is inside a cut,
    /// it shifts to the next span that remains; if it's outside what's exported (a chunk, a reel), nil.
    static func outputStart(_ t: Double, keep: [EditEngine.Span]) -> Double? {
        if let o = EditEngine.toOutput(t, keep: keep) { return o }
        guard let first = keep.first, let last = keep.last, t >= first.start, t <= last.end else { return nil }
        return keep.firstIndex { $0.start >= t }.map { EditEngine.outputDuration(Array(keep.prefix($0))) }
    }

    /// Draws each layer once, at video size, and places it in the edited video's time.
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
                        // Fits in a square one third of the short side (× size), without leaving the frame.
                        // Drawn only once at its final size so the photo isn't decoded on every frame.
                        let e = pic.extent
                        guard e.width > 0, e.height > 0 else { return nil }
                        let sc = min(base * 0.34 * k / max(e.width, e.height), W * 0.95 / e.width, H * 0.95 / e.height)
                        let scaled = pic.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
                        guard let cg = overlayContext.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
                        return CIImage(cgImage: cg)
                    }
            }
            guard let img else { return nil }
            var card = RenderScene.OverlayCard(id: o.id, start: start, end: start + o.duration, image: img,
                                               cx: o.x, cy: o.y, animate: o.animate)
            if let a = o.animation, !a.isEmpty {
                // Keyframes in final video time; those falling in a cut shift to the next span
                card.anim = a.mapped { Self.outputStart($0, keep: keep) }
                card.baseScale = Double(k)
            }
            card.enter = o.enter
            card.exit = o.exit
            return card
        }
    }

    /// Draws each lower third once, at video size, and places it in the edited video's time.
    static func cintilloCards(project: Project, keep: [EditEngine.Span], renderSize: CGSize, vertical: Bool) -> [RenderScene.CintilloCard] {
        let W = renderSize.width, H = renderSize.height
        let width = vertical ? W * 0.92 : min(W * 0.6, H * 1.25)
        let height = vertical ? H * 0.075 : H * 0.12
        // Podcast color: the most repeated one in the logo (if any); otherwise, each kind's
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
            // Color: the chosen one; otherwise, the sponsor logo's (sponsor style), the podcast's, or the kind's
            let sponsorColor = (c.style == "sponsor") ? logoImage.flatMap { dominantColor($0) } : nil
            let accent = c.color.flatMap { TextRenderer.color($0) } ?? sponsorColor ?? (c.fromDirector ? kindColor : (podcastColor ?? kindColor))
            let art: TextRenderer.CintilloArt?
            switch c.style {
            case "clean": art = TextRenderer.cintilloClean(title: c.title, text: c.text, accent: accent, width: width, height: height * 1.15)
            case "sponsor": art = TextRenderer.cintilloSponsor(title: c.title, text: c.text, tag: c.tagText, accent: accent, logo: logo, width: width * 0.95, height: height * 1.3)
            default: art = TextRenderer.cintilloNews(title: c.title, text: c.text, tag: c.tagText, accent: accent, logo: logo, width: width, height: height)
            }
            if art == nil { NSLog("lower third \(c.id) style \(c.style): couldn't be drawn") }
            guard let art else { return nil }
            if ProcessInfo.processInfo.environment["THEPOD_DEBUG"] != nil { NSLog("lower third \(c.id) \(c.style) o=\(o) dur=\(c.duration) size=\(art.full.extent)") }
            return RenderScene.CintilloCard(start: o, end: o + c.duration, image: art.full, base: art.base, logoW: art.logoW, style: c.style, sound: c.sound)
        }
    }

    /// The dominant color in an image (saturated; avoids whites, blacks and grays).
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

    /// Lower third sounds (low whoosh on entering and a tap on leaving), as audio tracks.
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
