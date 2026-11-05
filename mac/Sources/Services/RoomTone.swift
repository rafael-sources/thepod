import AVFoundation

/// Tono de sala: el ambiente propio de cada persona (aire, ventilador, la sala) para rellenar los huecos donde su
/// pista no tiene nada —antes de que empiece su grabación, después de que termine, bajo un pitido— y que el
/// corte no suene «muerto». Se toma del segundo más quieto de su grabación que no sea silencio digital.
enum RoomTone {
    /// Cuánto puede durar la muestra y qué tan quieta debe ser para fiarse de ella.
    static let window = 1.0                       // s de ambiente que se toman
    static let minDB: Float = -78                 // por debajo es silencio digital (no hay ambiente que copiar)
    static let maxDB: Float = -38                 // por encima no es ambiente: hay voz o ruido fuerte
    static let loopSeconds = 4.0                  // largo del bucle que se escribe en caché

    /// El segundo más quieto y estable de la persona, en tiempo del episodio. Nil si no hay ambiente usable.
    static func quietestWindow(energy: [Float], hop: Double = EnergyMap.hop) -> (start: Double, db: Float)? {
        let n = Int(window / hop)
        guard energy.count >= n, n > 0 else { return nil }
        var best: (Int, Float)?
        for i in 0...(energy.count - n) {
            let slice = energy[i..<(i + n)]
            let mx = slice.max() ?? -120, mn = slice.min() ?? -120
            // estable: menos de 6 dB entre el punto más alto y el más bajo del segundo
            guard mn > minDB, mx < maxDB, mx - mn < 6 else { continue }
            let mean = slice.reduce(0, +) / Float(n)
            if best == nil || mean < best!.1 { best = (i, mean) }
        }
        return best.map { (Double($0.0) * hop, $0.1) }
    }

    /// Escribe (o devuelve de caché) el bucle de ambiente de una persona: `loopSeconds` de su segundo más quieto,
    /// repetido con cruces de 50 ms para que no se note la costura.
    static func loop(project: Project, lane: Lane, energy: EnergyMap) -> URL? {
        guard let arr = energy.lanes[lane.id], let q = quietestWindow(energy: arr) else { return nil }
        let url = ProjectStore.cacheFolder(for: project.id).appendingPathComponent("tono-sala-\(lane.id)-\(Int(q.start * 10)).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Del tiempo del episodio al archivo fuente de esa persona
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

    /// Repite la muestra hasta `loopSeconds` cruzando 50 ms entre copias (igual potencia).
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
                    if copy > 0, i < x {                       // cruce con la copia anterior
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

    /// Dónde una persona no tiene nada que suene (tiempo del video final): antes de su primer tramo, después del
    /// último y bajo cada pitido. Los huecos de menos de 150 ms no valen la pena.
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

    /// Factor de volumen que suaviza una unión de corte: baja a cero en `w` segundos antes y sube en `w` después.
    static func joinDip(_ t: Double, joins: [Double], w: Double = 0.006) -> Double {
        var f = 1.0
        for j in joins { let d = abs(t - j); if d < w { f = min(f, d / w) } }
        return f
    }
}
