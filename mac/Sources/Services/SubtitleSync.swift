import Foundation

/// Places the transcript words where they actually sound.
///
/// WHY
/// Whisper's per-word timings come out shifted: in the measured projects, the word appeared
/// between 0.1 and 0.45 s (sometimes 0.8 s) BEFORE the voice was heard. Subtitles appeared before
/// the person spoke, and cutting silences made it more noticeable (the phrase ends up stuck to the cut).
///
/// HOW
/// For each person "where there are words" is compared with "where their microphone sounds" (volume every 10 ms).
/// 1. In 60 s spans the overall shift (±0.6 s) that best matches the two is searched.
/// 2. Each phrase (words without a pause longer than 0.35 s) is refined around that shift (±0.6 s).
/// A phrase never passes the same person's previous one, so the order is preserved.
/// All functions return the words in the SAME order they were received (so each word can be
/// tracked before/after, for example for sensitive words).
enum SubtitleSync {
    static let hop = 0.01                   // 10 ms
    static let maxShift = 0.6               // maximum shift searched, in seconds
    static let chunk = 60.0                 // span for the overall shift
    static let phraseGap = 0.35             // pause that separates phrases

    struct Result {
        var words: [Word]
        var moved: Int                      // words shifted by more than 30 ms
        var typicalShift: Double            // typical shift (median), in seconds
    }

    /// Aligns the words to the audio. With `range` (episode time) it only touches words starting there.
    static func align(_ words: [Word], project: Project, range: (start: Double, end: Double)? = nil,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> Result {
        var out = words
        var shifts: [Double] = []
        let lanes = Array(Set(words.map(\.lane))).sorted()
        for (li, laneId) in lanes.enumerated() {
            guard let lane = project.lanes.first(where: { $0.id == laneId }) else { continue }
            // Indices of this person's words, in time order
            let idx = words.indices.filter { i in
                let w = words[i]
                guard w.lane == laneId else { return false }
                if let range { return w.s >= range.start - 0.01 && w.s <= range.end + 0.01 }
                return true
            }.sorted { words[$0].s < words[$1].s }
            guard !idx.isEmpty else { continue }
            let first = words[idx.first!].s, last = words[idx.last!].e
            var prior = 0.0
            var prevEnd = -Double.infinity
            var c0 = first
            while c0 <= last {
                try Task.checkCancellation()
                let c1 = c0 + chunk
                let inChunk = idx.filter { words[$0].s >= c0 && words[$0].s < c1 }
                defer { c0 = c1 }
                guard !inChunk.isEmpty else { continue }
                // Volume of the person's microphone from a bit before to a bit after the span
                let e0 = words[inChunk.first!].s - maxShift - 0.4
                let e1 = words[inChunk.map { $0 }.max { words[$0].e < words[$1].e }!].e + maxShift + 0.4
                let env = try await envelope(project: project, lane: lane, from: e0, to: e1)
                guard env.count > 20 else { continue }
                let z = zscore(env)
                func score(_ list: [Int], _ shift: Double) -> Double {
                    guard let f = list.first, let l = list.last else { return -.infinity }
                    let a = bin(words[f].s + shift, origin: e0) - 30
                    let b = bin(words[l].e + shift, origin: e0) + 30
                    guard b > a else { return -.infinity }
                    var speech = [Bool](repeating: false, count: b - a)
                    for i in list {
                        let s = bin(words[i].s + shift, origin: e0), e = bin(words[i].e + shift, origin: e0)
                        if e > s { for k in max(a, s)..<min(b, e) { speech[k - a] = true } }
                    }
                    var sum = 0.0, n = 0
                    for k in max(0, a)..<min(z.count, b) {
                        sum += (speech[k - a] ? 1 : -0.5) * z[k]
                        n += 1
                    }
                    return n > 0 ? sum / Double(n) : -.infinity
                }
                func best(_ list: [Int], around center: Double, span: Double) -> Double {
                    var bestShift = center, bestScore = -Double.infinity
                    var s = center - span
                    while s <= center + span + 1e-9 {
                        let v = score(list, s)
                        if v > bestScore { bestScore = v; bestShift = s }
                        s += hop
                    }
                    return bestShift
                }
                // 1. Overall shift of the span (only if there's enough speech for it to be reliable)
                let speech = inChunk.reduce(0.0) { $0 + max(0, words[$1].e - words[$1].s) }
                if speech >= 3 { prior = best(inChunk, around: 0, span: maxShift) }
                // 2. Phrase by phrase
                var phrase: [Int] = []
                func flush() {
                    guard let f = phrase.first, let l = phrase.last else { return }
                    var shift = prior
                    if words[l].e - words[f].s >= 0.6 { shift = best(phrase, around: prior, span: maxShift) }
                    shift = max(shift, prevEnd + 0.02 - words[f].s)       // don't overlap the previous phrase
                    for i in phrase {
                        out[i].s = max(0, words[i].s + shift)
                        out[i].e = max(out[i].s + 0.05, words[i].e + shift)
                        shifts.append(shift)
                    }
                    prevEnd = out[l].e
                    phrase = []
                }
                for i in inChunk {
                    if let p = phrase.last, words[i].s - words[p].e > phraseGap { flush() }
                    phrase.append(i)
                }
                flush()
                // 3. Words stretched over a pause ("creo" of 2.5 s): Whisper attaches the silence to the word.
                //    When that silence was cut the word disappeared from the subtitle or showed early. Only
                //    the piece where the voice sounds is kept.
                let floor = percentile(env, 0.2)
                for i in inChunk {
                    let dur = out[i].e - out[i].s
                    let chars = Double(out[i].w.count)
                    guard dur > max(0.7, 0.3 + 0.09 * chars) else { continue }
                    if let seg = loudest(env, origin: e0, from: out[i].s, to: out[i].e, threshold: floor + 12) {
                        out[i].s = max(out[i].s, seg.start - 0.03)
                        out[i].e = min(out[i].e, max(out[i].s + 0.08, seg.end + 0.03))
                    }
                }
                progress((Double(li) + min(1, (c1 - first) / max(1, last - first))) / Double(lanes.count))
            }
        }
        let moved = zip(words, out).filter { abs($0.s - $1.s) > 0.03 }.count
        let sorted = shifts.sorted()
        return Result(words: out, moved: moved, typicalShift: sorted.isEmpty ? 0 : sorted[sorted.count / 2])
    }

    private static func bin(_ t: Double, origin: Double) -> Int { Int(((t - origin) / hop).rounded()) }

    private static func percentile(_ v: [Float], _ q: Double) -> Float {
        guard !v.isEmpty else { return -60 }
        let sorted = v.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    /// The longest voice span (above `threshold` dB) within [from, to]; gaps under 0.15 s don't break it.
    private static func loudest(_ env: [Float], origin: Double, from: Double, to: Double, threshold: Float) -> (start: Double, end: Double)? {
        let a = max(0, bin(from, origin: origin)), b = min(env.count, bin(to, origin: origin))
        guard b - a > 2 else { return nil }
        var best: (Int, Int)?
        var segStart: Int?
        var lastLoud = -100
        for k in a..<b {
            if env[k] >= threshold {
                if segStart == nil || k - lastLoud > 15 { segStart = k }
                lastLoud = k
                if let st = segStart, (best == nil || (k - st) > (best!.1 - best!.0)) { best = (st, k + 1) }
            }
        }
        guard let best, best.1 - best.0 >= 8 else { return nil }      // at least 80 ms of voice
        return (origin + Double(best.0) * hop, origin + Double(best.1) * hop)
    }

    private static func zscore(_ v: [Float]) -> [Double] {
        let d = v.map { Double(max(-60, $0)) }
        let m = d.reduce(0, +) / Double(d.count)
        let sd = sqrt(d.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(d.count))
        return d.map { sd > 0 ? ($0 - m) / sd : 0 }
    }

    /// Volume (dB every 10 ms) of a person's microphone between two episode times. Index 0 = `from`.
    /// Where there's no recording it stays at −60.
    static func envelope(project: Project, lane: Lane, from: Double, to: Double) async throws -> [Float] {
        let n = max(0, Int(((to - from) / hop).rounded(.up)))
        var out = [Float](repeating: -60, count: n)
        for placed in lane.placed {
            let a = max(from, placed.tlStart), b = min(to, placed.tlEnd)
            guard b - a > hop, let media = project.mediaItem(placed.clip.mediaId), media.hasAudio else { continue }
            let src0 = placed.clip.srcIn + (a - placed.tlStart)
            let values = try await AudioAnalysis.windowedDB(url: ProjectStore.url(media.file, in: project.id),
                                                            from: src0, to: src0 + (b - a), hop: hop) { _ in }
            let start = Int(((a - from) / hop).rounded())
            for (k, v) in values.enumerated() where start + k >= 0 && start + k < n { out[start + k] = max(-60, v) }
        }
        return out
    }

    /// Re-listens to a span of the episode (each person separately) and returns their words in episode
    /// time, NOT aligned. 1 s extra is listened to on each side so as not to lose the first and last word.
    static func listen(project: Project, from start: Double, to end: Double,
                       report: @escaping @Sendable (String, Double?) -> Void) async throws -> [Word] {
        let a = max(0, start - 1), b = min(project.duration, end + 1)
        var words: [Word] = []
        for (li, lane) in project.lanes.enumerated() {
            let who = project.laneName(lane.id)
            let label = "\(who) (\(li + 1) de \(project.lanes.count))"
            for placed in lane.placed {
                let t0 = max(a, placed.tlStart), t1 = min(b, placed.tlEnd)
                guard t1 - t0 > 0.3, let media = project.mediaItem(placed.clip.mediaId), media.hasAudio else { continue }
                report(label, nil)
                let full = try await AudioAnalysis.whisperAudio(media: media, slug: project.id) { _ in }
                let piece = ProjectStore.cacheFolder(for: project.id).appendingPathComponent("tramo_\(media.id)_\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: piece) }
                let src0 = placed.clip.srcIn + (t0 - placed.tlStart)
                try await FFmpeg.run(["-ss", String(format: "%.3f", src0), "-t", String(format: "%.3f", t1 - t0),
                                      "-i", full.path, "-c:a", "pcm_s16le", piece.path], duration: t1 - t0)
                let heard = try await Transcriber.shared.transcribe(
                    wav: piece, language: project.language,
                    status: { st in report("\(st) — \(label)", nil) },
                    progress: { f in report(label, f) })
                for w in heard {
                    let s = w.s + t0, e = w.e + t0
                    let mid = (s + e) / 2
                    guard mid >= start - 0.3, mid <= end + 0.3 else { continue }
                    words.append(Word(w: w.w, s: s, e: e, p: w.p, lane: lane.id))
                }
            }
        }
        return Transcripts.merge(words)
    }

    /// Moves sensitive words to the new timings of their words (marks are matched by person and time).
    static func remapSensitive(_ marks: [SensitiveMark], old: [Word], new: [Word]) -> [SensitiveMark] {
        guard !marks.isEmpty, old.count == new.count else { return marks }
        var moved: [String: Word] = [:]
        for (o, n) in zip(old, new) where o.s != n.s {
            moved[SensitiveMark.makeId(lane: o.lane, s: o.s)] = n
        }
        guard !moved.isEmpty else { return marks }
        return marks.map { m in
            guard let w = moved[m.id] else { return m }
            var out = m
            out.id = SensitiveMark.makeId(lane: w.lane, s: w.s)
            out.s = w.s
            out.e = w.e
            return out
        }
    }
}
