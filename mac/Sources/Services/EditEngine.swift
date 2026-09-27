import Foundation

/// Pure functions: cuts → keep ranges, timeline↔output mapping, silence / filler detection and caption lines.
enum EditEngine {
    typealias Span = (start: Double, end: Double)

    // MARK: Keep ranges

    /// Ranges of TIMELINE time that reach the output (window minus enabled cuts).
    static func keepRanges(duration: Double, cuts: [Cut], window: Span? = nil) -> [Span] {
        let w0 = max(0, window?.start ?? 0)
        let w1 = min(duration, window?.end ?? duration)
        guard w1 > w0 else { return [] }
        let merged = mergeIntervals(cuts.filter { $0.enabled && $0.end > $0.start }.map { ($0.start, $0.end) })
        var result: [Span] = []
        var cursor = w0
        for c in merged {
            if c.end <= cursor { continue }
            if c.start >= w1 { break }
            if c.start > cursor { result.append((cursor, min(c.start, w1))) }
            cursor = max(cursor, c.end)
            if cursor >= w1 { break }
        }
        if cursor < w1 { result.append((cursor, w1)) }
        return result.filter { $0.end - $0.start > 0.04 }   // drop sub-frame slivers
    }

    static func mergeIntervals(_ list: [Span]) -> [Span] {
        let sorted = list.sorted { $0.start < $1.start }
        var out: [Span] = []
        for r in sorted {
            if let last = out.last, r.start <= last.end + 0.001 {
                out[out.count - 1].end = max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func outputDuration(_ keep: [Span]) -> Double { keep.reduce(0) { $0 + ($1.end - $1.start) } }

    /// Timeline → output time. Returns nil if `t` falls inside a cut.
    static func toOutput(_ t: Double, keep: [Span]) -> Double? {
        var acc = 0.0
        for r in keep {
            if t < r.start - 1e-6 { return nil }
            if t <= r.end + 1e-6 { return acc + (min(t, r.end) - r.start) }
            acc += r.end - r.start
        }
        return nil
    }

    /// Output → timeline time.
    static func toTimeline(_ o: Double, keep: [Span]) -> Double {
        var acc = 0.0
        for r in keep {
            let len = r.end - r.start
            if o <= acc + len { return r.start + (o - acc) }
            acc += len
        }
        return keep.last?.end ?? 0
    }

    // MARK: Silences

    /// Silence cuts from word gaps (all lanes merged). Keeps `pad` seconds of air around speech.
    static func silenceCuts(words: [Word], duration: Double, minGap: Double, pad: Double) -> [Cut] {
        guard !words.isEmpty else { return [] }
        let spans = mergeIntervals(words.map { ($0.s, $0.e) })
        var cuts: [Cut] = []
        var prevEnd = 0.0
        var first = true
        for s in spans {
            let gap = s.start - prevEnd
            let lead = first ? 0.0 : pad
            if gap >= minGap {
                let a = prevEnd + lead, b = s.start - pad
                if b - a > 0.15 {
                    cuts.append(Cut(start: a, end: b, kind: .silence, label: String(format: "Silencio de %.1f s", gap)))
                }
            }
            prevEnd = max(prevEnd, s.end)
            first = false
        }
        if duration - prevEnd >= minGap {
            cuts.append(Cut(start: prevEnd + pad, end: duration, kind: .silence, label: "Silencio final"))
        }
        return cuts
    }

    /// Fallback when there is no transcript: silence from audio energy (dB per 100 ms window, max across lanes).
    static func silenceCuts(energy: [Float], hop: Double, threshold: Float = -38, minGap: Double, pad: Double) -> [Cut] {
        var cuts: [Cut] = []
        var runStart: Int?
        func close(_ end: Int) {
            guard let s = runStart else { return }
            let a = Double(s) * hop + pad, b = Double(end) * hop - pad
            if Double(end - s) * hop >= minGap, b - a > 0.15 {
                cuts.append(Cut(start: a, end: b, kind: .silence, label: String(format: "Silencio de %.1f s", Double(end - s) * hop)))
            }
            runStart = nil
        }
        for (i, db) in energy.enumerated() {
            if db < threshold { if runStart == nil { runStart = i } } else { close(i) }
        }
        close(energy.count)
        return cuts
    }

    /// Safety net: Whisper sometimes skips words. Never cut a stretch where the audio is clearly loud
    /// (someone is talking) for longer than `minRun` seconds — split the silence cut around it.
    static func protectSpeech(_ cuts: [Cut], energy: [Float], hop: Double, threshold: Float = -35,
                              minRun: Double = 0.4, pad: Double) -> [Cut] {
        guard !energy.isEmpty else { return cuts }
        var out: [Cut] = []
        for cut in cuts {
            guard cut.kind == .silence else { out.append(cut); continue }
            let a = max(0, Int(cut.start / hop)), b = min(energy.count, Int(cut.end / hop))
            var loud: [Span] = []
            var runStart: Int?
            if a < b {
                for i in a..<b {
                    if energy[i] > threshold { if runStart == nil { runStart = i } }
                    else if let r = runStart {
                        if Double(i - r) * hop >= minRun { loud.append((Double(r) * hop - pad, Double(i) * hop + pad)) }
                        runStart = nil
                    }
                }
                if let r = runStart, Double(b - r) * hop >= minRun { loud.append((Double(r) * hop - pad, Double(b) * hop + pad)) }
            }
            var cursor = cut.start
            for l in loud {
                if l.start - cursor > 0.3 {
                    var piece = cut; piece.id = UUID(); piece.start = cursor; piece.end = l.start
                    out.append(piece)
                }
                cursor = max(cursor, l.end)
            }
            if cut.end - cursor > 0.3 {
                var piece = cut; piece.id = UUID(); piece.start = cursor
                out.append(piece)
            }
        }
        return out
    }

    // MARK: Fillers

    static let soundFillers: Set<String> = ["eh", "ehh", "ehhh", "ehm", "em", "emm", "mm", "mmm", "mmmm", "hmm", "hm",
                                            "um", "umm", "uh", "uhm", "ah", "ahh", "aah", "eeh", "eee", "ee", "mmh"]
    static let wordFillers: Set<String> = ["este", "o sea", "osea", "pues", "bueno", "digamos", "tipo", "o_sea"]

    static func normalize(_ w: String) -> String {
        w.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    static func fillerCuts(words: [Word], includeWordFillers: Bool) -> [Cut] {
        var cuts: [Cut] = []
        for (i, w) in words.enumerated() {
            let n = normalize(w.w)
            var hit = soundFillers.contains(n)
            var end = w.e
            if !hit, includeWordFillers {
                if wordFillers.contains(n) { hit = true }
                if n == "o", i + 1 < words.count, normalize(words[i + 1].w) == "sea" { hit = true; end = words[i + 1].e }
            }
            guard hit else { continue }
            let prevEnd = i > 0 ? words[i - 1].e : 0
            let nextStart = i + 1 < words.count ? words[i + 1].s : end + 0.2
            let a = max(prevEnd, w.s - 0.04), b = min(nextStart, end + 0.04)
            if b > a {
                cuts.append(Cut(start: a, end: b, kind: .filler, label: "“\(w.w.trimmingCharacters(in: .whitespaces))”"))
            }
        }
        return cuts
    }

    // MARK: Captions

    /// Groups words into short caption lines and maps them to OUTPUT time. Words that were cut disappear.
    static func captionLines(words: [Word], keep: [Span], vertical: Bool, uppercase: Bool) -> [CaptionLine] {
        let maxWords = vertical ? 4 : 8
        let maxChars = vertical ? 22 : 44
        var lines: [CaptionLine] = []
        var current: [CaptionLine.W] = []
        var chars = 0
        var lastEnd = -10.0

        func flush() {
            guard let f = current.first, let l = current.last else { return }
            lines.append(CaptionLine(start: f.start, end: l.end, words: current))
            current = []
            chars = 0
        }

        let sortedWords = words.sorted { $0.s < $1.s }
        for w in sortedWords {
            let mid = (w.s + w.e) / 2
            guard let o0 = toOutput(max(w.s, mid - 0.001), keep: keep) else { continue }
            let o1 = toOutput(w.e, keep: keep) ?? (o0 + max(0.08, w.e - mid))
            var text = w.w.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if uppercase { text = text.uppercased() }
            let start = toOutput(w.s, keep: keep) ?? o0
            let gapBreak = start - lastEnd > 0.7
            if !current.isEmpty && (current.count >= maxWords || chars + text.count > maxChars || gapBreak) { flush() }
            current.append(.init(text: text, start: start, end: max(o1, start + 0.05)))
            chars += text.count + 1
            lastEnd = o1
            if let last = text.last, ".?!…".contains(last) { flush() }
        }
        flush()
        // Hold each line on screen until the next begins (max +0.6 s) so captions don't flicker.
        for i in lines.indices {
            let next = i + 1 < lines.count ? lines[i + 1].start : lines[i].end + 0.6
            lines[i].end = max(lines[i].end, min(next, lines[i].end + 0.6))
        }
        return lines
    }

    // MARK: Transcript text for AI

    static func transcriptForAI(_ project: Project) -> String {
        var out = ""
        var currentLane = -1
        var line = ""
        var lineStart = 0.0
        func flush() {
            guard !line.isEmpty else { return }
            out += "[\(clock(lineStart))] \(project.laneName(currentLane)): \(line)\n"
            line = ""
        }
        for w in project.words.sorted(by: { $0.s < $1.s }) {
            if w.lane != currentLane || line.count > 400 {
                flush()
                currentLane = w.lane
                lineStart = w.s
            }
            line += (line.isEmpty ? "" : " ") + w.w.trimmingCharacters(in: .whitespaces)
        }
        flush()
        return out
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

enum Transcripts {
    /// Sort and remove mic-bleed duplicates: the same word heard on two lanes at the same time.
    static func merge(_ words: [Word]) -> [Word] {
        let sorted = words.sorted { $0.s < $1.s }
        var drop = Set<Int>()
        for i in sorted.indices where !drop.contains(i) {
            var j = i + 1
            while j < sorted.count, sorted[j].s < sorted[i].e + 0.3 {
                let a = sorted[i], b = sorted[j]
                if a.lane != b.lane, EditEngine.normalize(a.w) == EditEngine.normalize(b.w) {
                    let overlap = min(a.e, b.e) - max(a.s, b.s)
                    if overlap > 0.5 * min(a.e - a.s, b.e - b.s) {
                        drop.insert(a.p >= b.p ? j : i)
                    }
                }
                j += 1
            }
        }
        return sorted.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}
