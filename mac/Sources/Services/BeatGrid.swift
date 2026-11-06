import AVFoundation

/// Beat snap: a music clip's hits (onsets) and its tempo, without artificial intelligence.
/// Energy per 10 ms hop (full band and lows), positive flux as «onset strength», peaks with an adaptive
/// threshold; the tempo comes from the autocorrelation of that strength between 60 and 200 BPM and the beat grid is
/// placed with the phase that best lands on the onsets.
struct BeatGrid: Codable, Equatable {
    static let hop = 0.01
    var bpm: Double
    var beats: [Double]           // file seconds
    var onsets: [Double]          // detected onsets (file seconds)
    var duration: Double

    /// A clip's beats placed in episode time.
    func beats(in clip: AudioLaneClip) -> [Double] {
        beats.filter { $0 >= clip.srcIn && $0 <= clip.srcOut }.map { clip.tlStart + ($0 - clip.srcIn) }
    }

    // MARK: Analysis

    /// Energy envelopes (dB) per 10 ms hop: full band and lows only (< 150 Hz, for the kick).
    static func envelopes(url: URL) -> (full: [Float], low: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate, ch = Int(fmt.channelCount)
        guard sr > 0, ch > 0, file.length > 0 else { return nil }
        let hopN = Int(sr * hop)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(hopN)) else { return nil }
        // 2nd-order low-pass at 150 Hz (Butterworth)
        let w0 = 2 * Double.pi * 150 / sr, cs = cos(w0), sn = sin(w0), alpha = sn / (2 * 0.7071)
        let b0 = (1 - cs) / 2, b1 = 1 - cs, b2 = (1 - cs) / 2, a0 = 1 + alpha, a1 = -2 * cs, a2 = 1 - alpha
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var full: [Float] = [], low: [Float] = []
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(hopN)) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let d = buf.floatChannelData else { break }
            var sf = 0.0, sl = 0.0
            for i in 0..<n {
                var v = 0.0
                for c in 0..<ch { v += Double(d[c][i]) }
                v /= Double(ch)
                let y = (b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = v; y2 = y1; y1 = y
                sf += v * v; sl += y * y
            }
            full.append(Float(10 * log10(max(1e-12, sf / Double(n)))))
            low.append(Float(10 * log10(max(1e-12, sl / Double(n)))))
            if n < hopN { break }
        }
        return (full, low, sr)
    }

    /// Onset strength per hop: energy rise (dB) of the full band and the lows, weighting the lows more.
    static func onsetStrength(full: [Float], low: [Float]) -> [Float] {
        let n = min(full.count, low.count)
        guard n > 1 else { return [] }
        var s = [Float](repeating: 0, count: n)
        for i in 1..<n {
            s[i] = max(0, full[i] - full[i - 1]) + 1.5 * max(0, low[i] - low[i - 1])
        }
        return s
    }

    /// Onsets: strength peaks above the local mean (±1 s) plus 1.5 deviations, separated ≥ 120 ms.
    static func onsets(strength s: [Float]) -> [Int] {
        let n = s.count
        guard n > 10 else { return [] }
        let w = Int(1.0 / hop)
        var out: [Int] = []
        var last = -1_000
        for i in 1..<(n - 1) {
            guard s[i] > 0, s[i] >= s[i - 1], s[i] > s[i + 1] else { continue }
            let a = max(0, i - w), b = min(n - 1, i + w)
            var mean: Float = 0; for j in a...b { mean += s[j] }; mean /= Float(b - a + 1)
            var varc: Float = 0; for j in a...b { varc += (s[j] - mean) * (s[j] - mean) }; let sd = sqrt(varc / Float(b - a + 1))
            guard s[i] > mean + 1.5 * sd, s[i] > 1.0, i - last >= Int(0.12 / hop) else { continue }
            out.append(i); last = i
        }
        return out
    }

    /// Tempo by autocorrelation of the onset strength (60–200 BPM), preferring the strongest pulse.
    static func tempo(strength s: [Float]) -> Double? {
        let n = s.count
        guard n > Int(4.0 / hop) else { return nil }
        let mean = s.reduce(0, +) / Float(n)
        let x = s.map { $0 - mean }
        let minLag = Int(60.0 / 200.0 / hop), maxLag = Int(60.0 / 60.0 / hop)
        var best: (lag: Int, r: Float)?
        var r0: Float = 0; for v in x { r0 += v * v }
        guard r0 > 0 else { return nil }
        for lag in minLag...maxLag {
            var r: Float = 0
            var i = 0
            while i + lag < n { r += x[i] * x[i + lag]; i += 1 }
            r /= r0
            // gentle bias towards 90–150 BPM (the most common tempos) to avoid landing on multiples
            let bpm = 60 / (Double(lag) * hop)
            let bias: Float = bpm >= 90 && bpm <= 150 ? 1.0 : 0.85
            if best == nil || r * bias > best!.r { best = (lag, r * bias) }
        }
        guard let b = best, b.r > 0.05 else { return nil }
        return 60 / (Double(b.lag) * hop)
    }

    /// Beat grid with the tempo's period and the phase that best lands on the onsets.
    static func grid(bpm: Double, strength s: [Float], duration: Double) -> [Double] {
        let period = 60 / bpm
        let pN = period / hop
        var bestPhase = 0, bestScore: Float = -1
        let steps = max(1, Int(pN))
        for ph in 0..<steps {
            var score: Float = 0
            var t = Double(ph)
            while Int(t) < s.count { score += s[Int(t)]; t += pN }
            if score > bestScore { bestScore = score; bestPhase = ph }
        }
        var out: [Double] = []
        var t = Double(bestPhase) * hop
        while t < duration { out.append((t * 1000).rounded() / 1000); t += period }
        return out
    }

    static func analyze(url: URL) -> BeatGrid? {
        guard let env = envelopes(url: url) else { return nil }
        let s = onsetStrength(full: env.full, low: env.low)
        let duration = Double(env.full.count) * hop
        let on = onsets(strength: s).map { Double($0) * hop }
        guard let bpm = tempo(strength: s) else {
            return BeatGrid(bpm: 0, beats: [], onsets: on, duration: duration)
        }
        return BeatGrid(bpm: (bpm * 10).rounded() / 10, beats: grid(bpm: bpm, strength: s, duration: duration), onsets: on, duration: duration)
    }

    // MARK: Per-project cache

    static func cacheURL(project: Project, mediaId: Int) -> URL {
        ProjectStore.cacheFolder(for: project.id).appendingPathComponent("ritmo-\(mediaId).json")
    }

    /// The grid of a project's music clip (computed once and cached).
    static func load(project: Project, mediaId: Int) -> BeatGrid? {
        guard let media = project.mediaItem(mediaId) else { return nil }
        let url = cacheURL(project: project, mediaId: mediaId)
        if let d = try? Data(contentsOf: url), let g = try? JSONDecoder().decode(BeatGrid.self, from: d) { return g }
        guard let g = analyze(url: ProjectStore.url(media.file, in: project.id)) else { return nil }
        if let d = try? JSONEncoder().encode(g) { try? d.write(to: url) }
        return g
    }

    /// All beats of the project's music track, in episode time, sorted.
    static func episodeBeats(project: Project) -> [Double] {
        var out: [Double] = []
        for clip in project.audioLane {
            guard let g = load(project: project, mediaId: clip.mediaId), g.bpm > 0 else { continue }
            out += g.beats(in: clip)
        }
        return out.sorted()
    }

    /// The beat nearest to `t` if within `tolerance` seconds.
    static func snap(_ t: Double, to beats: [Double], tolerance: Double) -> Double? {
        guard !beats.isEmpty else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if beats[mid] < t { lo = mid + 1 } else { hi = mid } }
        var best = beats[lo]
        if lo > 0, abs(beats[lo - 1] - t) < abs(best - t) { best = beats[lo - 1] }
        return abs(best - t) <= tolerance ? best : nil
    }
}
