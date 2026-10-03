import Foundation

/// Pone las palabras de la transcripción donde realmente suenan.
///
/// POR QUÉ
/// Los tiempos que da Whisper por palabra salen corridos: en los proyectos medidos, la palabra figuraba
/// entre 0,1 y 0,45 s (a veces 0,8 s) ANTES de que se oyera la voz. Los subtítulos aparecían antes de que
/// la persona hablara, y al cortar silencios se notaba más (la frase queda pegada al corte).
///
/// CÓMO
/// Por cada persona se compara "dónde hay palabras" con "dónde suena su micrófono" (volumen cada 10 ms).
/// 1. Por tramos de 60 s se busca el corrimiento general (±0,6 s) que mejor hace coincidir las dos cosas.
/// 2. Cada frase (palabras sin pausa de más de 0,35 s) se afina alrededor de ese corrimiento (±0,6 s).
/// Una frase nunca pasa a la anterior de la misma persona, así el orden se mantiene.
/// Todas las funciones devuelven las palabras en el MISMO orden que se recibieron (para poder seguir
/// cada palabra antes/después, por ejemplo para las palabras sensibles).
enum SubtitleSync {
    static let hop = 0.01                   // 10 ms
    static let maxShift = 0.6               // corrimiento máximo que se busca, en segundos
    static let chunk = 60.0                 // tramo para el corrimiento general
    static let phraseGap = 0.35             // pausa que separa frases

    struct Result {
        var words: [Word]
        var moved: Int                      // palabras que se corrieron más de 30 ms
        var typicalShift: Double            // corrimiento típico (mediana), en segundos
    }

    /// Ajusta las palabras al audio. Con `range` (tiempo del episodio) solo toca las palabras que empiezan ahí.
    static func align(_ words: [Word], project: Project, range: (start: Double, end: Double)? = nil,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> Result {
        var out = words
        var shifts: [Double] = []
        let lanes = Array(Set(words.map(\.lane))).sorted()
        for (li, laneId) in lanes.enumerated() {
            guard let lane = project.lanes.first(where: { $0.id == laneId }) else { continue }
            // Índices de las palabras de esta persona, en orden de tiempo
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
                // Volumen del micrófono de la persona desde un poco antes hasta un poco después del tramo
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
                // 1. Corrimiento general del tramo (solo si hay habla suficiente para que sea confiable)
                let speech = inChunk.reduce(0.0) { $0 + max(0, words[$1].e - words[$1].s) }
                if speech >= 3 { prior = best(inChunk, around: 0, span: maxShift) }
                // 2. Frase por frase
                var phrase: [Int] = []
                func flush() {
                    guard let f = phrase.first, let l = phrase.last else { return }
                    var shift = prior
                    if words[l].e - words[f].s >= 0.6 { shift = best(phrase, around: prior, span: maxShift) }
                    shift = max(shift, prevEnd + 0.02 - words[f].s)       // no pisar la frase anterior
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
                progress((Double(li) + min(1, (c1 - first) / max(1, last - first))) / Double(lanes.count))
            }
        }
        let moved = zip(words, out).filter { abs($0.s - $1.s) > 0.03 }.count
        let sorted = shifts.sorted()
        return Result(words: out, moved: moved, typicalShift: sorted.isEmpty ? 0 : sorted[sorted.count / 2])
    }

    private static func bin(_ t: Double, origin: Double) -> Int { Int(((t - origin) / hop).rounded()) }

    private static func zscore(_ v: [Float]) -> [Double] {
        let d = v.map { Double(max(-60, $0)) }
        let m = d.reduce(0, +) / Double(d.count)
        let sd = sqrt(d.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(d.count))
        return d.map { sd > 0 ? ($0 - m) / sd : 0 }
    }

    /// Volumen (dB cada 10 ms) del micrófono de una persona entre dos tiempos del episodio. Índice 0 = `from`.
    /// Donde no hay grabación queda en −60.
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

    /// Lleva las palabras sensibles a los tiempos nuevos de sus palabras (las marcas se buscan por persona y tiempo).
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
