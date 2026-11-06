import AVFoundation

/// Room tone: each person's own ambience (air, fan, the room) to fill the gaps where their
/// track has nothing —before their recording starts, after it ends, under a beep— so the
/// cut doesn't sound «dead». Taken from the quietest second of their recording that isn't digital silence.
enum RoomTone {
    /// How long the sample can be and how quiet it must be to trust it.
    static let window = 1.0                       // s of ambience taken
    static let minDB: Float = -78                 // below this is digital silence (no ambience to copy)
    static let maxDB: Float = -38                 // above this it isn't ambience: there's voice or loud noise
    static let loopSeconds = 4.0                  // length of the loop written to cache

    /// The person's quietest, most stable second, in episode time. Nil if there's no usable ambience.
    static func quietestWindow(energy: [Float], hop: Double = EnergyMap.hop) -> (start: Double, db: Float)? {
        let n = Int(window / hop)
        guard energy.count >= n, n > 0 else { return nil }
        var best: (Int, Float)?
        for i in 0...(energy.count - n) {
            let slice = energy[i..<(i + n)]
            let mx = slice.max() ?? -120, mn = slice.min() ?? -120
            // stable: less than 6 dB between the highest and lowest point of the second
            guard mn > minDB, mx < maxDB, mx - mn < 6 else { continue }
            let mean = slice.reduce(0, +) / Float(n)
            if best == nil || mean < best!.1 { best = (i, mean) }
        }
        return best.map { (Double($0.0) * hop, $0.1) }
    }

    /// Writes (or returns from cache) a person's ambience loop: `loopSeconds` of their quietest second,
    /// repeated with 50 ms crossfades so the seam isn't noticeable.
    static func loop(project: Project, lane: Lane, energy: EnergyMap) -> URL? {
        guard let arr = energy.lanes[lane.id], let q = quietestWindow(energy: arr) else { return nil }
        let url = ProjectStore.cacheFolder(for: project.id).appendingPathComponent("tono-sala-\(lane.id)-\(Int(q.start * 10)).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // From episode time to that person's source file
        guard let placed = lane.placed.first(where: { q.start >= $0.tlStart && q.start + window <= $0.tlEnd }),
              let media = project.mediaItem(placed.clip.mediaId) else { return nil }
        let srcT = placed.clip.srcIn + (q.start - placed.tlStart)
        var rel = (project.enhanceAudio ? media.enhancedAudioFile : nil) ?? media.file
        if !FileManager.default.fileExists(atPath: ProjectStore.url(rel, in: project.id).path) { rel = media.file }
        guard let file = try? AVAudioFile(forReading: ProjectStore.url(rel, in: project.id)) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let n = AVAudioFrameCount(window * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        file.framePosition = AVAudioFramePosition(srcT * sr)
        guard (try? file.read(into: buf, frameCount: n)) != nil, buf.frameLength > n / 2 else { return nil }
        return writeLoop(from: buf, to: url)
    }

    /// Repeats the sample up to `loopSeconds` crossfading 50 ms between copies (equal power).
    static func writeLoop(from buf: AVAudioPCMBuffer, to url: URL) -> URL? {
        let fmt = buf.format
        let sr = fmt.sampleRate
        let ch = Int(fmt.channelCount)
        let src = Int(buf.frameLength)
        let x = Int(0.05 * sr)
        guard src > 2 * x, let data = buf.floatChannelData else { return nil }
        let total = Int(loopSeconds * sr)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)), let o = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(total)
        let step = src - x
        var pos = 0
        var copy = 0
        while pos < total {
            for i in 0..<src {
                let j = pos + i
                guard j < total else { break }
                for c in 0..<ch {
                    var v = data[c][i]
                    if copy > 0, i < x {                       // crossfade with the previous copy
                        let f = Float(i) / Float(x)
                        v = v * sin(f * .pi / 2) + o[c][j] * cos(f * .pi / 2)
                    }
                    o[c][j] = v
                }
            }
            pos += step; copy += 1
        }
        try? FileManager.default.removeItem(at: url)
        guard let file = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { return nil }
        do { try file.write(from: out) } catch { return nil }
        return url
    }

    /// A person's noise print (for print-based reduction): the spectrum of the quietest second.
    static func noiseProfile(project: Project, lane: Lane, energy: EnergyMap) -> (profile: [Float], at: Double)? {
        guard let arr = energy.lanes[lane.id], let q = quietestWindow(energy: arr),
              let placed = lane.placed.first(where: { q.start >= $0.tlStart && q.start + window <= $0.tlEnd }),
              let media = project.mediaItem(placed.clip.mediaId) else { return nil }
        let srcT = placed.clip.srcIn + (q.start - placed.tlStart)
        var rel = (project.enhanceAudio ? media.enhancedAudioFile : nil) ?? media.file
        if !FileManager.default.fileExists(atPath: ProjectStore.url(rel, in: project.id).path) { rel = media.file }
        guard let p = NoiseReducer.profile(url: ProjectStore.url(rel, in: project.id), start: srcT, seconds: window) else { return nil }
        return (p, q.start)
    }

    /// Where a person has nothing sounding (final video time): before their first span, after the
    /// last and under each beep. Gaps under 150 ms aren't worth it.
    static func deadSpans(laneSpan: (start: Double, end: Double)?, content: (start: Double, end: Double),
                         bleeps: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        if let s = laneSpan {
            if s.start - content.start > 0.15 { out.append((content.start, s.start)) }
            if content.end - s.end > 0.15 { out.append((s.end, content.end)) }
        } else {
            out.append((content.start, content.end))
        }
        for b in bleeps where b.end - b.start > 0.15 { out.append((b.start, b.end)) }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Volume factor that smooths a cut join: drops to zero over `w` seconds before and rises over `w` after.
    static func joinDip(_ t: Double, joins: [Double], w: Double = 0.006) -> Double {
        var f = 1.0
        for j in joins { let d = abs(t - j); if d < w { f = min(f, d / w) } }
        return f
    }
}
