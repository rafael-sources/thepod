import Foundation
import AVFoundation

/// Per-lane loudness (dB every 100 ms, timeline time) used for "who is talking" and energy-based silences.
struct EnergyMap: Codable {
    static let hop = 0.1
    var lanes: [Int: [Float]] = [:]

    func db(lane: Int, at t: Double) -> Float {
        guard let arr = lanes[lane], !arr.isEmpty else { return -120 }
        let i = Int(t / Self.hop)
        return (i >= 0 && i < arr.count) ? arr[i] : -120
    }

    /// Max across lanes — "is anybody talking?"
    var combined: [Float] {
        let n = lanes.values.map(\.count).max() ?? 0
        return (0..<n).map { i in lanes.values.map { i < $0.count ? $0[i] : -120 }.max() ?? -120 }
    }

    /// Active lane per 100 ms window with 0.3 s smoothing and 1 s minimum hold (same idea as postPod's spotlight).
    func activeLanes(duration: Double, laneIds: [Int]) -> [Int] {
        let n = Int(ceil(duration / Self.hop))
        guard !laneIds.isEmpty, n > 0 else { return [] }
        var result = [Int](repeating: laneIds[0], count: n)
        var current = laneIds[0]
        var heldSince = 0
        let minHold = Int(1.0 / Self.hop)
        for i in 0..<n {
            var best = current
            var bestDB: Float = -200
            var currentDB: Float = -200
            for id in laneIds {
                guard let arr = lanes[id] else { continue }
                let lo = max(0, i - 1), hi = min(arr.count - 1, i + 1)
                guard lo <= hi else { continue }
                let avg = arr[lo...hi].reduce(0, +) / Float(hi - lo + 1)
                if avg > bestDB { bestDB = avg; best = id }
                if id == current { currentDB = avg }
            }
            if best != current, bestDB > -42, bestDB - currentDB > 4, i - heldSince >= minHold {
                current = best
                heldSince = i
            }
            result[i] = current
        }
        return result
    }
}

enum AudioAnalysis {
    static func energyURL(_ slug: String) -> URL { ProjectStore.cacheFolder(for: slug).appendingPathComponent("energy.json") }

    static func loadEnergy(_ slug: String) -> EnergyMap? {
        guard let d = try? Data(contentsOf: energyURL(slug)) else { return nil }
        return try? JSONDecoder().decode(EnergyMap.self, from: d)
    }

    static func computeEnergy(project: Project, progress: @escaping (Double) -> Void) async throws -> EnergyMap {
        var map = EnergyMap()
        for (li, lane) in project.lanes.enumerated() {
            var laneDB = [Float](repeating: -120, count: max(0, Int((lane.placed.first?.tlStart ?? 0) / EnergyMap.hop)))
            for placed in lane.placed {
                guard let media = project.mediaItem(placed.clip.mediaId), media.hasAudio else {
                    laneDB += [Float](repeating: -120, count: Int(placed.clip.length / EnergyMap.hop))
                    continue
                }
                let url = ProjectStore.url(media.file, in: project.id)
                let values = try await windowedDB(url: url, from: placed.clip.srcIn, to: placed.clip.srcOut) { f in
                    progress((Double(li) + f) / Double(max(1, project.lanes.count)))
                }
                laneDB += values
            }
            map.lanes[lane.id] = laneDB
        }
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: energyURL(project.id)) }
        return map
    }

    /// Reads audio as 8 kHz mono float and returns RMS in dB per 100 ms window.
    static func windowedDB(url: URL, from: Double, to: Double, hop: Double = EnergyMap.hop, progress: (Double) -> Void) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48000),
                                       end: CMTime(seconds: to, preferredTimescale: 48000))
        let sr = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "audio", code: 1) }
        let win = Int(sr * hop)
        var acc: Float = 0
        var count = 0
        var out: [Float] = []
        let total = max(1, to - from)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            guard let ptr else { continue }
            let n = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: n) { f in
                for i in 0..<n {
                    acc += f[i] * f[i]
                    count += 1
                    if count == win {
                        let rms = sqrt(acc / Float(win))
                        out.append(rms > 0 ? 20 * log10(rms) : -120)
                        acc = 0
                        count = 0
                    }
                }
            }
            if out.count % 600 == 0 { progress(min(1, Double(out.count) * hop / total)) }
        }
        return out
    }

    /// Speaker switches in OUTPUT time for the given keep ranges.
    static func speakerSwitches(project: Project, energy: EnergyMap?, keep: [EditEngine.Span]) -> [SpeakerSwitch] {
        let ids = project.lanes.map(\.id)
        guard let first = ids.first else { return [] }
        guard ids.count > 1, let energy else { return [SpeakerSwitch(time: 0, lane: first)] }
        let active = energy.activeLanes(duration: project.duration, laneIds: ids)
        var switches: [SpeakerSwitch] = []
        var outCursor = 0.0
        for r in keep {
            var t = r.start
            while t < r.end {
                let i = min(active.count - 1, max(0, Int(t / EnergyMap.hop)))
                let lane = active.isEmpty ? first : active[i]
                if switches.last?.lane != lane {
                    switches.append(SpeakerSwitch(time: outCursor + (t - r.start), lane: lane))
                }
                t += EnergyMap.hop
            }
            outCursor += r.end - r.start
        }
        // Collapse very short flashes created by cuts (< 0.8 s on screen).
        var cleaned: [SpeakerSwitch] = []
        for (i, s) in switches.enumerated() {
            let next = i + 1 < switches.count ? switches[i + 1].time : .infinity
            if next - s.time < 0.8, !cleaned.isEmpty { continue }
            if cleaned.last?.lane == s.lane { continue }
            cleaned.append(s)
        }
        return cleaned.isEmpty ? [SpeakerSwitch(time: 0, lane: first)] : cleaned
    }

    /// Punch-in dinámico: cuánto acercarse a una persona en cada 100 ms del video final (1 = nada … 1,045 = tope).
    /// Sale de la energía de su voz: por encima de su nivel típico de habla (percentil 90) menos 12 dB va subiendo,
    /// con subida rápida (0,25 s) y bajada lenta (0,8 s) para que no tiemble.
    static func punchInCurve(energy: [Float], keep: [EditEngine.Span], amount: Double = 0.045) -> [Float] {
        guard !energy.isEmpty else { return [] }
        let talking = energy.filter { $0 > -60 }.sorted()
        guard talking.count > 10 else { return [] }
        let level = Double(talking[Int(Double(talking.count - 1) * 0.9)])
        let hop = EnergyMap.hop
        // fuerza 0…1 en tiempo del episodio, suavizada hacia delante
        var smooth = [Float](repeating: 0, count: energy.count)
        var v = 0.0
        let aAtt = 1 - exp(-hop / 0.25), aRel = 1 - exp(-hop / 0.8)
        for i in 0..<energy.count {
            let raw = max(0, min(1, (Double(energy[i]) - (level - 12)) / 12))
            v += (raw > v ? aAtt : aRel) * (raw - v)
            smooth[i] = Float(v)
        }
        // al tiempo del video final
        let outDur = EditEngine.outputDuration(keep)
        let n = Int(outDur / hop) + 1
        var out = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let t = EditEngine.toTimeline(Double(i) * hop, keep: keep)
            let j = Int(t / hop)
            if j >= 0, j < smooth.count { out[i] = 1 + Float(amount) * smooth[j] }
        }
        return out
    }

    /// Audiograma: nivel de la voz 0…1 cada 100 ms del video final, para dibujar ondas que la siguen.
    /// 0 = 30 dB por debajo del nivel típico de habla, 1 = el nivel típico; sube rápido (50 ms) y baja en 150 ms.
    static func audiogramCurve(energy: [Float], keep: [EditEngine.Span]) -> [Float] {
        guard !energy.isEmpty else { return [] }
        let talking = energy.filter { $0 > -60 }.sorted()
        guard talking.count > 10 else { return [] }
        let level = Double(talking[Int(Double(talking.count - 1) * 0.9)])
        let hop = EnergyMap.hop
        var smooth = [Float](repeating: 0, count: energy.count)
        var v = 0.0
        let aAtt = 1 - exp(-hop / 0.05), aRel = 1 - exp(-hop / 0.15)
        for i in 0..<energy.count {
            let raw = max(0, min(1, (Double(energy[i]) - (level - 30)) / 30))
            v += (raw > v ? aAtt : aRel) * (raw - v)
            smooth[i] = Float(v)
        }
        let n = Int(EditEngine.outputDuration(keep) / hop) + 1
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let j = Int(EditEngine.toTimeline(Double(i) * hop, keep: keep) / hop)
            if j >= 0, j < smooth.count { out[i] = smooth[j] }
        }
        return out
    }

    /// Los cambios de cámara que ve la pantalla (Studio · Video): con «sigue a quien habla» apagado, una sola
    /// cámara (la plantilla manda); si no, los mismos cambios pero sin cambiar antes de `minHold` segundos.
    static func cameraSwitches(_ switches: [SpeakerSwitch], settings: StudioVideoSettings) -> [SpeakerSwitch] {
        guard let first = switches.first else { return [] }
        guard settings.followSpeaker else { return [first] }
        var out: [SpeakerSwitch] = [first]
        let rest = Array(switches.dropFirst())
        for (i, s) in rest.enumerated() {
            guard let last = out.last else { continue }
            // Si llega antes de la permanencia mínima, se pospone; si para entonces ya hay otro cambio, se salta
            let at = max(s.time, last.time + settings.minHold)
            if i + 1 < rest.count, rest[i + 1].time <= at { continue }
            if last.lane == s.lane { continue }
            out.append(SpeakerSwitch(time: at, lane: s.lane))
        }
        return out
    }

    /// «Silenciar a quien no habla», hecho como lo hace una puerta de mezcla de verdad: cada persona queda ABIERTA
    /// mientras habla y un rato después (`hold`), y también cuando habla encima de quien tiene la palabra (risas,
    /// interrupciones). Devuelve, por persona, los tramos abiertos en tiempo del video final (sin intro). Fuera de
    /// esos tramos se baja; quien llama a esto pone las rampas (sube rápido antes de cada tramo, baja suave después).
    /// Antes se bajaba al instante a la otra persona en cada cambio de turno y en conversaciones rápidas «bombeaba».
    static func gateOpenings(project: Project, energy: EnergyMap, keep: [EditEngine.Span],
                             hold: Double = 1.5) -> [Int: [(start: Double, end: Double)]] {
        let ids = project.lanes.map(\.id)
        let active = energy.activeLanes(duration: project.duration, laneIds: ids)
        guard !active.isEmpty else { return [:] }
        let n = active.count
        let holdN = Int((hold / EnergyMap.hop).rounded())
        var out: [Int: [(start: Double, end: Double)]] = [:]
        for id in ids {
            // 1) dónde habla esta persona (en la rejilla de 100 ms del tiempo de la línea de tiempo)
            var habla = [Bool](repeating: false, count: n)
            for i in 0..<n {
                if active[i] == id { habla[i] = true; continue }
                // hablando encima: su voz está a menos de 6 dB de la de quien tiene la palabra
                let mio = energy.db(lane: id, at: Double(i) * EnergyMap.hop)
                let suyo = energy.db(lane: active[i], at: Double(i) * EnergyMap.hop)
                if mio > -42, mio > suyo - 6 { habla[i] = true }
            }
            // 2) se mantiene abierta `hold` segundos después de dejar de hablar
            var abierta = [Bool](repeating: false, count: n)
            var resto = 0
            for i in 0..<n {
                if habla[i] { resto = holdN + 1 }
                if resto > 0 { abierta[i] = true; resto -= 1 }
            }
            // 3) a tiempo del video final, siguiendo los cortes
            var tramos: [(start: Double, end: Double)] = []
            var cursor = 0.0
            for r in keep {
                var t = r.start
                while t < r.end {
                    let i = min(n - 1, max(0, Int(t / EnergyMap.hop)))
                    if abierta[i] {
                        let o = cursor + (t - r.start)
                        let fin = min(o + EnergyMap.hop, cursor + (r.end - r.start))
                        if let u = tramos.last, o - u.end < 0.001 { tramos[tramos.count - 1].end = fin }
                        else { tramos.append((o, fin)) }
                    }
                    t += EnergyMap.hop
                }
                cursor += r.end - r.start
            }
            // 4) silencios cortos entre dos tramos (menos de 1,2 s) no cierran la puerta: bajar y volver a subir
            //    en medio segundo es justo el bombeo que se quiere evitar
            var unidos: [(start: Double, end: Double)] = []
            for t in tramos {
                if let u = unidos.last, t.start - u.end < 1.2 { unidos[unidos.count - 1].end = t.end }
                else { unidos.append(t) }
            }
            out[id] = unidos
        }
        return out
    }

    // MARK: ffmpeg-based jobs

    /// Archivo con la voz limpia de una persona, uno por nivel de limpieza.
    static func enhancedRel(mediaId: Int, level: Int) -> String { "media/voz_\(mediaId)_n\(level).m4a" }

    /// Cuánto de la voz aislada entra en cada nivel (el resto es el original, para que suene natural).
    static func isolationWet(_ level: Int) -> Double { [1: 0.7, 2: 0.88, 3: 1.0][level] ?? 0.88 }

    /// Sonido de estudio: separa la voz del ruido (teclas, perro, calle, ventilador) con el aislador de voz de
    /// Apple —o, si la Mac no lo trae, con la red neuronal de antes—, le da un poco de claridad y la deja a un
    /// volumen parejo con una sola ganancia fija. Sin compresor ni nivelado automático: esos levantaban el ruido
    /// que quedaba y le quitaban naturalidad a la voz. El volumen final de la mezcla se ajusta al exportar.
    static func enhance(media: SourceMedia, slug: String, level: Int, progress: @escaping (Double) -> Void) async throws -> String {
        let rel = enhancedRel(mediaId: media.id, level: level)
        let dest = ProjectStore.url(rel, in: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return rel }
        let cache = ProjectStore.cacheFolder(for: slug)
        // Nombres únicos: dos ventanas trabajando el mismo proyecto no se pisan
        let tag = "\(media.id)_\(UUID().uuidString)"
        let raw = cache.appendingPathComponent("voz_raw_\(tag).wav")
        let clean = cache.appendingPathComponent("voz_clean_\(tag).wav")
        let tmp = cache.appendingPathComponent("voz_\(tag).m4a")
        defer { for u in [raw, clean, tmp] { try? FileManager.default.removeItem(at: u) } }
        let wet = isolationWet(level)
        var cleanedInput = clean
        if VoiceIsolation.isAvailable {
            try await FFmpeg.run(["-i", ProjectStore.url(media.file, in: slug).path, "-vn", "-ac", "1", "-ar", "48000",
                                  "-c:a", "pcm_f32le", raw.path], duration: media.duration) { progress($0 * 0.2) }
            try await VoiceIsolation.process(input: raw, output: clean, wet: wet) { f in progress(0.2 + f * 0.6) }
        } else if let m = FFmpeg.rnnoiseModel {
            let path = m.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "'", with: "\\'")
            try await FFmpeg.run(["-i", ProjectStore.url(media.file, in: slug).path, "-vn", "-ac", "1", "-ar", "48000",
                                  "-af", String(localized: "arnndn=m='\(path)':mix=\(String(format: "%.2f", wet))"), "-c:a", "pcm_f32le", clean.path],
                                 duration: media.duration) { progress($0 * 0.8) }
        } else {
            cleanedInput = ProjectStore.url(media.file, in: slug)
        }
        // Claridad suave y volumen parejo entre personas (−19 LUFS por voz), con una ganancia fija
        var af = "highpass=f=70,equalizer=f=4000:t=q:w=1:g=2"
        if let lufs = await loudness(cleanedInput) {
            af += String(format: ",volume=%.2fdB", max(-15, min(15, -19 - lufs)))
        }
        // Entre palabras, lo poco que deja el aislador (una tecla suelta) se baja: más en Máximo, nada en Natural
        if level >= 2 {
            af += String(localized: ",agate=threshold=0.006:ratio=3:attack=10:release=250:range=\(level >= 3 ? "0.06" : "0.18")")
        }
        af += ",alimiter=limit=0.89:level=0"
        try await FFmpeg.run(["-i", cleanedInput.path, "-vn", "-af", af, "-ar", "48000", "-c:a", "aac", "-b:a", "192k", tmp.path],
                             duration: media.duration) { progress(0.8 + $0 * 0.2) }
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return rel
    }

    /// Archivo del audio de una persona con su ecualizador, a partir de `base` (el limpio o el original).
    static func eqRel(mediaId: Int, base: String, eq: VoiceEQ) -> String {
        let b = (base as NSString).lastPathComponent.replacingOccurrences(of: ".", with: "_")
        let key = eq.key.replacingOccurrences(of: "+", with: "p").replacingOccurrences(of: "-", with: "m").replacingOccurrences(of: ".", with: "")
        return "media/eq_\(mediaId)_\(b)_\(key).m4a"
    }

    static func applyEQ(media: SourceMedia, base: String, eq: VoiceEQ, slug: String, progress: @escaping (Double) -> Void) async throws -> String {
        let rel = eqRel(mediaId: media.id, base: base, eq: eq)
        let dest = ProjectStore.url(rel, in: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return rel }
        let tmp = ProjectStore.cacheFolder(for: slug).appendingPathComponent("eq_\(media.id)_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await FFmpeg.run(["-i", ProjectStore.url(base, in: slug).path, "-vn", "-af", eq.ffmpegFilter,
                              "-ar", "48000", "-c:a", "aac", "-b:a", "192k", tmp.path],
                             duration: media.duration, progress: progress)
        if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.moveItem(at: tmp, to: dest) }
        return rel
    }

    /// Volumen integrado (LUFS) de un archivo, medido con ffmpeg (EBU R128).
    static func loudness(_ url: URL) async -> Double? {
        guard let out = try? await FFmpeg.run(["-i", url.path, "-vn", "-af", String(localized: "ebur128=framelog=quiet"), "-f", "null", "-"], allowFailure: true)
        else { return nil }
        // En el resumen final: "I:         -16.3 LUFS"
        guard let r = out.range(of: #"I:\s+(-?[0-9.]+) LUFS"#, options: [.regularExpression, .backwards]) else { return nil }
        let num = out[r].replacingOccurrences(of: "I:", with: "").replacingOccurrences(of: String(localized: "LUFS"), with: "").trimmingCharacters(in: .whitespaces)
        return Double(num)
    }

    /// 16 kHz mono WAV for Whisper.
    static func whisperAudio(media: SourceMedia, slug: String, progress: @escaping (Double) -> Void) async throws -> URL {
        let dest = ProjectStore.cacheFolder(for: slug).appendingPathComponent("whisper_\(media.id).wav")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let tmp = ProjectStore.cacheFolder(for: slug).appendingPathComponent("whisper_\(media.id)_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var src = ProjectStore.url(media.enhancedAudioFile ?? media.file, in: slug)
        if !FileManager.default.fileExists(atPath: src.path) { src = ProjectStore.url(media.file, in: slug) }
        try await FFmpeg.run(["-i", src.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", tmp.path],
                             duration: media.duration, progress: progress)
        if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.moveItem(at: tmp, to: dest) }
        return dest
    }
}
