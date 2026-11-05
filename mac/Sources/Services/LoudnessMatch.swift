import AVFoundation

/// Voces parejas por medición: la sonoridad integrada de cada persona (ITU-R BS.1770-4: filtro K, bloques de
/// 400 ms cada 100 ms, compuerta absoluta −70 LUFS y relativa −10 LU) y la ganancia fija que las iguala.
/// La compuerta deja fuera los silencios, así que lo que se compara es lo que cada uno habla.
enum LoudnessMatch {
    struct Result: Equatable {
        let lane: Int
        let lufs: Double
        let gainDB: Double
    }

    /// Sonoridad integrada de un archivo (mezclado a mono), o nil si está vacío o no se pudo leer.
    static func integratedLUFS(url: URL, maxSeconds: Double = .infinity) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let ch = Int(fmt.channelCount)
        guard sr > 0, ch > 0, file.length > 0 else { return nil }
        var k = KWeight(sampleRate: sr)
        let hop = Int(sr * 0.1)
        var mono = [Float](repeating: 0, count: hop)
        var hopPowers: [Double] = []          // potencia K de cada 100 ms
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(hop)) else { return nil }
        let maxFrames = maxSeconds.isFinite ? AVAudioFramePosition(maxSeconds * sr) : file.length
        while file.framePosition < min(file.length, maxFrames) {
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(hop)) } catch { break }
            let n = Int(buf.frameLength)
            guard n > 0, let data = buf.floatChannelData else { break }
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<ch { v += data[c][i] }
                mono[i] = v / Float(ch)
            }
            let p = mono.withUnsafeBufferPointer { k.meanSquare($0.baseAddress!, n) }
            hopPowers.append(p)
            if n < hop { break }
        }
        guard hopPowers.count >= 4 else { return nil }
        // Bloques de 400 ms (4 saltos de 100 ms) con solape del 75 %
        var blocks: [Double] = []
        blocks.reserveCapacity(hopPowers.count)
        for i in 3..<hopPowers.count { blocks.append((hopPowers[i - 3] + hopPowers[i - 2] + hopPowers[i - 1] + hopPowers[i]) / 4) }
        let abs = blocks.filter { MixLoudness.lufs($0) > -70 }
        guard !abs.isEmpty else { return nil }
        let gate = MixLoudness.lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let kept = abs.filter { MixLoudness.lufs($0) > gate }
        guard !kept.isEmpty else { return nil }
        return MixLoudness.lufs(kept.reduce(0, +) / Double(kept.count))
    }

    /// Mide cada persona del proyecto (el archivo mejorado si lo hay) y calcula la ganancia que la lleva al
    /// promedio de todas, acotada a ±12 dB para no subir el ruido de una grabación floja hasta las nubes.
    static func measure(project: Project) -> [Result] {
        var measured: [(Int, Double)] = []
        for lane in project.lanes {
            guard let clip = lane.clips.first, let media = project.mediaItem(clip.mediaId), media.hasAudio else { continue }
            var rel = (project.enhanceAudio ? media.enhancedAudioFile : nil) ?? media.file
            if !FileManager.default.fileExists(atPath: ProjectStore.url(rel, in: project.id).path) { rel = media.file }
            if let l = integratedLUFS(url: ProjectStore.url(rel, in: project.id)) { measured.append((lane.id, l)) }
        }
        return gains(for: measured)
    }

    /// La parte sin archivos: dadas las sonoridades, las ganancias hacia el promedio (±12 dB).
    static func gains(for measured: [(lane: Int, lufs: Double)]) -> [Result] {
        guard !measured.isEmpty else { return [] }
        let target = measured.map(\.lufs).reduce(0, +) / Double(measured.count)
        return measured.map { m in
            let g = max(-12, min(12, target - m.lufs))
            return Result(lane: m.lane, lufs: m.lufs, gainDB: (g * 10).rounded() / 10)
        }
    }
}
