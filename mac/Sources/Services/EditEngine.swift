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

    /// Antes de estas palabras, «bueno»/«tipo» son palabra de verdad («es bueno», «un tipo»), no muletilla.
    static let buenoNotFillerAfter: Set<String> = ["es", "muy", "tan", "lo", "mas", "que", "esta", "estuvo", "estaba", "era",
                                                   "fue", "sea", "un", "algo", "super", "re", "menos", "seria", "sera",
                                                   "ser", "estar", "bien", "nada", "tambien", "igual", "tiene", "tenia", "parece"]
    static let tipoNotFillerAfter: Set<String> = ["un", "el", "ese", "este", "esa", "que", "otro", "mismo", "cada", "ningun",
                                                  "algun", "del", "al", "de", "cualquier", "mi", "tu", "su", "buen", "gran"]

    /// Muletillas, con cuidado de no cortar palabras válidas.
    ///
    /// - Sonidos («eh», «mmm»…): se cortan siempre.
    /// - «este», «o sea», «tipo»: se cortan cuando están solos entre pausas, repetidos («este este») o
    ///   pegados a un sonido («este… eh»). Si no, quedan como sugerencia apagada.
    /// - «bueno», «pues», «digamos»: casi siempre son válidos al empezar una frase; nunca se cortan solos,
    ///   quedan como sugerencia apagada para que la persona decida.
    /// - Si por el contexto son palabra de verdad («es bueno», «este tema», «tipo de», «un tipo») no se marcan.
    /// Se mira a la misma persona (las palabras del otro no cuentan como pausa ni como contexto), y no se
    /// toca nada que se pise con la voz de otra persona.
    static func fillerCuts(words: [Word], includeWordFillers: Bool) -> [Cut] {
        let all = words.sorted { $0.s < $1.s }
        var cuts: [Cut] = []
        var byLane: [Int: [Int]] = [:]                  // índices en `all`, por persona
        for (i, w) in all.enumerated() { byLane[w.lane, default: []].append(i) }

        func othersOverlap(_ a: Double, _ b: Double, lane: Int) -> Bool {
            all.contains { $0.lane != lane && $0.s < b - 0.05 && $0.e > a + 0.05 }
        }
        func bounds(_ gi: Int, end: Double) -> (Double, Double)? {
            let w = all[gi]
            let prevEnd = gi > 0 ? all[..<gi].map(\.e).max() ?? 0 : 0
            let nextStart = gi + 1 < all.count ? all[(gi + 1)...].map(\.s).min() ?? end + 0.2 : end + 0.2
            let a = max(prevEnd, w.s - 0.04), b = min(nextStart, end + 0.04)
            return b > a ? (a, b) : nil
        }
        func trailingPunct(_ raw: String) -> Bool {
            guard let last = raw.trimmingCharacters(in: .whitespaces).last else { return false }
            return ",.;:?!…".contains(last)
        }

        for (_, idx) in byLane {
            var skipNext = false
            for (k, gi) in idx.enumerated() {
                if skipNext { skipNext = false; continue }
                let w = all[gi]
                let n = normalize(w.w)
                let prev = k > 0 ? all[idx[k - 1]] : nil
                let next = k + 1 < idx.count ? all[idx[k + 1]] : nil
                let pn = prev.map { normalize($0.w) } ?? ""
                let nn = next.map { normalize($0.w) } ?? ""
                let gapBefore = prev.map { w.s - $0.e } ?? 9
                var end = w.e
                var shown = w.w.trimmingCharacters(in: .whitespacesAndNewlines)

                var sure = false
                var doubtful = false
                if soundFillers.contains(n) {
                    sure = true
                } else if includeWordFillers {
                    var key = n
                    var after = next
                    var rawLast = w.w
                    if n == "o", nn == "sea", let nx = next {
                        key = "o sea"; end = nx.e; skipNext = true
                        after = k + 2 < idx.count ? all[idx[k + 2]] : nil
                        rawLast = nx.w; shown = "o sea"
                    }
                    let an = after.map { normalize($0.w) } ?? ""
                    let gapAfter = after.map { $0.s - end } ?? 9
                    let isolated = gapBefore >= 0.25 && gapAfter >= 0.25
                    let nextIsSound = soundFillers.contains(an)
                    let prevIsSound = soundFillers.contains(pn)
                    switch key {
                    case "este":
                        // «este tema», «en este caso»: demostrativo pegado a la palabra que sigue
                        if !trailingPunct(rawLast), gapAfter < 0.15, !nextIsSound, an != "este" { break }
                        if an == "este" || pn == "este" || nextIsSound || prevIsSound || isolated { sure = true } else { doubtful = true }
                    case "tipo":
                        if an == "de" || tipoNotFillerAfter.contains(pn) { break }
                        if isolated || nextIsSound || prevIsSound { sure = true } else { doubtful = true }
                    case "o sea", "osea", "o_sea":
                        if isolated || nextIsSound || prevIsSound || an == "o" { sure = true } else { doubtful = true }
                    case "bueno":
                        if buenoNotFillerAfter.contains(pn) || an == "para" { break }
                        doubtful = true
                    case "pues", "digamos":
                        doubtful = true
                    default:
                        break
                    }
                }
                guard sure || doubtful else { continue }
                if othersOverlap(w.s, end, lane: w.lane) { continue }
                guard let (a, b) = bounds(gi, end: end) else { continue }
                if sure {
                    cuts.append(Cut(start: a, end: b, kind: .filler, label: "“\(shown)”"))
                } else {
                    cuts.append(Cut(start: a, end: b, kind: .filler, enabled: false,
                                    label: "¿Muletilla? «\(shown.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:?!…")))»",
                                    suggested: true))
                }
            }
        }
        return cuts.sorted { $0.start < $1.start }
    }

    /// Arranques en falso y frases repetidas («es que, es que el…», «de la de la»): sugiere cortar el primer
    /// intento (desde que empieza hasta que empieza el segundo). Siempre apagado: decide la persona.
    static func repeatCuts(words: [Word]) -> [Cut] {
        let all = words.sorted { $0.s < $1.s }
        var cuts: [Cut] = []
        let lanes = Set(all.map(\.lane))
        let neverAlone: Set<String> = ["no", "si", "ya", "muy", "bien", "mas", "nada", "chao", "jaja", "ja"]
        for lane in lanes {
            let lw = all.filter { $0.lane == lane }
            let toks = lw.map { normalize($0.w) }
            var i = 0
            while i < lw.count {
                var found: (n: Int, j: Int)?
                search: for n in stride(from: 4, through: 1, by: -1) where i + n <= lw.count {
                    let a = Array(toks[i..<(i + n)])
                    if a.contains(where: { $0.isEmpty || soundFillers.contains($0) }) { continue }
                    if n == 1, neverAlone.contains(a[0]) { continue }
                    let maxGap = n >= 3 ? 2 : 1                 // palabras en el medio permitidas (con 1-2 palabras: solo una muletilla)
                    for gap in 0...maxGap {
                        let j = i + n + gap
                        guard j + n <= lw.count else { break }
                        // lo que hay en el medio tiene que ser muletilla o sonido («es que, eh, es que»)
                        let middle = toks[(i + n)..<j]
                        if gap > 0, !middle.allSatisfy({ soundFillers.contains($0) || wordFillers.contains($0) }) && n < 3 { continue }
                        if Array(toks[j..<(j + n)]) == a {
                            let pause = lw[j].s - lw[i + n - 1].e
                            let span = lw[j].s - lw[i].s
                            if pause < (n == 1 ? 0.6 : 1.5), span < 4 { found = (n, j); break search }
                        }
                    }
                }
                guard let f = found else { i += 1; continue }
                let first = lw[i], second = lw[f.j]
                let start = max(all.filter { $0.e <= first.s + 0.001 && $0.s < first.s }.map(\.e).max() ?? 0, first.s - 0.04)
                let end = second.s - 0.02
                if end - start >= 0.12, !all.contains(where: { $0.lane != lane && $0.s < end - 0.05 && $0.e > start + 0.05 }) {
                    let phrase = lw[i..<(i + f.n)].map { $0.w.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }.joined(separator: " ")
                    cuts.append(Cut(start: start, end: end, kind: .repeated, enabled: false,
                                    label: "¿Repetido? «\(phrase)»", suggested: true))
                }
                i = f.j
            }
        }
        return cuts.sorted { $0.start < $1.start }
    }

    /// Sonidos sin palabras («eeeh» o «mmm» que la transcripción no escribió): tramos de 0,3 a 1,2 s en los que
    /// el micrófono de una persona suena fuerte (y más que los demás) pero nadie dice ninguna palabra.
    /// Pueden ser también risas o toses: por eso solo se sugieren, apagados.
    static func soundOnlyCuts(words: [Word], energy: EnergyMap) -> [Cut] {
        let hop = EnergyMap.hop
        let all = words.sorted { $0.s < $1.s }
        guard !all.isEmpty else { return [] }
        var cuts: [Cut] = []
        for (lane, env) in energy.lanes {
            let lw = all.filter { $0.lane == lane }
            guard lw.count > 20 else { continue }
            // nivel típico de su voz: mediana de la energía donde habla
            var speech: [Float] = []
            for w in lw { let a = Int(w.s / hop), b = Int(w.e / hop); if a < b, b <= env.count { speech += env[a..<b] } }
            guard speech.count > 50 else { continue }
            let voice = speech.sorted()[speech.count / 2]
            let threshold = voice - 9
            // huecos sin palabras de nadie, de al menos 0,6 s
            var holes: [(Double, Double)] = []
            var lastEnd = 0.0
            for w in all {
                if w.s - lastEnd >= 0.6 { holes.append((lastEnd + 0.12, w.s - 0.12)) }
                lastEnd = max(lastEnd, w.e)
            }
            for (h0, h1) in holes {
                var k = Int(h0 / hop)
                let kEnd = min(env.count, Int(h1 / hop))
                while k < kEnd {
                    guard env[k] >= threshold else { k += 1; continue }
                    var e = k
                    while e < kEnd, env[e] >= threshold - 3 { e += 1 }
                    let dur = Double(e - k) * hop
                    let louder = (k..<e).allSatisfy { i in energy.lanes.allSatisfy { $0.key == lane || i >= $0.value.count || $0.value[i] < env[i] - 6 } }
                    if dur >= 0.3, dur <= 1.2, louder {
                        cuts.append(Cut(start: Double(k) * hop - 0.05, end: Double(e) * hop + 0.05, kind: .filler, enabled: false,
                                        label: "¿Sonido sin palabras?", suggested: true))
                    }
                    k = e + 1
                }
            }
        }
        return cuts.sorted { $0.start < $1.start }
    }

    /// Al volver a calcular los cortes automáticos, conserva lo que la persona ya decidió (prendido o apagado)
    /// en los que caen en el mismo lugar.
    static func carryDecisions(from old: [Cut], into new: [Cut]) -> [Cut] {
        let decided = old.filter { $0.reviewed == true }
        guard !decided.isEmpty else { return new }
        return new.map { c in
            guard let o = decided.first(where: { $0.kind == c.kind && abs($0.start - c.start) < 0.15 && abs($0.end - c.end) < 0.15 }) else { return c }
            var c = c; c.enabled = o.enabled; c.reviewed = true
            return c
        }
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

    // MARK: Corregir texto

    /// Palabras nuevas para una frase corregida a mano. Las que siguen iguales conservan su tiempo exacto;
    /// las nuevas o cambiadas se reparten (según su largo) en el hueco que dejan las que se fueron.
    static func retime(old: [Word], tokens: [String], lane: Int) -> [Word] {
        guard !old.isEmpty else { return [] }
        if tokens.count == old.count { return zip(old, tokens).map { var w = $0; w.w = $1; return w } }
        func plain(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = old.map { plain($0.w) }, b = tokens.map(plain)
        // Subsecuencia común más larga: qué palabras viejas siguen en el texto nuevo
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = (!a[i].isEmpty && a[i] == b[j]) ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if !a[i].isEmpty && a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        var out: [Word] = []
        /// Reparte `toks` entre `from` y `to` según el largo de cada palabra.
        func spread(_ toks: ArraySlice<String>, from: Double, to: Double) {
            guard !toks.isEmpty else { return }
            let end = max(to, from + 0.12 * Double(toks.count))
            let weights = toks.map { Double(max(1, $0.count)) }
            let total = weights.reduce(0, +)
            var t = from
            for (k, tok) in toks.enumerated() {
                let len = (end - from) * weights[k] / total
                out.append(Word(w: tok, s: t, e: t + max(0.05, len - 0.02), p: 1, lane: lane))
                t += len
            }
        }
        var oi = 0, tj = 0
        for (pi, pj) in pairs + [(old.count, tokens.count)] {
            // Hueco: palabras viejas oi..<pi se reemplazan por los tokens tj..<pj
            let from = oi < pi ? old[oi].s : (oi > 0 ? old[oi - 1].e : old[0].s)
            let to = oi < pi ? old[pi - 1].e : (pi < old.count ? old[pi].s : from)
            spread(tokens[tj..<pj], from: from, to: to)
            if pi < old.count {
                var w = old[pi]; w.w = tokens[pj]; out.append(w)
            }
            oi = pi + 1; tj = pj + 1
        }
        return out
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
