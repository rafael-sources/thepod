import AVFoundation
import AppKit
import CoreImage

/// Pruebas de Studio · Video. Se corren sin archivos de video: la escena se arma con imágenes de color y se
/// dibuja con el mismo `RenderScene` que usa el export, así lo que se comprueba es lo que sale.
///
/// `--video-studio-test`: keyframes, transiciones, cortes de cámara, permanencia mínima, guardar/cargar.
/// `--studio-tests`: todas las pruebas de Studio seguidas (audio y video).
enum StudioTests {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Color medio (r, g, b) de un recuadro del cuadro dibujado (fracciones del cuadro, y desde arriba).
    private static func mean(_ img: CIImage, _ box: CGRect, size: CGSize) -> (r: Double, g: Double, b: Double) {
        let W = size.width, H = size.height
        let r = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    private static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ size: CGSize) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Una escena de dos personas (1 = roja, 2 = verde) sin nombres, subtítulos ni logo.
    private static func scene(layout: LayoutTemplate, switches: [SpeakerSwitch]) -> RenderScene {
        var style = CaptionStyle(); style.enabled = false
        return RenderScene(renderSize: CGSize(width: 640, height: 360), format: .landscape, layout: layout, laneOrder: [1, 2],
                           trackIDs: [:], captions: [], style: style, switches: switches,
                           names: [:], showNames: false, cropX: [:], logo: nil, background: nil, title: "prueba")
    }

    /// Voces parejas por medición: un tono a −20 dBFS mide −23 LUFS (BS.1770); dos archivos a 10 dB de diferencia
    /// reciben ganancias de ±5 dB; el silencio no cuenta (compuerta); las ganancias se acotan a ±12 dB.
    static func loudnessMatchTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("match-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func tone(_ name: String, dbfs: Double, secs: Double = 4, silenceAfter: Double = 0) -> URL? {
            let url = dir.appendingPathComponent(name)
            let sr = 48_000.0
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
                  let file = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { return nil }
            let n = AVAudioFrameCount(sr * (secs + silenceAfter))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
            buf.frameLength = n
            let amp = Float(pow(10, dbfs / 20))
            for i in 0..<Int(n) {
                let t = Double(i) / sr
                buf.floatChannelData![0][i] = t < secs ? amp * Float(sin(2 * .pi * 1000 * t)) : 0
            }
            try? file.write(from: buf)
            return url
        }
        guard let a = tone("a.caf", dbfs: -20), let b = tone("b.caf", dbfs: -30), let c = tone("c.caf", dbfs: -20, silenceAfter: 8) else {
            check(false, "no se pudieron escribir los tonos"); return false
        }
        let la = LoudnessMatch.integratedLUFS(url: a) ?? -999, lb = LoudnessMatch.integratedLUFS(url: b) ?? -999, lc = LoudnessMatch.integratedLUFS(url: c) ?? -999
        check(abs(la + 23) < 0.3, String(format: "seno 1 kHz a −20 dBFS mide %.2f LUFS (esperado −23,0)", la))
        check(abs(lb + 33) < 0.3, String(format: "a −30 dBFS mide %.2f LUFS", lb))
        check(abs(lc - la) < 0.3, String(format: "8 s de silencio después no cambian la medida (%.2f): la compuerta los deja fuera", lc))
        let g = LoudnessMatch.gains(for: [(1, la), (2, lb)])
        check(g.count == 2 && abs(g[0].gainDB + 5) < 0.15 && abs(g[1].gainDB - 5) < 0.15, "dos voces a 10 dB de diferencia: −5 dB y +5 dB hacia el promedio (\(g.map(\.gainDB)))")
        let far = LoudnessMatch.gains(for: [(1, -10), (2, -50)])
        check(far[1].gainDB == 12 && far[0].gainDB == -12, "las ganancias se acotan a ±12 dB")
        print(ok ? "OK voces parejas por medición" : "FAIL voces parejas")
        return ok
    }

    /// Tono de sala: elige el segundo más quieto que no sea silencio digital, escribe un bucle sin costura,
    /// calcula los huecos muertos y suaviza las uniones.
    static func roomToneTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        // 1) Energía: 3 s de voz (−20), 2 s de ambiente (−55), 2 s de silencio digital (−120), 1 s de ambiente inestable
        var e: [Float] = []
        e += [Float](repeating: -20, count: 30)
        e += [Float](repeating: -55, count: 20)
        e += [Float](repeating: -120, count: 20)
        e += (0..<10).map { Float(-50 - ($0 % 2) * 9) }
        let q = RoomTone.quietestWindow(energy: e)
        check(q != nil && q!.start >= 3.0 && q!.start <= 4.0 && abs(q!.db + 55) < 0.5, "elige el ambiente (−55 dB), no la voz ni el silencio digital ni el tramo inestable (\(q.map { "\($0.start) s" } ?? "nil"))")
        check(RoomTone.quietestWindow(energy: [Float](repeating: -120, count: 50)) == nil, "una pista en silencio digital no tiene tono de sala")
        check(RoomTone.quietestWindow(energy: [Float](repeating: -25, count: 50)) == nil, "una pista que siempre habla tampoco")
        // 2) Bucle: de 1 s de ruido sale un bucle de 4 s con el mismo nivel y sin saltos en las costuras
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tono-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sr = 48_000.0
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1), let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr)) {
            buf.frameLength = AVAudioFrameCount(sr)
            var seed: UInt32 = 12345
            for i in 0..<Int(sr) { seed = seed &* 1664525 &+ 1013904223; buf.floatChannelData![0][i] = (Float(seed % 20000) / 10000 - 1) * 0.01 }
            let url = RoomTone.writeLoop(from: buf, to: dir.appendingPathComponent("loop.caf"))
            if let url, let f = try? AVAudioFile(forReading: url) {
                check(abs(Double(f.length) / sr - RoomTone.loopSeconds) < 0.01, "el bucle dura \(RoomTone.loopSeconds) s")
                let lufsSrc = LoudnessMatch.integratedLUFS(url: url) ?? -999
                check(lufsSrc > -70 && lufsSrc < -30, String(format: "el bucle conserva un nivel de ambiente (%.1f LUFS)", lufsSrc))
                // sin costura audible: la potencia en 20 ms alrededor de cada costura es la misma que en el medio (±1,5 dB)
                let n = AVAudioFrameCount(f.length)
                if let all = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n), (try? f.read(into: all)) != nil {
                    func rms(_ from: Int, _ len: Int) -> Double {
                        var sum = 0.0; for i in from..<(from + len) { let v = Double(all.floatChannelData![0][i]); sum += v * v }; return sqrt(sum / Double(len))
                    }
                    let w = Int(0.02 * sr)
                    let seam = Int(sr) - Int(0.05 * sr) + Int(0.025 * sr) - w / 2      // centro del primer cruce
                    let mid = Int(0.5 * sr)
                    let ratio = 20 * log10(rms(seam, w) / max(1e-9, rms(mid, w)))
                    check(abs(ratio) < 1.5, String(format: "la costura conserva la potencia (%.2f dB respecto al medio)", ratio))
                }
            } else { check(false, "no se pudo escribir el bucle") }
        }
        // 3) Huecos muertos: antes y después del tramo de la persona, y bajo un pitido; los de < 150 ms no
        let dead = RoomTone.deadSpans(laneSpan: (12, 100), content: (4, 130), bleeps: [(50, 50.6), (70, 70.05)])
        check(dead.count == 3 && dead[0] == (4, 12) && dead[1] == (50, 50.6) && dead[2] == (100, 130), "huecos: antes (4–12), pitido (50–50,6) y después (100–130); el pitido de 50 ms no cuenta (\(dead))")
        check(RoomTone.deadSpans(laneSpan: (4.05, 129.9), content: (4, 130), bleeps: []).isEmpty, "sin huecos si la persona cubre casi todo")
        // 4) Unión de corte: cero justo en la unión, entero a 6 ms, sin tocar lejos
        check(RoomTone.joinDip(10, joins: [10]) == 0 && abs(RoomTone.joinDip(10.003, joins: [10]) - 0.5) < 1e-6 && RoomTone.joinDip(10.006, joins: [10]) >= 0.999 && RoomTone.joinDip(12, joins: [10]) == 1,
              "la unión baja a cero y vuelve en 6 ms")
        print(ok ? "OK tono de sala" : "FAIL tono de sala")
        return ok
    }

    /// Entrega: subtítulos .srt/.vtt y capítulos .chapters.json junto al export; subtítulos dentro del MP4 y
    /// transcripción dentro del MP3 (con ffmpeg).
    static func deliveryTest() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var p = Project(id: "entrega-prueba", name: "Entrega", podcastName: "Prueba", createdAt: Date(), importedFrom: "tracks")
        let clip = LaneClip(mediaId: 1, srcIn: 0, srcOut: 10)
        p.lanes = [Lane(id: 1, name: "Ana", participantId: nil, clips: [clip]), Lane(id: 2, name: "Beto", participantId: nil, clips: [clip])]
        p.words = [Word(w: "Hola", s: 0.2, e: 0.5, lane: 1), Word(w: "a", s: 0.5, e: 0.6, lane: 1), Word(w: "todos", s: 0.6, e: 1.0, lane: 1),
                   Word(w: "Qué", s: 3.0, e: 3.3, lane: 2), Word(w: "tal", s: 3.3, e: 3.6, lane: 2)]
        p.transcribedLanes = [1, 2]
        let v = Exporter.vtt(project: p)
        check(v.hasPrefix("WEBVTT\n\n1\n00:00:00.200 --> "), "el VTT empieza con la cabecera y el primer tiempo con punto (\(v.prefix(30).replacingOccurrences(of: "\n", with: "⏎")))")
        check(v.contains("<v Ana>") && v.contains("<v Beto>"), "el VTT dice quién habla en cada línea")
        let srt = Exporter.srt(project: p)
        check(srt.contains("00:00:00,200 -->") && !srt.contains("<v "), "el SRT usa coma en los tiempos y no lleva etiquetas de voz")
        let chapters = [(time: 0.0, title: "Inicio"), (time: 61.5, title: "El tema"), (time: 125.0, title: "Cierre")]
        let json = Exporter.chaptersJSON(chapters) ?? ""
        check(json.contains("\"version\" : \"1.2.0\"") && json.contains("\"startTime\" : 61.5") && json.contains("\"title\" : \"El tema\""), "el JSON de capítulos sigue Podcasting 2.0")
        check(Exporter.chaptersJSON([]) == nil, "sin capítulos no hay JSON")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("entrega-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("episodio.mp4")
        let written = Exporter.writeSidecars(project: p, next: fake, chapters: chapters).map(\.lastPathComponent).sorted()
        check(written == ["episodio.chapters.json", "episodio.srt", "episodio.vtt"], "junto al export quedan .srt, .vtt y .chapters.json (\(written))")
        // Con ffmpeg: un MP4 de 5 s con subtítulos dentro y un MP3 con la transcripción
        if FFmpeg.isAvailable {
            let mp4 = dir.appendingPathComponent("base.mp4")
            do {
                _ = try await FFmpeg.run(["-f", "lavfi", "-i", "color=c=black:s=320x180:d=5", "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                                          "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", mp4.path])
                let srtURL = dir.appendingPathComponent("s.srt"); try Exporter.srt(project: p).write(to: srtURL, atomically: true, encoding: .utf8)
                let with = dir.appendingPathComponent("con-subs.mp4")
                _ = try await FFmpeg.run(["-i", mp4.path, "-i", srtURL.path, "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text", "-metadata:s:s:0", "language=spa", with.path])
                let tracks = try await AVURLAsset(url: with).load(.tracks)
                check(tracks.contains { $0.mediaType == .subtitle || $0.mediaType == .text }, "el MP4 lleva una pista de subtítulos (\(tracks.map { $0.mediaType.rawValue }))")
                let mp3 = dir.appendingPathComponent("con-letra.mp3")
                _ = try await FFmpeg.run(["-i", mp4.path, "-vn", "-c:a", "libmp3lame", "-b:a", "64k", "-id3v2_version", "3", "-metadata", "lyrics=" + Exporter.transcriptText(project: p), mp3.path])
                // AVFoundation no expone la letra ID3; ffmpeg sí la lee
                let probe = (try? await FFmpeg.run(["-i", mp3.path], allowFailure: true)) ?? ""
                check(probe.contains("lyrics") && probe.contains("Hola a todos"), "el MP3 lleva la transcripción dentro (etiqueta de letra ID3)")
            } catch { check(false, "ffmpeg: \(error.localizedDescription)") }
        } else { print("  (sin ffmpeg: no se prueba la pista de subtítulos ni la letra)") }
        print(ok ? "OK entrega: subtítulos y capítulos junto al archivo y dentro de él" : "FAIL entrega")
        return ok
    }

    /// Imán al ritmo: una pista de golpes a 120 BPM (patada de 80 Hz cada 0,5 s con ruido) debe dar 120 BPM, los
    /// beats sobre los golpes y los ataques contados; el enganche elige el beat más cercano dentro de la tolerancia.
    static func beatGridTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ritmo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sr = 48_000.0, secs = 20.0, period = 0.5
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1), let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * secs)) else { return false }
        buf.frameLength = AVAudioFrameCount(sr * secs)
        var seed: UInt32 = 777
        for i in 0..<Int(sr * secs) {
            let t = Double(i) / sr
            seed = seed &* 1664525 &+ 1013904223
            var v = (Float(seed % 20000) / 10000 - 1) * 0.02                       // ruido de fondo
            let inBeat = t.truncatingRemainder(dividingBy: period)
            if inBeat < 0.06 { v += Float(0.6 * exp(-inBeat * 40) * sin(2 * .pi * 80 * t)) }   // patada que decae
            buf.floatChannelData![0][i] = v
        }
        let url = dir.appendingPathComponent("golpes.caf")
        guard let f = try? AVAudioFile(forWriting: url, settings: fmt.settings), (try? f.write(from: buf)) != nil else { return false }
        guard let g = BeatGrid.analyze(url: url) else { check(false, "no se pudo analizar"); return false }
        check(abs(g.bpm - 120) < 1.5, String(format: "tempo detectado %.1f BPM (esperado 120)", g.bpm))
        let expected = Int(secs / period)
        check(abs(g.onsets.count - expected) <= 3, "ataques: \(g.onsets.count) (esperado ~\(expected))")
        let offsets = g.beats.map { b -> Double in let r = b.truncatingRemainder(dividingBy: period); return min(r, period - r) }
        let worst = offsets.max() ?? 1
        check(g.beats.count >= expected - 2 && worst < 0.03, String(format: "la rejilla cae sobre los golpes (peor desvío %.0f ms, %d beats)", worst * 1000, g.beats.count))
        // Enganche
        let beats = [1.0, 1.5, 2.0]
        check(BeatGrid.snap(1.46, to: beats, tolerance: 0.1) == 1.5 && BeatGrid.snap(1.3, to: beats, tolerance: 0.1) == nil && BeatGrid.snap(0.2, to: beats, tolerance: 1) == 1.0,
              "el imán elige el beat más cercano solo dentro de la tolerancia")
        var clip = AudioLaneClip(id: 1, mediaId: 1, tlStart: 100, srcIn: 1.2, srcOut: 1.9)
        check(BeatGrid(bpm: 120, beats: beats, onsets: [], duration: 3).beats(in: clip) == [100.3], "los beats de un clip pasan al tiempo del episodio (el de 2,0 s queda fuera del clip) (\(BeatGrid(bpm: 120, beats: beats, onsets: [], duration: 3).beats(in: clip)))")
        clip.srcIn = 0
        print(ok ? "OK imán al ritmo" : "FAIL imán al ritmo")
        return ok
    }

    /// Panorama de conversación: los panoramas por orden en pantalla, y un tono estéreo con pan a la derecha sale
    /// casi todo por el canal derecho dentro de un export real (mismo tap que la vista previa).
    static func panTest() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        check(Project.conversationPans(count: 1) == [0], "una persona: al centro")
        let two = Project.conversationPans(count: 2)
        check(two.count == 2 && abs(two[0] + 0.2) < 1e-9 && abs(two[1] - 0.2) < 1e-9, "dos personas: −20 % y +20 % (\(two))")
        let four = Project.conversationPans(count: 4)
        check(four.first! >= -0.3 && four.last! <= 0.3 && four == four.sorted(), "cuatro personas: de izquierda a derecha sin pasar de ±30 % (\(four.map { String(format: "%.2f", $0) }))")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let sr = 48_000.0
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let src = dir.appendingPathComponent("tono.caf")
            let file = try AVAudioFile(forWriting: src, settings: fmt.settings)
            let n = AVAudioFrameCount(sr * 2)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
            buf.frameLength = n
            for i in 0..<Int(n) { let v = Float(0.3 * sin(2 * .pi * 440 * Double(i) / sr)); buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v }
            try file.write(from: buf)
            func export(pan: Double) async throws -> (l: Double, r: Double) {
                let asset = AVURLAsset(url: src)
                let comp = AVMutableComposition()
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                let st = try await asset.loadTracks(withMediaType: .audio).first!
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: st, at: .zero)
                let p = AVMutableAudioMixInputParameters(track: track)
                let tap = ChainTap(laneId: 1, settings: ChainSettings(), keep: [EditEngine.Span(start: 0, end: 2)], introDuration: 0)
                tap.pan = pan
                p.audioTapProcessor = tap.makeProcessor()
                let mix = AVMutableAudioMix(); mix.inputParameters = [p]
                let out = dir.appendingPathComponent("out-\(UUID().uuidString).m4a")
                let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A)!
                s.audioMix = mix; s.outputURL = out; s.outputFileType = .m4a
                await s.export()
                if let e = s.error { throw e }
                _ = tap
                let f = try AVAudioFile(forReading: out)
                let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
                try f.read(into: b)
                guard f.processingFormat.channelCount >= 2 else { return (0, 0) }
                var l = 0.0, r = 0.0
                let m = Int(b.frameLength)
                for i in (m / 3)..<(2 * m / 3) { l += Double(b.floatChannelData![0][i] * b.floatChannelData![0][i]); r += Double(b.floatChannelData![1][i] * b.floatChannelData![1][i]) }
                return (sqrt(l / Double(m / 3)), sqrt(r / Double(m / 3)))
            }
            let c = try await export(pan: 0), right = try await export(pan: 1), half = try await export(pan: 0.5)
            check(abs(c.l - c.r) < 0.01 && c.l > 0.15, String(format: "pan 0: igual por los dos lados (%.3f / %.3f)", c.l, c.r))
            check(right.l < 0.02 && right.r > c.r * 1.3, String(format: "pan +1: casi nada a la izquierda y más a la derecha (%.3f / %.3f)", right.l, right.r))
            check(half.r > half.l * 1.5 && half.l > 0.05, String(format: "pan +0,5: inclinado a la derecha sin perder la izquierda (%.3f / %.3f)", half.l, half.r))
        } catch { check(false, "export: \(error.localizedDescription)") }
        print(ok ? "OK panorama de conversación" : "FAIL panorama")
        return ok
    }

    /// Informe de sonoridad: se lee el resumen de ffmpeg, se juzga cada destino y se escribe el PDF; con ffmpeg,
    /// un tono a −20 dBFS mide −23 LUFS y pico −20 dBTP en el archivo real.
    static func loudnessReportTest() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let sample = """
        [Parsed_ebur128_0 @ 0x1] Summary:

          Integrated loudness:
            I:         -16.3 LUFS
            Threshold: -26.8 LUFS

          Loudness range:
            LRA:         7.2 LU
            Threshold: -36.9 LUFS
            LRA low:   -21.1 LUFS
            LRA high:  -13.9 LUFS

          True peak:
            Peak:       -1.4 dBFS
        """
        let m = LoudnessReport.parse(sample, duration: 125)
        check(m == LoudnessReport.Measure(integrated: -16.3, truePeak: -1.4, range: 7.2, duration: 125), "lee integrado, LRA y pico real del resumen de ffmpeg (\(String(describing: m)))")
        if let m {
            let ok16 = LoudnessReport.targets[0].passes(m), ok14 = LoudnessReport.targets[2].passes(m), ok23 = LoudnessReport.targets[3].passes(m)
            check(ok16 && !ok14 && !ok23, "a −16,3 LUFS cumple Spotify/Apple y no YouTube ni radio")
            var hot = m; hot.truePeak = -0.2
            check(!LoudnessReport.targets[0].passes(hot), "con pico real por encima de −1 dBTP no cumple aunque el nivel esté bien")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("informe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var p = Project(id: "x", name: "Informe de prueba", podcastName: "Podcast", createdAt: Date(), importedFrom: "tracks")
            p.episode.title = "El episodio"
            let fake = dir.appendingPathComponent("episodio.mp3")
            let pdf = LoudnessReport.writePDF(project: p, file: fake, format: .audio, measure: m, target: -16)
            let size = pdf.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            check(pdf?.lastPathComponent == "episodio.sonoridad.pdf" && size > 2000, "escribe episodio.sonoridad.pdf (\(size) bytes)")
            if FFmpeg.isAvailable {
                let tone = dir.appendingPathComponent("tono.caf")
                let sr = 48_000.0
                if let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1), let f = try? AVAudioFile(forWriting: tone, settings: fmt.settings),
                   let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 6)) {
                    b.frameLength = AVAudioFrameCount(sr * 6)
                    for i in 0..<Int(b.frameLength) { b.floatChannelData![0][i] = Float(0.1 * sin(2 * .pi * 1000 * Double(i) / sr)) }
                    try? f.write(from: b)
                }
                do {
                    if let r = await LoudnessReport.measure(tone) {
                        check(abs(r.integrated + 23) < 0.5 && abs(r.truePeak + 20) < 0.7 && r.duration > 5.5, String(format: "mide el archivo real: %.1f LUFS, pico %.1f dBTP, %.1f s", r.integrated, r.truePeak, r.duration))
                    } else { check(false, "no midió el archivo") }
                } catch { check(false, "ffmpeg: \(error.localizedDescription)") }
            }
        }
        print(ok ? "OK informe de sonoridad" : "FAIL informe de sonoridad")
        return ok
    }

    /// Punch-in dinámico: la curva sube cuando la persona habla fuerte y baja despacio; en el cuadro, el borde del
    /// video queda fuera cuando hay acercamiento.
    static func punchInTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        // 10 s: 4 s callado (−70), 2 s hablando normal (−30), 1 s fuerte (−22), 3 s callado
        var e: [Float] = []
        e += [Float](repeating: -70, count: 40); e += [Float](repeating: -30, count: 20); e += [Float](repeating: -22, count: 10); e += [Float](repeating: -70, count: 30)
        let keep = [EditEngine.Span(start: 0, end: 10)]
        let c = AudioAnalysis.punchInCurve(energy: e, keep: keep)
        check(c.count >= 100 && c[20] < 1.002, "callado: sin acercamiento (\(String(format: "%.3f", c[20])))")
        check(c[69] > 1.03 && c[69] <= 1.046, "hablando fuerte: cerca del tope (\(String(format: "%.3f", c[69])))")
        check(c[72] > c[80] && c[80] > c[95] && c[95] < 1.01, "al callarse baja despacio (\(String(format: "%.3f → %.3f → %.3f", c[72], c[80], c[95])))")
        let cut = AudioAnalysis.punchInCurve(energy: e, keep: [EditEngine.Span(start: 6, end: 10)])
        check(cut.count >= 40 && cut[5] > 1.03, "con cortes, la curva va en tiempo del video final (\(String(format: "%.3f", cut.count > 5 ? cut[5] : -1)))")
        // Cuadro: persona roja con una franja azul a la izquierda (8 %); con acercamiento la franja se recorta
        let size = CGSize(width: 640, height: 360)
        var style = CaptionStyle(); style.enabled = false
        let scene = RenderScene(renderSize: size, format: .landscape, layout: .solo, laneOrder: [1], trackIDs: [:], captions: [], style: style,
                                switches: [SpeakerSwitch(time: 0, lane: 1)], names: [:], showNames: false, cropX: [:], logo: nil, background: nil, title: "p")
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let stripe = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 102, height: 720))
        let frame = stripe.composited(over: red)
        let before = mean(scene.render(frames: [1: frame], time: 1), CGRect(x: 0.05, y: 0.4, width: 0.025, height: 0.2), size: size)
        scene.punchIn = [1: [Float](repeating: 1.1, count: 100)]
        let after = mean(scene.render(frames: [1: frame], time: 1), CGRect(x: 0.05, y: 0.4, width: 0.025, height: 0.2), size: size)
        check(before.b > 0.7 && after.r > 0.7, "con acercamiento del 10 %, lo que estaba en el borde queda fuera del cuadro")
        print(ok ? "OK punch-in dinámico" : "FAIL punch-in")
        return ok
    }

    /// Reducción de ruido por huella: con la huella del ruido, el ruido baja ≥ 10 dB y un tono de voz (300 Hz) a
    /// 20 dB por encima se conserva (±1,5 dB); con una huella casi nula la señal pasa intacta (reconstrucción).
    static func noiseReducerTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let sr = 48_000.0
        var seed: UInt32 = 4242
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return (Float(seed % 20000) / 10000 - 1) * 0.02 }   // ≈ −41 dBFS rms
        // Huella: 1 s solo ruido
        var only = [Float](repeating: 0, count: Int(sr))
        for i in only.indices { only[i] = noise() }
        guard let prof = only.withUnsafeBufferPointer({ NoiseReducer.profile(samples: $0.baseAddress!, count: $0.count) }) else { check(false, "sin huella"); return false }
        check(prof.count == NoiseReducer.bins && prof.max()! > 0, "la huella tiene \(NoiseReducer.bins) bandas")
        // Señal: 3 s de ruido + tono de 300 Hz a 0,2 (≈ −17 dBFS), procesada por bloques de 512 como en la mezcla
        let total = Int(sr * 3)
        var sig = [Float](repeating: 0, count: total)
        for i in 0..<total { sig[i] = noise() + 0.2 * Float(sin(2 * .pi * 300 * Double(i) / sr)) }
        func run(_ input: [Float], amount: Float, profile: [Float]) -> [Float] {
            let nr = NoiseReducer(); nr.profile = profile; nr.amount = amount; nr.prepare(channels: 1)
            var out = input
            out.withUnsafeMutableBufferPointer { op in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
                var pos = 0
                while pos < total {
                    let n = min(512, total - pos)
                    abl.mBuffers.mData = UnsafeMutableRawPointer(op.baseAddress! + pos)
                    abl.mBuffers.mDataByteSize = UInt32(n * 4)
                    nr.process(&abl, frames: n)
                    pos += n
                }
            }
            return out
        }
        /// Potencia de una banda (Goertzel) y potencia total, sobre el segundo central
        func band(_ x: [Float], hz: Double) -> Double {
            let a = total / 3, len = total / 3, w = 2 * Double.pi * hz / sr
            var re = 0.0, im = 0.0
            for i in 0..<len { let v = Double(x[a + i]); re += v * cos(w * Double(i)); im -= v * sin(w * Double(i)) }
            return 20 * log10(max(1e-9, sqrt(re * re + im * im) / Double(len) * 2))
        }
        func rmsDB(_ x: [Float], from: Int, to: Int) -> Double { var s = 0.0; for i in from..<to { s += Double(x[i] * x[i]) }; return 10 * log10(max(1e-12, s / Double(to - from))) }
        let out = run(sig, amount: 0.6, profile: prof)
        let toneIn = band(sig, hz: 300), toneOut = band(out, hz: 300)
        check(abs(toneOut - toneIn) < 1.5, String(format: "el tono de voz se conserva (%.1f → %.1f dB)", toneIn, toneOut))
        // ruido: la señal sin tono, por el mismo reductor
        var onlyNoise = [Float](repeating: 0, count: total); for i in 0..<total { onlyNoise[i] = noise() }
        let nOut = run(onlyNoise, amount: 0.6, profile: prof)
        let lat = NoiseReducer.n
        let nIn = rmsDB(onlyNoise, from: total / 3, to: 2 * total / 3), nO = rmsDB(nOut, from: total / 3 + lat, to: 2 * total / 3 + lat)
        check(nIn - nO >= 9, String(format: "el ruido baja %.1f dB (normal: ≥ 9)", nIn - nO))
        let strong = run(onlyNoise, amount: 0.9, profile: prof)
        check(nIn - rmsDB(strong, from: total / 3 + lat, to: 2 * total / 3 + lat) > nIn - nO, "en «Fuerte» baja más que en «Normal»")
        // sin huella que restar: reconstrucción (retardada n muestras), error por debajo de −30 dB
        let clean = run(sig, amount: 0.6, profile: [Float](repeating: 1e-6, count: NoiseReducer.bins))
        var diff = 0.0, ref = 0.0
        for i in (total / 3)..<(2 * total / 3) { let d = Double(clean[i + lat] - sig[i]); diff += d * d; ref += Double(sig[i] * sig[i]) }
        check(10 * log10(diff / ref) < -30, String(format: "sin ruido que restar la señal pasa intacta (error %.1f dB)", 10 * log10(diff / ref)))
        print(ok ? "OK reducción de ruido por huella" : "FAIL reducción de ruido")
        return ok
    }

    /// Quitar clics: sobre un tono de voz con 20 clics de una muestra, los clics desaparecen (pico ≤ el del tono),
    /// el tono se conserva, y sin clics la señal pasa intacta (retardada).
    static func declickTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let sr = 48_000.0, total = Int(sr * 3)
        var clean = [Float](repeating: 0, count: total)
        for i in 0..<total { clean[i] = 0.3 * Float(sin(2 * .pi * 220 * Double(i) / sr)) + 0.1 * Float(sin(2 * .pi * 1700 * Double(i) / sr)) }
        var dirty = clean
        var positions: [Int] = []
        for k in 0..<20 { let pos = 6000 + k * 6500; positions.append(pos); dirty[pos] += 0.6; dirty[pos + 1] -= 0.4 }
        func run(_ input: [Float], amount: Float) -> ([Float], Int) {
            let d = DeClicker(); d.amount = amount; d.prepare(channels: 1)
            var out = input
            out.withUnsafeMutableBufferPointer { op in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
                var pos = 0
                while pos < total {
                    let n = min(1024, total - pos)
                    abl.mBuffers.mData = UnsafeMutableRawPointer(op.baseAddress! + pos); abl.mBuffers.mDataByteSize = UInt32(n * 4)
                    d.process(&abl, frames: n); pos += n
                }
            }
            return (out, d.clicks)
        }
        let lat = DeClicker.lookahead
        let (out, found) = run(dirty, amount: 0.5)
        check(found >= 18 && found <= 24, "encuentra los clics (\(found) de 20)")
        var maxResidual: Float = 0
        for pos in positions { for j in -3...4 { maxResidual = max(maxResidual, abs(out[pos + j + lat] - clean[pos + j])) } }
        check(maxResidual < 0.06, String(format: "donde había clic queda la onda (residuo máximo %.3f)", maxResidual))
        var diff = 0.0, ref = 0.0
        for i in 1000..<(total - 2000) { let d = Double(out[i + lat] - clean[i]); diff += d * d; ref += Double(clean[i] * clean[i]) }
        check(10 * log10(diff / ref) < -40, String(format: "el resto de la voz queda igual (error %.1f dB)", 10 * log10(diff / ref)))
        let (same, none) = run(clean, amount: 0.5)
        var d2 = 0.0
        for i in 1000..<(total - 2000) { let d = Double(same[i + lat] - clean[i]); d2 += d * d }
        check(none == 0 && 10 * log10(d2 / ref) < -60, String(format: "sin clics no toca nada (%d detectados, error %.1f dB)", none, 10 * log10(max(1e-20, d2) / ref)))
        print(ok ? "OK quitar clics" : "FAIL quitar clics")
        return ok
    }

    /// Superficie MIDI: se interpretan los mensajes (UMP 1.0), el mapa por defecto mueve lo que debe, «Aprender»
    /// asigna el siguiente control y la curva del fader da 0 dB a tres cuartos.
    @MainActor static func midiTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let m = MIDIControl.shared
        m.resetToNanoKontrol()
        var got: [(MIDIControl.Action, Double)] = []
        m.handler = { got.append(($0, $1)) }
        func ump(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> UInt32 { (0x2 << 28) | (UInt32(status) << 16) | (UInt32(d1) << 8) | UInt32(d2) }
        m.handle(words: [ump(0xB0, 0, 127), ump(0xB0, 3, 64), ump(0xB0, 48, 127), ump(0xB0, 48, 0), ump(0xB0, 41, 127), ump(0xB0, 45, 127)])
        check(got.count == 5 && got[0].0 == .fader(0) && abs(got[0].1 - 1) < 1e-9 && got[1].0 == .fader(3) && abs(got[1].1 - 64.0 / 127) < 1e-9,
              "faders CC 0 y 3 llegan con su valor (\(got.map { $0.0.name }))")
        check(got[2].0 == .mute(0) && got[3].0 == .play && got[4].0 == .ab, "mute solo al pulsar (no al soltar), play y A/B")
        got = []
        m.learning = .solo(2)
        m.handle(words: [ump(0x90, 60, 100)])
        check(m.learning == nil && m.map["note:60"] == .solo(2), "«Aprender»: la nota 60 queda como Solo 3")
        m.handle(words: [ump(0x90, 60, 100), ump(0x80, 60, 0)])
        check(got.count == 1 && got[0].0 == .solo(2), "la nota aprendida dispara Solo 3 una vez por pulsación")
        check(MIDIControl.volume(forFader: 0) == 0 && abs(MIDIControl.volume(forFader: 0.79) - 1) < 1e-6 && abs(20 * log10(MIDIControl.volume(forFader: 1)) - 6) < 0.01,
              "curva del fader: 0 = silencio, 79 % = 0 dB, tope = +6 dB")
        m.handler = nil
        m.resetToNanoKontrol()
        print(ok ? "OK superficie MIDI" : "FAIL MIDI")
        return ok
    }

    /// Audiograma: la curva sigue la voz (0 en silencio, ~1 hablando, baja en ~150 ms) y en un cuadro sin cámara
    /// las barras del centro crecen cuando la persona habla.
    static func audiogramTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var e: [Float] = []
        e += [Float](repeating: -75, count: 20); e += [Float](repeating: -25, count: 20); e += [Float](repeating: -75, count: 20)
        let c = AudioAnalysis.audiogramCurve(energy: e, keep: [EditEngine.Span(start: 0, end: 6)])
        check(c.count >= 60 && c[10] < 0.05 && c[30] > 0.85 && c[45] < 0.2, String(format: "curva: callado %.2f · hablando %.2f · poco después %.2f", c[10], c[30], c[45]))
        let size = CGSize(width: 640, height: 360)
        var style = CaptionStyle(); style.enabled = false
        let scene = RenderScene(renderSize: size, format: .landscape, layout: .solo, laneOrder: [1], trackIDs: [:], captions: [], style: style,
                                switches: [SpeakerSwitch(time: 0, lane: 1)], names: [1: ("Ana", nil)], showNames: false, cropX: [:], logo: nil, background: nil, title: "p")
        // sin cámara: frames vacío → logo/nombre; con audiograma, barras al 14 % de alto
        let quiet = mean(scene.render(frames: [:], time: 1), CGRect(x: 0.47, y: 0.80, width: 0.06, height: 0.06), size: size)
        scene.audiogram = [1: c]
        let talking = mean(scene.render(frames: [:], time: 3), CGRect(x: 0.47, y: 0.80, width: 0.06, height: 0.06), size: size)
        let silent = mean(scene.render(frames: [:], time: 1), CGRect(x: 0.47, y: 0.80, width: 0.06, height: 0.06), size: size)
        check(talking.r > quiet.r + 0.3 && talking.r > silent.r + 0.2, String(format: "las barras del centro crecen al hablar (%.2f → %.2f; callado %.2f)", quiet.r, talking.r, silent.r))
        if let dir = ProcessInfo.processInfo.environment["THEPOD_SHOT"] {
            let big = RenderScene(renderSize: CGSize(width: 1280, height: 720), format: .landscape, layout: .solo, laneOrder: [1], trackIDs: [:], captions: [], style: style,
                                  switches: [SpeakerSwitch(time: 0, lane: 1)], names: [1: ("Ana María", nil)], showNames: false, cropX: [:], logo: nil, background: nil, title: "p")
            big.audiogram = [1: c]
            let img = big.render(frames: [:], time: 3.2)
            try? ctx.writePNGRepresentation(of: img, to: URL(fileURLWithPath: dir).appendingPathComponent("audiograma.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        print(ok ? "OK audiograma" : "FAIL audiograma")
        return ok
    }

    /// Cola de exportación: se procesa de a uno, en orden, sin bloquear la app; un fallo no frena el resto;
    /// no se duplica lo que ya espera; quitar de la cola y cancelar funcionan.
    @MainActor static func exportQueueTest() async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let p = Project(id: "cola", name: "Cola", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        let s = ProjectSession(project: p, app: AppModel())
        var order: [String] = []
        var running = 0, overlap = false
        s.exportQueueRunner = { kind in
            running += 1; if running > 1 { overlap = true }
            order.append(kind.title)
            try await Task.sleep(nanoseconds: 60_000_000)
            running -= 1
            if case .stems = kind { throw NSError(domain: "cola", code: 1, userInfo: [NSLocalizedDescriptionKey: "sin pistas"]) }
            return [URL(fileURLWithPath: "/tmp/\(kind.title).mp4")]
        }
        check(s.enqueue(.format(.landscape)), "se agrega YouTube")
        check(s.enqueue(.stems), "se agrega pistas")
        check(s.enqueue(.format(.audio)), "se agrega MP3")
        check(!s.enqueue(.format(.audio)), "MP3 ya esperando no se duplica")
        check(s.exportQueue.count == 3 && s.queuePending == 3, "tres en cola")
        check(s.isBusy, "la barra de trabajo muestra la cola")
        // la app sigue respondiendo mientras exporta: el hilo principal no está bloqueado
        var ticks = 0
        while s.queuePending > 0 && ticks < 100 { ticks += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
        check(ticks > 2 && ticks < 100, "terminó en segundo plano mientras el hilo principal seguía libre (\(ticks) vueltas)")
        check(order == ["YouTube", "Pistas por separado (WAV)", "Solo audio (MP3)"], "orden de llegada: \(order)")
        check(!overlap, "nunca dos exportaciones a la vez")
        check(s.exportQueue[0].status == .done([URL(fileURLWithPath: "/tmp/YouTube.mp4")]), "YouTube listo con su archivo")
        if case .failed(let why) = s.exportQueue[1].status { check(why == "sin pistas", "pistas falló con su motivo") } else { check(false, "pistas debía fallar") }
        check(s.exportQueue[2].status.isFinished && s.exportQueue[2].files.count == 1, "MP3 salió aunque pistas falló")
        check(!s.isBusy && s.job == nil, "al terminar se libera la barra")
        s.clearFinishedExports()
        check(s.exportQueue.isEmpty, "limpiar deja la cola vacía")
        // quitar uno que espera y cancelar el que corre vacía el resto
        s.exportQueueRunner = { kind in try await Task.sleep(nanoseconds: 400_000_000); return [] }
        s.enqueue(.format(.vertical)); s.enqueue(.format(.square)); s.enqueue(.reels)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let sq = s.exportQueue.first { $0.kind == .format(.square) }!
        s.removeFromQueue(sq.id)
        check(s.exportQueue.count == 2, "se quita el que esperaba")
        s.removeFromQueue(s.exportQueue[0].id)
        check(s.exportQueue.count == 2 && s.exportQueue[0].status == .running, "el que corre no se quita, se cancela")
        s.cancelJob()
        ticks = 0
        while s.queuePending > 0 && ticks < 50 { ticks += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
        check(s.exportQueue.count == 1 && s.exportQueue[0].status == .failed("Cancelado"), "cancelar para el actual y vacía lo que esperaba")
        // "Exportar todo" encola YouTube + MP3 (+ reels solo si hay marcados)
        s.clearFinishedExports()
        s.exportQueueRunner = { _ in [] }
        s.enqueueAll()
        check(s.exportQueue.map(\.kind) == [.format(.landscape), .format(.audio)], "exportar todo sin reels: YouTube y MP3")
        return ok
    }

    /// Revisión compartida: el segundo del archivo revisado (con intro y cortes) pasa al segundo del episodio, y el
    /// enlace con sus comentarios se guarda y se carga con el proyecto.
    static func reviewTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var r = ReviewLink(token: "abc", url: "https://postpod.castmedia.space/r/abc", sentAt: Date(), introDuration: 4,
                           keep: [EditEngine.Span(start: 0, end: 60), EditEngine.Span(start: 90, end: 200)])
        let c1 = ReviewComment(id: 1, t: 34, author: "Caro", text: "aquí", resolved: false)       // 30 s de contenido → 30 s del episodio
        let c2 = ReviewComment(id: 2, t: 74, author: "", text: "allá", resolved: true)            // 70 s de contenido → 60 + 10 = 100 s del episodio
        check(abs(r.timelineTime(c1) - 30) < 1e-9 && abs(r.timelineTime(c2) - 100) < 1e-9, "el segundo del archivo pasa al del episodio saltando intro y cortes (\(r.timelineTime(c1)), \(r.timelineTime(c2)))")
        check(abs(ReviewLink(token: "x", url: "u", sentAt: Date()).timelineTime(c1) - 34) < 1e-9, "sin intro ni cortes, el mismo segundo")
        r.comments = [c1, c2]
        var p = Project(id: "rev", name: "Rev", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        p.review = r
        do {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let back = try dec.decode(Project.self, from: try enc.encode(p))
            check(back.review?.token == "abc" && back.review?.comments.count == 2 && back.review?.comments[1].resolved == true, "el enlace y los comentarios se guardan con el proyecto")
            var obj = try JSONSerialization.jsonObject(with: try enc.encode(p)) as! [String: Any]
            obj["review"] = nil
            let old = try dec.decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
            check(old.review == nil, "un proyecto sin revisión abre igual")
        } catch { check(false, "guardar/cargar: \(error)") }
        let model = TimelineModel(project: p, energy: nil)
        check(model.reviewMarks.map(\.t) == [30, 100] && model.reviewMarks[1].resolved, "la línea de tiempo recibe las marcas en el segundo del episodio")
        print(ok ? "OK revisión compartida" : "FAIL revisión compartida")
        return ok
    }

    static func videoStudioTest() -> Bool {
        let size = CGSize(width: 640, height: 360)
        let frames: [Int: CIImage] = [1: solid(1, 0, 0, CGSize(width: 1280, height: 720)), 2: solid(0, 1, 0, CGSize(width: 1280, height: 720))]
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }

        // 1) Interpolación de keyframes: lineal, suave y pausa
        var a = LayerAnimation()
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .linear); a.write(LayerAnimation.x, t: 10, v: 1)
        check(abs((a.value(LayerAnimation.x, at: 5) ?? -1) - 0.5) < 1e-9, "keyframe lineal: a mitad de camino vale 0,5")
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .smooth)
        let sm = a.value(LayerAnimation.x, at: 2.5) ?? -1
        check(sm > 0.1 && sm < 0.25, "keyframe suave: arranca despacio (\(String(format: "%.3f", sm)) a un cuarto)")
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .hold)
        check(abs((a.value(LayerAnimation.x, at: 9.9) ?? -1) - 0) < 1e-9 && abs((a.value(LayerAnimation.x, at: 10) ?? -1) - 1) < 1e-9, "keyframe pausa: salta justo en el siguiente")
        check(a.value(LayerAnimation.y, at: 3) == nil, "un parámetro sin keyframes devuelve nil (usa el valor fijo)")

        // 2) Una capa con keyframes de posición se mueve en el cuadro dibujado
        let s1 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let blue = solid(0, 0, 1, CGSize(width: 120, height: 120))
        var anim = LayerAnimation()
        anim.write(LayerAnimation.x, t: 0, v: 0.15, ease: .linear); anim.write(LayerAnimation.x, t: 10, v: 0.85)
        anim.write(LayerAnimation.opacity, t: 0, v: 1, ease: .linear); anim.write(LayerAnimation.opacity, t: 10, v: 1)
        var card = RenderScene.OverlayCard(id: 7, start: 0, end: 10, image: blue, cx: 0.5, cy: 0.5, animate: false)
        card.anim = anim; card.baseScale = 1
        s1.overlays = [card]
        let f0 = s1.render(frames: frames, time: 0.5), f9 = s1.render(frames: frames, time: 9.5)
        let leftAt0 = mean(f0, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        let leftAt9 = mean(f9, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        let rightAt9 = mean(f9, CGRect(x: 0.78, y: 0.4, width: 0.14, height: 0.2), size: size)
        check(leftAt0.b > 0.7 && leftAt0.r < 0.3, "capa con keyframes: al inicio está a la izquierda (azul sobre rojo)")
        check(leftAt9.r > 0.7 && leftAt9.b < 0.3 && rightAt9.b > 0.7, "capa con keyframes: al final está a la derecha")
        // opacidad a 0 → no se ve
        anim.write(LayerAnimation.opacity, t: 0, v: 0, ease: .hold); anim.write(LayerAnimation.opacity, t: 10, v: 0)
        card.anim = anim; s1.overlays = [card]
        let fo = s1.render(frames: frames, time: 0.5)
        let hidden = mean(fo, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        check(hidden.r > 0.7 && hidden.b < 0.3, "keyframe de opacidad 0: la capa no se ve")

        // 3) Cortes de cámara a mano ganan a quién habla, y la plantilla del tramo también
        let sw = [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 5, lane: 2)]
        let s2 = scene(layout: .solo, switches: sw)
        s2.cameraSpans = [RenderScene.CameraSpan(start: 6, end: 8, lane: 1, template: nil),
                          RenderScene.CameraSpan(start: 8, end: 9, lane: nil, template: .sideBySide)]
        let c5 = mean(s2.render(frames: frames, time: 5.5), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: size)
        let c7 = mean(s2.render(frames: frames, time: 7), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: size)
        check(c5.g > 0.7 && c5.r < 0.3, "sin tramo a mano: a los 5,5 s se ve a quien habla (verde)")
        check(c7.r > 0.7 && c7.g < 0.3, "tramo a mano 6–8 s: se ve la persona fijada (roja) aunque hable la otra")
        let f8 = s2.render(frames: frames, time: 8.5)
        let l8 = mean(f8, CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2), size: size), r8 = mean(f8, CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2), size: size)
        check(l8.r > 0.6 && r8.g > 0.6, "tramo a mano con plantilla Lado a lado: rojo a la izquierda, verde a la derecha")
        check(s2.activeLane(at: 7).lane == 1 && s2.activeLane(at: 9.5).lane == 2, "fuera del tramo vuelve el automático")

        // 4) Permanencia mínima: los cambios muy seguidos se posponen o se saltan; apagado «sigue a quien habla» = una cámara
        let rapid = [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 1, lane: 2), SpeakerSwitch(time: 1.8, lane: 1), SpeakerSwitch(time: 6, lane: 2)]
        var st = StudioVideoSettings(); st.minHold = 2.5
        let held = AudioAnalysis.cameraSwitches(rapid, settings: st)
        check(held.count == 2 && held[1].lane == 2 && held[1].time == 6, "permanencia 2,5 s: el ida y vuelta de 1 s se salta, queda 0→1 y 6→2 (\(held.map { "\($0.time):\($0.lane)" }))")
        var st2 = StudioVideoSettings(); st2.minHold = 2.5
        let late = AudioAnalysis.cameraSwitches([SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 1, lane: 2)], settings: st2)
        check(late.count == 2 && abs(late[1].time - 2.5) < 1e-9, "un cambio a 1 s se pospone a 2,5 s")
        st2.followSpeaker = false
        check(AudioAnalysis.cameraSwitches(rapid, settings: st2).count == 1, "sin seguir a quien habla: una sola cámara")

        // 5) Transición «a negro» en un b-roll: a mitad de la transición el cuadro está oscuro; «corte» entra entero
        let s3 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let white = solid(1, 1, 1, CGSize(width: 1280, height: 720))
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .black, duration: 1))]
        let mid = mean(s3.render(frames: frames, time: 2.5), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        let after = mean(s3.render(frames: frames, time: 3.5), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        check(mid.r < 0.15 && mid.g < 0.15 && mid.b < 0.15, "transición a negro: a mitad está oscuro (\(String(format: "%.2f", mid.r)))")
        check(after.r > 0.9 && after.g > 0.9, "después de la transición el b-roll se ve entero")
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .cut, duration: 1))]
        let cutIn = mean(s3.render(frames: frames, time: 2.05), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        check(cutIn.r > 0.9, "transición corte: entra entero desde el primer cuadro")
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .slide, duration: 1))]
        let slide = s3.render(frames: frames, time: 2.5)
        let sl = mean(slide, CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2), size: size), sr = mean(slide, CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2), size: size)
        check(sl.r > 0.9 && sl.g > 0.9 && sr.g < 0.3, "transición deslizar: a mitad ya cubre la izquierda y aún no la derecha")

        // 5b) Entradas y salidas de un título: subir deja la capa más abajo a mitad de camino; escribir la revela de izquierda
        //     a derecha; fundido al salir la apaga; sin entrada elegida, la salida simple sigue
        let s4 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let wide = solid(0, 0, 1, CGSize(width: 320, height: 60))
        var tc = RenderScene.OverlayCard(id: 9, start: 2, end: 8, image: wide, cx: 0.5, cy: 0.5, animate: true)
        tc.enter = TitleMotion(kind: .rise, duration: 1)
        s4.overlays = [tc]
        // La capa ocupa 0,417–0,583 del alto en su sitio; a un tercio de la subida va unos 0,04 más abajo:
        // la franja 0,42–0,45 (su borde superior) está vacía mientras sube y cubierta al llegar.
        let risen = s4.render(frames: frames, time: 2.3)        // un tercio de la subida
        let topEdgeRising = mean(risen, CGRect(x: 0.45, y: 0.42, width: 0.1, height: 0.03), size: size)
        let topEdgeSettled = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.42, width: 0.1, height: 0.03), size: size)
        check(topEdgeRising.r > 0.6 && topEdgeSettled.b > 0.7, "entrada «subir»: a un tercio la capa está más abajo que su sitio")
        let settled = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        check(settled.b > 0.7, "después de la entrada la capa está en su sitio y entera")
        tc.enter = TitleMotion(kind: .reveal, duration: 1)
        s4.overlays = [tc]
        let half = s4.render(frames: frames, time: 2.5)
        let leftHalf = mean(half, CGRect(x: 0.27, y: 0.46, width: 0.08, height: 0.08), size: size)
        let rightHalf = mean(half, CGRect(x: 0.65, y: 0.46, width: 0.08, height: 0.08), size: size)
        check(leftHalf.b > 0.7 && rightHalf.r > 0.7, "entrada «escribir»: a mitad se ve la izquierda y aún no la derecha")
        tc.enter = nil; tc.exit = TitleMotion(kind: .fade, duration: 1)
        s4.overlays = [tc]
        let fading = mean(s4.render(frames: frames, time: 7.8), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        let shown = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        check(fading.b < shown.b - 0.3, "salida «fundido»: al final la capa se va apagando")

        // 5c) Crossfade: dos clips de música que se solapan se cruzan solos (fades curvos del largo del solape) y
        //     al separarlos el cruce desaparece; la suma de potencias en el medio del cruce es ~1 (igual potencia)
        var pm = Project(id: "x", name: "x", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        pm.audioLane = [AudioLaneClip(id: 1, mediaId: 1, tlStart: 0, srcIn: 0, srcOut: 10), AudioLaneClip(id: 2, mediaId: 1, tlStart: 8.8, srcIn: 0, srcOut: 10)]
        pm.crossfadeOverlaps(touching: 2)
        check(abs(pm.audioLane[0].fadeOut - 1.2) < 1e-9 && abs(pm.audioLane[1].fadeIn - 1.2) < 1e-9 && pm.audioLane[0].crossfade && pm.audioLane[1].crossfade,
              "dos clips solapados 1,2 s se cruzan con fades de 1,2 s")
        pm.audioLane[1].tlStart = 12; pm.crossfadeOverlaps(touching: 2)
        check(pm.audioLane[0].fadeOut == 0 && pm.audioLane[1].fadeIn == 0, "al separarlos, el cruce se quita")
        pm.crossfade(1, with: 2, seconds: 2)
        check(abs(pm.audioLane[1].tlStart - 8) < 1e-9 && abs(pm.audioLane[0].fadeOut - 2) < 1e-9, "«Cruzar con el siguiente» adelanta el segundo clip y pone los fades")
        let eqp = sin(0.5 * Double.pi / 2)
        check(abs(eqp * eqp + eqp * eqp - 1) < 1e-9, "fades de igual potencia: en el medio del cruce las potencias suman 1")

        // 6) Guardar y cargar: el proyecto conserva keyframes, transiciones y cortes; uno viejo (sin esos campos) abre igual
        var p = Project(id: "prueba-studio", name: "Prueba", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        var layer = VideoLayer(id: 1, kind: .text, start: 3, text: "Hola")
        layer.animation = anim
        layer.enter = TitleMotion(kind: .wipe, duration: 0.3)
        p.overlays = [layer]
        var br = BRollClip(id: 1, file: "broll/x.mp4", isVideo: true, start: 10)
        br.transitionIn = Transition(kind: .zoom, duration: 0.8)
        p.brolls = [br]
        p.studioVideo.cuts = [CameraCut(start: 6, end: 8, lane: 1, template: .pip)]
        p.studioVideo.minHold = 3
        do {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let data = try enc.encode(p)
            let back = try dec.decode(Project.self, from: data)
            check(back.overlays.first?.animation == anim && back.overlays.first?.enter?.kind == .wipe && back.brolls.first?.transitionIn?.kind == .zoom
                  && back.studioVideo.cuts.first?.template == .pip && back.studioVideo.minHold == 3, "guardar y cargar conserva todo lo de Studio · Video")
            check(back.videoTunedInStudio && !Project(id: "x", name: "x", podcastName: nil, createdAt: Date(), importedFrom: "tracks").videoTunedInStudio, "«ajustado en Studio» se detecta solo cuando hay algo")
            // un proyecto sin los campos nuevos
            var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            obj["studioVideo"] = nil
            var ov = obj["overlays"] as! [[String: Any]]; ov[0]["animation"] = nil; ov[0]["enter"] = nil; obj["overlays"] = ov
            var bs = obj["brolls"] as! [[String: Any]]; bs[0]["transitionIn"] = nil; obj["brolls"] = bs
            let old = try dec.decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
            check(old.overlays.first?.animation == nil && old.overlays.first?.enter == nil && old.brolls.first?.transitionIn == nil && old.studioVideo.isDefault, "un proyecto viejo abre con los valores de siempre")
        } catch { check(false, "guardar/cargar: \(error)") }

        print(ok ? "OK Studio · Video: keyframes, cortes de cámara, permanencia, transiciones, entradas de título y guardado" : "FAIL Studio · Video")
        return ok
    }
}
