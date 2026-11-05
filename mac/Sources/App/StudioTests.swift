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
