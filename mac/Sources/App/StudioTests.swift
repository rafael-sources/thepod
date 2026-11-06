import AVFoundation
import AppKit
import CoreImage

/// Studio · Video tests. Run without video files: the scene is built from color images and
/// drawn with the same `RenderScene` the export uses, so what's checked is what comes out.
///
/// `--video-studio-test`: keyframes, transitions, camera cuts, minimum hold, save/load.
/// `--studio-tests`: all Studio tests in a row (audio and video).
enum StudioTests {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Mean color (r, g, b) of a box in the drawn frame (fractions of the frame, from the top).
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

    /// A two-person scene (1 = red, 2 = green) without names, subtitles or logo.
    private static func scene(layout: LayoutTemplate, switches: [SpeakerSwitch]) -> RenderScene {
        var style = CaptionStyle(); style.enabled = false
        return RenderScene(renderSize: CGSize(width: 640, height: 360), format: .landscape, layout: layout, laneOrder: [1, 2],
                           trackIDs: [:], captions: [], style: style, switches: switches,
                           names: [:], showNames: false, cropX: [:], logo: nil, background: nil, title: "prueba")
    }

    /// Even voices by measurement: a tone at −20 dBFS measures −23 LUFS (BS.1770); two files 10 dB apart
    /// get ±5 dB gains; silence doesn't count (gate); gains are clamped to ±12 dB.
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
            check(false, "couldn't write the tones"); return false
        }
        let la = LoudnessMatch.integratedLUFS(url: a) ?? -999, lb = LoudnessMatch.integratedLUFS(url: b) ?? -999, lc = LoudnessMatch.integratedLUFS(url: c) ?? -999
        check(abs(la + 23) < 0.3, String(format: "1 kHz sine at −20 dBFS measures %.2f LUFS (expected −23.0)", la))
        check(abs(lb + 33) < 0.3, String(format: "at −30 dBFS measures %.2f LUFS", lb))
        check(abs(lc - la) < 0.3, String(format: "8 s of silence afterwards don't change the measurement (%.2f): the gate leaves them out", lc))
        let g = LoudnessMatch.gains(for: [(1, la), (2, lb)])
        check(g.count == 2 && abs(g[0].gainDB + 5) < 0.15 && abs(g[1].gainDB - 5) < 0.15, "two voices 10 dB apart: −5 dB and +5 dB towards the average (\(g.map(\.gainDB)))")
        let far = LoudnessMatch.gains(for: [(1, -10), (2, -50)])
        check(far[1].gainDB == 12 && far[0].gainDB == -12, "gains are clamped to ±12 dB")
        print(ok ? "OK even voices by measurement" : "FAIL even voices")
        return ok
    }

    /// Room tone: picks the quietest second that isn't digital silence, writes a seamless loop,
    /// computes the dead gaps and smooths the joins.
    static func roomToneTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        // 1) Energy: 3 s of voice (−20), 2 s of ambience (−55), 2 s of digital silence (−120), 1 s of unstable ambience
        var e: [Float] = []
        e += [Float](repeating: -20, count: 30)
        e += [Float](repeating: -55, count: 20)
        e += [Float](repeating: -120, count: 20)
        e += (0..<10).map { Float(-50 - ($0 % 2) * 9) }
        let q = RoomTone.quietestWindow(energy: e)
        check(q != nil && q!.start >= 3.0 && q!.start <= 4.0 && abs(q!.db + 55) < 0.5, "picks the ambience (−55 dB), not the voice, the digital silence or the unstable span (\(q.map { "\($0.start) s" } ?? "nil"))")
        check(RoomTone.quietestWindow(energy: [Float](repeating: -120, count: 50)) == nil, "a digitally silent track has no room tone")
        check(RoomTone.quietestWindow(energy: [Float](repeating: -25, count: 50)) == nil, "a track that always speaks doesn't either")
        // 2) Loop: from 1 s of noise comes a 4 s loop with the same level and no jumps at the seams
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
                check(abs(Double(f.length) / sr - RoomTone.loopSeconds) < 0.01, "the loop lasts \(RoomTone.loopSeconds) s")
                let lufsSrc = LoudnessMatch.integratedLUFS(url: url) ?? -999
                check(lufsSrc > -70 && lufsSrc < -30, String(format: "the loop keeps an ambience level (%.1f LUFS)", lufsSrc))
                // no audible seam: the power in 20 ms around each seam is the same as in the middle (±1.5 dB)
                let n = AVAudioFrameCount(f.length)
                if let all = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n), (try? f.read(into: all)) != nil {
                    func rms(_ from: Int, _ len: Int) -> Double {
                        var sum = 0.0; for i in from..<(from + len) { let v = Double(all.floatChannelData![0][i]); sum += v * v }; return sqrt(sum / Double(len))
                    }
                    let w = Int(0.02 * sr)
                    let seam = Int(sr) - Int(0.05 * sr) + Int(0.025 * sr) - w / 2      // center of the first crossing
                    let mid = Int(0.5 * sr)
                    let ratio = 20 * log10(rms(seam, w) / max(1e-9, rms(mid, w)))
                    check(abs(ratio) < 1.5, String(format: "the seam keeps the power (%.2f dB relative to the middle)", ratio))
                }
            } else { check(false, "couldn't write the loop") }
        }
        // 3) Dead gaps: before and after the person's span, and under a beep; those < 150 ms are not
        let dead = RoomTone.deadSpans(laneSpan: (12, 100), content: (4, 130), bleeps: [(50, 50.6), (70, 70.05)])
        check(dead.count == 3 && dead[0] == (4, 12) && dead[1] == (50, 50.6) && dead[2] == (100, 130), "gaps: before (4–12), beep (50–50.6) and after (100–130); the 50 ms beep doesn't count (\(dead))")
        check(RoomTone.deadSpans(laneSpan: (4.05, 129.9), content: (4, 130), bleeps: []).isEmpty, "no gaps if the person covers almost everything")
        // 4) Cut join: zero right at the join, full at 6 ms, nothing touched further away
        check(RoomTone.joinDip(10, joins: [10]) == 0 && abs(RoomTone.joinDip(10.003, joins: [10]) - 0.5) < 1e-6 && RoomTone.joinDip(10.006, joins: [10]) >= 0.999 && RoomTone.joinDip(12, joins: [10]) == 1,
              "la unión baja a cero y vuelve en 6 ms")
        print(ok ? "OK room tone" : "FAIL room tone")
        return ok
    }

    /// Delivery: .srt/.vtt subtitles and .chapters.json chapters next to the export; subtitles inside the MP4 and
    /// transcript inside the MP3 (with ffmpeg).
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
        check(v.hasPrefix("WEBVTT\n\n1\n00:00:00.200 --> "), "the VTT starts with the header and the first timestamp uses a dot (\(v.prefix(30).replacingOccurrences(of: "\n", with: "⏎")))")
        check(v.contains("<v Ana>") && v.contains("<v Beto>"), "the VTT says who speaks on each line")
        let srt = Exporter.srt(project: p)
        check(srt.contains("00:00:00,200 -->") && !srt.contains("<v "), "the SRT uses a comma in timestamps and has no voice tags")
        let chapters = [(time: 0.0, title: "Inicio"), (time: 61.5, title: "El tema"), (time: 125.0, title: "Cierre")]
        let json = Exporter.chaptersJSON(chapters) ?? ""
        check(json.contains("\"version\" : \"1.2.0\"") && json.contains("\"startTime\" : 61.5") && json.contains("\"title\" : \"El tema\""), "the chapters JSON follows Podcasting 2.0")
        check(Exporter.chaptersJSON([]) == nil, "no chapters, no JSON")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("entrega-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("episodio.mp4")
        let written = Exporter.writeSidecars(project: p, next: fake, chapters: chapters).map(\.lastPathComponent).sorted()
        check(written == ["episodio.chapters.json", "episodio.srt", "episodio.vtt"], ".srt, .vtt and .chapters.json are written next to the export (\(written))")
        // With ffmpeg: a 5 s MP4 with embedded subtitles and an MP3 with the transcript
        if FFmpeg.isAvailable {
            let mp4 = dir.appendingPathComponent("base.mp4")
            do {
                _ = try await FFmpeg.run(["-f", "lavfi", "-i", "color=c=black:s=320x180:d=5", "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                                          "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", mp4.path])
                let srtURL = dir.appendingPathComponent("s.srt"); try Exporter.srt(project: p).write(to: srtURL, atomically: true, encoding: .utf8)
                let with = dir.appendingPathComponent("con-subs.mp4")
                _ = try await FFmpeg.run(["-i", mp4.path, "-i", srtURL.path, "-map", "0", "-map", "1", "-c:v", "copy", "-c:a", "copy", "-c:s", "mov_text", "-metadata:s:s:0", "language=spa", with.path])
                let tracks = try await AVURLAsset(url: with).load(.tracks)
                check(tracks.contains { $0.mediaType == .subtitle || $0.mediaType == .text }, "the MP4 carries a subtitle track (\(tracks.map { $0.mediaType.rawValue }))")
                let mp3 = dir.appendingPathComponent("con-letra.mp3")
                _ = try await FFmpeg.run(["-i", mp4.path, "-vn", "-c:a", "libmp3lame", "-b:a", "64k", "-id3v2_version", "3", "-metadata", "lyrics=" + Exporter.transcriptText(project: p), mp3.path])
                // AVFoundation doesn't expose the ID3 lyrics; ffmpeg does read them
                let probe = (try? await FFmpeg.run(["-i", mp3.path], allowFailure: true)) ?? ""
                check(probe.contains("lyrics") && probe.contains("Hola a todos"), "the MP3 carries the transcript inside (ID3 lyrics tag)")
            } catch { check(false, "ffmpeg: \(error.localizedDescription)") }
        } else { print("  (no ffmpeg: the subtitle track and lyrics aren't tested)") }
        print(ok ? "OK delivery: subtitles and chapters next to the file and inside it" : "FAIL delivery")
        return ok
    }

    /// Beat snap: a hit track at 120 BPM (80 Hz kick every 0.5 s with noise) must give 120 BPM, the
    /// beats on the hits and the onsets counted; snapping picks the nearest beat within tolerance.
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
            var v = (Float(seed % 20000) / 10000 - 1) * 0.02                       // background noise
            let inBeat = t.truncatingRemainder(dividingBy: period)
            if inBeat < 0.06 { v += Float(0.6 * exp(-inBeat * 40) * sin(2 * .pi * 80 * t)) }   // decaying kick
            buf.floatChannelData![0][i] = v
        }
        let url = dir.appendingPathComponent("golpes.caf")
        guard let f = try? AVAudioFile(forWriting: url, settings: fmt.settings), (try? f.write(from: buf)) != nil else { return false }
        guard let g = BeatGrid.analyze(url: url) else { check(false, "couldn't analyze"); return false }
        check(abs(g.bpm - 120) < 1.5, String(format: "detected tempo %.1f BPM (expected 120)", g.bpm))
        let expected = Int(secs / period)
        check(abs(g.onsets.count - expected) <= 3, "onsets: \(g.onsets.count) (expected ~\(expected))")
        let offsets = g.beats.map { b -> Double in let r = b.truncatingRemainder(dividingBy: period); return min(r, period - r) }
        let worst = offsets.max() ?? 1
        check(g.beats.count >= expected - 2 && worst < 0.03, String(format: "the grid lands on the hits (worst deviation %.0f ms, %d beats)", worst * 1000, g.beats.count))
        // Snapping
        let beats = [1.0, 1.5, 2.0]
        check(BeatGrid.snap(1.46, to: beats, tolerance: 0.1) == 1.5 && BeatGrid.snap(1.3, to: beats, tolerance: 0.1) == nil && BeatGrid.snap(0.2, to: beats, tolerance: 1) == 1.0,
              "el imán elige el beat más cercano solo dentro de la tolerancia")
        var clip = AudioLaneClip(id: 1, mediaId: 1, tlStart: 100, srcIn: 1.2, srcOut: 1.9)
        check(BeatGrid(bpm: 120, beats: beats, onsets: [], duration: 3).beats(in: clip) == [100.3], "a clip's beats map to episode time (the one at 2.0 s falls outside the clip) (\(BeatGrid(bpm: 120, beats: beats, onsets: [], duration: 3).beats(in: clip)))")
        clip.srcIn = 0
        print(ok ? "OK beat snap" : "FAIL beat snap")
        return ok
    }

    /// Conversation panning: pans by on-screen order, and a stereo tone panned right comes out
    /// almost entirely on the right channel inside a real export (same tap as the preview).
    static func panTest() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        check(Project.conversationPans(count: 1) == [0], "one person: centered")
        let two = Project.conversationPans(count: 2)
        check(two.count == 2 && abs(two[0] + 0.2) < 1e-9 && abs(two[1] - 0.2) < 1e-9, "two people: −20 % and +20 % (\(two))")
        let four = Project.conversationPans(count: 4)
        check(four.first! >= -0.3 && four.last! <= 0.3 && four == four.sorted(), "four people: left to right without exceeding ±30 % (\(four.map { String(format: "%.2f", $0) }))")
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
            check(abs(c.l - c.r) < 0.01 && c.l > 0.15, String(format: "pan 0: equal on both sides (%.3f / %.3f)", c.l, c.r))
            check(right.l < 0.02 && right.r > c.r * 1.3, String(format: "pan +1: almost nothing on the left and more on the right (%.3f / %.3f)", right.l, right.r))
            check(half.r > half.l * 1.5 && half.l > 0.05, String(format: "pan +0.5: leaning right without losing the left (%.3f / %.3f)", half.l, half.r))
        } catch { check(false, "export: \(error.localizedDescription)") }
        print(ok ? "OK conversation panning" : "FAIL panning")
        return ok
    }

    /// Loudness report: ffmpeg's summary is read, each destination is judged and the PDF is written; with ffmpeg,
    /// a tone at −20 dBFS measures −23 LUFS and −20 dBTP peak in the real file.
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
        check(m == LoudnessReport.Measure(integrated: -16.3, truePeak: -1.4, range: 7.2, duration: 125), "reads integrated, LRA and true peak from ffmpeg's summary (\(String(describing: m)))")
        if let m {
            let ok16 = LoudnessReport.targets[0].passes(m), ok14 = LoudnessReport.targets[2].passes(m), ok23 = LoudnessReport.targets[3].passes(m)
            check(ok16 && !ok14 && !ok23, "at −16.3 LUFS meets Spotify/Apple but not YouTube or radio")
            var hot = m; hot.truePeak = -0.2
            check(!LoudnessReport.targets[0].passes(hot), "with true peak above −1 dBTP it fails even if the level is fine")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("informe-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var p = Project(id: "x", name: "Informe de prueba", podcastName: "Podcast", createdAt: Date(), importedFrom: "tracks")
            p.episode.title = "El episodio"
            let fake = dir.appendingPathComponent("episodio.mp3")
            let pdf = LoudnessReport.writePDF(project: p, file: fake, format: .audio, measure: m, target: -16)
            let size = pdf.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            check(pdf?.lastPathComponent == "episodio.sonoridad.pdf" && size > 2000, "writes episodio.sonoridad.pdf (\(size) bytes)")
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
                        check(abs(r.integrated + 23) < 0.5 && abs(r.truePeak + 20) < 0.7 && r.duration > 5.5, String(format: "measures the real file: %.1f LUFS, peak %.1f dBTP, %.1f s", r.integrated, r.truePeak, r.duration))
                    } else { check(false, "didn't measure the file") }
                } catch { check(false, "ffmpeg: \(error.localizedDescription)") }
            }
        }
        print(ok ? "OK loudness report" : "FAIL loudness report")
        return ok
    }

    /// Dynamic punch-in: the curve rises when the person speaks loudly and falls slowly; in the frame, the video's
    /// edge stays outside when zoomed in.
    static func punchInTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        // 10 s: 4 s quiet (−70), 2 s normal speech (−30), 1 s loud (−22), 3 s quiet
        var e: [Float] = []
        e += [Float](repeating: -70, count: 40); e += [Float](repeating: -30, count: 20); e += [Float](repeating: -22, count: 10); e += [Float](repeating: -70, count: 30)
        let keep = [EditEngine.Span(start: 0, end: 10)]
        let c = AudioAnalysis.punchInCurve(energy: e, keep: keep)
        check(c.count >= 100 && c[20] < 1.002, "quiet: no zoom (\(String(format: "%.3f", c[20])))")
        check(c[69] > 1.03 && c[69] <= 1.046, "speaking loudly: near the max (\(String(format: "%.3f", c[69])))")
        check(c[72] > c[80] && c[80] > c[95] && c[95] < 1.01, "on going quiet it drops slowly (\(String(format: "%.3f → %.3f → %.3f", c[72], c[80], c[95])))")
        let cut = AudioAnalysis.punchInCurve(energy: e, keep: [EditEngine.Span(start: 6, end: 10)])
        check(cut.count >= 40 && cut[5] > 1.03, "with cuts, the curve is in final video time (\(String(format: "%.3f", cut.count > 5 ? cut[5] : -1)))")
        // Frame: red person with a blue stripe on the left (8 %); with zoom the stripe is cropped
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
        check(before.b > 0.7 && after.r > 0.7, "with a 10 % zoom, what was at the edge falls outside the frame")
        print(ok ? "OK dynamic punch-in" : "FAIL punch-in")
        return ok
    }

    /// Noise-print reduction: with the noise print, noise drops ≥ 10 dB and a voice tone (300 Hz)
    /// 20 dB above is kept (±1.5 dB); with an almost-zero print the signal passes intact (reconstruction).
    static func noiseReducerTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let sr = 48_000.0
        var seed: UInt32 = 4242
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return (Float(seed % 20000) / 10000 - 1) * 0.02 }   // ≈ −41 dBFS rms
        // Print: 1 s of noise only
        var only = [Float](repeating: 0, count: Int(sr))
        for i in only.indices { only[i] = noise() }
        guard let prof = only.withUnsafeBufferPointer({ NoiseReducer.profile(samples: $0.baseAddress!, count: $0.count) }) else { check(false, "no print"); return false }
        check(prof.count == NoiseReducer.bins && prof.max()! > 0, "the print has \(NoiseReducer.bins) bands")
        // Signal: 3 s of noise + 300 Hz tone at 0.2 (≈ −17 dBFS), processed in 512-sample blocks as in the mix
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
        /// Power of a band (Goertzel) and total power, over the middle second
        func band(_ x: [Float], hz: Double) -> Double {
            let a = total / 3, len = total / 3, w = 2 * Double.pi * hz / sr
            var re = 0.0, im = 0.0
            for i in 0..<len { let v = Double(x[a + i]); re += v * cos(w * Double(i)); im -= v * sin(w * Double(i)) }
            return 20 * log10(max(1e-9, sqrt(re * re + im * im) / Double(len) * 2))
        }
        func rmsDB(_ x: [Float], from: Int, to: Int) -> Double { var s = 0.0; for i in from..<to { s += Double(x[i] * x[i]) }; return 10 * log10(max(1e-12, s / Double(to - from))) }
        let out = run(sig, amount: 0.6, profile: prof)
        let toneIn = band(sig, hz: 300), toneOut = band(out, hz: 300)
        check(abs(toneOut - toneIn) < 1.5, String(format: "the voice tone is kept (%.1f → %.1f dB)", toneIn, toneOut))
        // noise: the signal without the tone, through the same reducer
        var onlyNoise = [Float](repeating: 0, count: total); for i in 0..<total { onlyNoise[i] = noise() }
        let nOut = run(onlyNoise, amount: 0.6, profile: prof)
        let lat = NoiseReducer.n
        let nIn = rmsDB(onlyNoise, from: total / 3, to: 2 * total / 3), nO = rmsDB(nOut, from: total / 3 + lat, to: 2 * total / 3 + lat)
        check(nIn - nO >= 9, String(format: "the noise drops %.1f dB (normal: ≥ 9)", nIn - nO))
        let strong = run(onlyNoise, amount: 0.9, profile: prof)
        check(nIn - rmsDB(strong, from: total / 3 + lat, to: 2 * total / 3 + lat) > nIn - nO, "on «Fuerte» it drops more than on «Normal»")
        // no print to subtract: reconstruction (delayed n samples), error below −30 dB
        let clean = run(sig, amount: 0.6, profile: [Float](repeating: 1e-6, count: NoiseReducer.bins))
        var diff = 0.0, ref = 0.0
        for i in (total / 3)..<(2 * total / 3) { let d = Double(clean[i + lat] - sig[i]); diff += d * d; ref += Double(sig[i] * sig[i]) }
        check(10 * log10(diff / ref) < -30, String(format: "with no noise to subtract the signal passes intact (error %.1f dB)", 10 * log10(diff / ref)))
        print(ok ? "OK noise-print reduction" : "FAIL noise reduction")
        return ok
    }

    /// De-click: on a voice tone with 20 single-sample clicks, the clicks disappear (peak ≤ the tone's),
    /// the tone is kept, and without clicks the signal passes intact (delayed).
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
        check(found >= 18 && found <= 24, "finds the clicks (\(found) of 20)")
        var maxResidual: Float = 0
        for pos in positions { for j in -3...4 { maxResidual = max(maxResidual, abs(out[pos + j + lat] - clean[pos + j])) } }
        check(maxResidual < 0.06, String(format: "where there was a click the waveform remains (max residue %.3f)", maxResidual))
        var diff = 0.0, ref = 0.0
        for i in 1000..<(total - 2000) { let d = Double(out[i + lat] - clean[i]); diff += d * d; ref += Double(clean[i] * clean[i]) }
        check(10 * log10(diff / ref) < -40, String(format: "the rest of the voice stays the same (error %.1f dB)", 10 * log10(diff / ref)))
        let (same, none) = run(clean, amount: 0.5)
        var d2 = 0.0
        for i in 1000..<(total - 2000) { let d = Double(same[i + lat] - clean[i]); d2 += d * d }
        check(none == 0 && 10 * log10(d2 / ref) < -60, String(format: "without clicks nothing is touched (%d detected, error %.1f dB)", none, 10 * log10(max(1e-20, d2) / ref)))
        print(ok ? "OK de-click" : "FAIL de-click")
        return ok
    }

    /// MIDI surface: messages are parsed (UMP 1.0), the default map moves what it should, «Aprender» (Learn)
    /// assigns the next control and the fader curve gives 0 dB at three quarters.
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
        check(got[2].0 == .mute(0) && got[3].0 == .play && got[4].0 == .ab, "mute only on press (not on release), play and A/B")
        got = []
        m.learning = .solo(2)
        m.handle(words: [ump(0x90, 60, 100)])
        check(m.learning == nil && m.map["note:60"] == .solo(2), "«Aprender» (Learn): note 60 becomes Solo 3")
        m.handle(words: [ump(0x90, 60, 100), ump(0x80, 60, 0)])
        check(got.count == 1 && got[0].0 == .solo(2), "the learned note fires Solo 3 once per press")
        check(MIDIControl.volume(forFader: 0) == 0 && abs(MIDIControl.volume(forFader: 0.79) - 1) < 1e-6 && abs(20 * log10(MIDIControl.volume(forFader: 1)) - 6) < 0.01,
              "curva del fader: 0 = silencio, 79 % = 0 dB, tope = +6 dB")
        m.handler = nil
        m.resetToNanoKontrol()
        print(ok ? "OK MIDI surface" : "FAIL MIDI")
        return ok
    }

    /// Audiogram: the curve follows the voice (0 in silence, ~1 speaking, drops in ~150 ms) and in a frame without camera
    /// the center bars grow when the person speaks.
    static func audiogramTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var e: [Float] = []
        e += [Float](repeating: -75, count: 20); e += [Float](repeating: -25, count: 20); e += [Float](repeating: -75, count: 20)
        let c = AudioAnalysis.audiogramCurve(energy: e, keep: [EditEngine.Span(start: 0, end: 6)])
        check(c.count >= 60 && c[10] < 0.05 && c[30] > 0.85 && c[45] < 0.2, String(format: "curve: quiet %.2f · speaking %.2f · shortly after %.2f", c[10], c[30], c[45]))
        let size = CGSize(width: 640, height: 360)
        var style = CaptionStyle(); style.enabled = false
        let scene = RenderScene(renderSize: size, format: .landscape, layout: .solo, laneOrder: [1], trackIDs: [:], captions: [], style: style,
                                switches: [SpeakerSwitch(time: 0, lane: 1)], names: [1: ("Ana", nil)], showNames: false, cropX: [:], logo: nil, background: nil, title: "p")
        // no camera: empty frames → logo/name; with audiogram, bars at 14 % height
        let quiet = mean(scene.render(frames: [:], time: 1), CGRect(x: 0.47, y: 0.80, width: 0.06, height: 0.06), size: size)
        scene.audiogram = [1: c]
        let talking = mean(scene.render(frames: [:], time: 3), CGRect(x: 0.47, y: 0.80, width: 0.06, height: 0.06), size: size)
        let silent = mean(scene.render(frames: [:], time: 1), CGRect(x: 0.47, y: 0.80, width: 0.06, height: 0.06), size: size)
        check(talking.r > quiet.r + 0.3 && talking.r > silent.r + 0.2, String(format: "the center bars grow when speaking (%.2f → %.2f; quiet %.2f)", quiet.r, talking.r, silent.r))
        if let dir = ProcessInfo.processInfo.environment["THEPOD_SHOT"] {
            let big = RenderScene(renderSize: CGSize(width: 1280, height: 720), format: .landscape, layout: .solo, laneOrder: [1], trackIDs: [:], captions: [], style: style,
                                  switches: [SpeakerSwitch(time: 0, lane: 1)], names: [1: ("Ana María", nil)], showNames: false, cropX: [:], logo: nil, background: nil, title: "p")
            big.audiogram = [1: c]
            let img = big.render(frames: [:], time: 3.2)
            try? ctx.writePNGRepresentation(of: img, to: URL(fileURLWithPath: dir).appendingPathComponent("audiograma.png"), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        print(ok ? "OK audiogram" : "FAIL audiogram")
        return ok
    }

    /// Export queue: processed one at a time, in order, without blocking the app; a failure doesn't stop the rest;
    /// what's already waiting isn't duplicated; removing from the queue and cancelling work.
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
        check(s.enqueue(.format(.landscape)), "YouTube is added")
        check(s.enqueue(.stems), "stems are added")
        check(s.enqueue(.format(.audio)), "MP3 is added")
        check(!s.enqueue(.format(.audio)), "an MP3 already waiting isn't duplicated")
        check(s.exportQueue.count == 3 && s.queuePending == 3, "three in the queue")
        try? await Task.sleep(nanoseconds: 10_000_000)   // the queue starts on the next cycle
        check(s.isBusy && s.job?.title.hasPrefix("En cola") == true, "the job bar shows the queue")
        // the app keeps responding while exporting: the main thread isn't blocked
        var ticks = 0
        while s.queuePending > 0 && ticks < 100 { ticks += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
        check(ticks > 2 && ticks < 100, "finished in the background while the main thread stayed free (\(ticks) ticks)")
        check(order == ["YouTube", "Pistas por separado (WAV)", "Solo audio (MP3)"], "arrival order: \(order)")
        check(!overlap, "never two exports at once")
        check(s.exportQueue[0].status == .done([URL(fileURLWithPath: "/tmp/YouTube.mp4")]), "YouTube done with its file")
        if case .failed(let why) = s.exportQueue[1].status { check(why == "sin pistas", "stems failed with its reason") } else { check(false, "stems should have failed") }
        check(s.exportQueue[2].status.isFinished && s.exportQueue[2].files.count == 1, "MP3 came out even though stems failed")
        check(!s.isBusy && s.job == nil, "when done the bar is released")
        s.clearFinishedExports()
        check(s.exportQueue.isEmpty, "clearing leaves the queue empty")
        // removing a waiting one and cancelling the running one empties the rest
        s.exportQueueRunner = { kind in try await Task.sleep(nanoseconds: 400_000_000); return [] }
        s.enqueue(.format(.vertical)); s.enqueue(.format(.square)); s.enqueue(.reels)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let sq = s.exportQueue.first { $0.kind == .format(.square) }!
        s.removeFromQueue(sq.id)
        check(s.exportQueue.count == 2, "the waiting one is removed")
        s.removeFromQueue(s.exportQueue[0].id)
        check(s.exportQueue.count == 2 && s.exportQueue[0].status == .running, "the running one isn't removed, it's cancelled")
        s.cancelJob()
        ticks = 0
        while s.queuePending > 0 && ticks < 50 { ticks += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
        check(s.exportQueue.count == 1 && s.exportQueue[0].status == .failed("Cancelado"), "cancel stops the current one and empties what was waiting")
        // "Exportar todo" queues YouTube + MP3 (+ reels only if any are marked)
        s.clearFinishedExports()
        s.exportQueueRunner = { _ in [] }
        s.enqueueAll()
        check(s.exportQueue.map(\.kind) == [.format(.landscape), .format(.audio)], "export all without reels: YouTube and MP3")
        return ok
    }

    /// Speed (time-stretch): a clip at 2× takes half and at 0.5× double, and the pitch doesn't change (AVFoundation's
    /// spectral algorithm, the same the mix uses). Also the model: `length`, `tlEnd` and old projects at 1×.
    static func speedTest() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var c = AudioLaneClip(id: 1, mediaId: 1, tlStart: 10, srcIn: 2, srcOut: 6)
        check(c.length == 4 && c.tlEnd == 14, "at 1× lasts as long as the source")
        c.speed = 2
        check(c.length == 2 && c.tlEnd == 12, "at 2× lasts half in the episode")
        c.speed = 0.5
        check(c.length == 8 && c.tlEnd == 18, "at 0.5× lasts double")
        var p = Project(id: "vel", name: "Vel", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        p.audioLane = [c]
        check(abs(p.duration - 18) < 1e-9, "without voices, the episode lasts as far as the stretched music reaches (\(p.duration))")
        if let old = try? JSONDecoder().decode(AudioLaneClip.self, from: Data(#"{"id":1,"mediaId":1,"tlStart":0,"srcOut":3}"#.utf8)) {
            check(old.speed == 1 && old.length == 3, "a clip saved earlier opens at 1×")
        } else { check(false, "doesn't decode an old clip") }
        if let b = try? JSONDecoder().decode(BRollClip.self, from: Data(#"{"id":1,"file":"x.mp4"}"#.utf8)) { check(b.speed == 1 && b.speedEnd == nil, "an old b-roll opens at 1× and without ramp") }
        else { check(false, "doesn't decode an old b-roll") }
        // Ramp: from 1× to 2× over 4 s on screen consumes 6 s of source (average speed 1.5×), in 0.25 s chunks
        var br = BRollClip(id: 1, file: "x.mp4", isVideo: true, start: 0, duration: 4)
        br.speed = 1; br.speedEnd = 2
        let segs = br.speedSegments(screenLen: 4)
        check(segs.count == 16 && abs(segs.reduce(0) { $0 + $1.screen } - 4) < 1e-9, "the ramp splits into 16 chunks adding up to 4 s on screen")
        check(abs(br.sourceNeeded(screenLen: 4) - 6) < 0.05, String(format: "the 1×→2× ramp consumes 6 s of source (%.2f)", br.sourceNeeded(screenLen: 4)))
        check(segs.first!.source < segs.last!.source && abs(br.speed(at: 0) - 1) < 1e-9 && abs(br.speed(at: 1) - 2) < 1e-9, "starts slow and ends fast")
        br.speedEnd = nil; br.speed = 0.5
        check(br.speedSegments(screenLen: 4).count == 1 && abs(br.sourceNeeded(screenLen: 4) - 2) < 1e-9, "no ramp: a single segment, 0.5× consumes half")
        // Real mechanism: stretch without changing pitch
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let sr = 48_000.0
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
            let src = dir.appendingPathComponent("tono.caf")
            let file = try AVAudioFile(forWriting: src, settings: fmt.settings)
            let n = AVAudioFrameCount(sr * 4)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
            for i in 0..<Int(n) { buf.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * 440 * Double(i) / sr)) }
            try file.write(from: buf)
            func stretched(_ speed: Double) async throws -> (seconds: Double, hz: Double) {
                let asset = AVURLAsset(url: src)
                let comp = AVMutableComposition()
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                let st = try await asset.loadTracks(withMediaType: .audio).first!
                let full = try await asset.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: full), of: st, at: .zero)
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: full), toDuration: CMTime(seconds: full.seconds / speed, preferredTimescale: 90_000))
                let p = AVMutableAudioMixInputParameters(track: track); p.audioTimePitchAlgorithm = .spectral
                let mix = AVMutableAudioMix(); mix.inputParameters = [p]
                let out = dir.appendingPathComponent("out-\(UUID().uuidString).m4a")
                let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A)!
                s.audioMix = mix; s.outputURL = out; s.outputFileType = .m4a
                await s.export()
                if let e = s.error { throw e }
                let f = try AVAudioFile(forReading: out)
                let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
                try f.read(into: b)
                let m = Int(b.frameLength), ch = b.floatChannelData![0]
                var crossings = 0
                for i in (m / 3 + 1)..<(2 * m / 3) where (ch[i - 1] < 0) != (ch[i] < 0) { crossings += 1 }
                let secs = Double(m / 3) / f.processingFormat.sampleRate
                return (Double(m) / f.processingFormat.sampleRate, Double(crossings) / 2 / secs)
            }
            let fast = try await stretched(2), slow = try await stretched(0.5)
            check(abs(fast.seconds - 2) < 0.15 && abs(fast.hz - 440) < 15, String(format: "at 2×: lasts %.2f s and stays at %.0f Hz", fast.seconds, fast.hz))
            check(abs(slow.seconds - 8) < 0.15 && abs(slow.hz - 440) < 15, String(format: "at 0.5×: lasts %.2f s and stays at %.0f Hz", slow.seconds, slow.hz))
        } catch { check(false, "export: \(error.localizedDescription)") }
        print(ok ? "OK speed (time-stretch)" : "FAIL speed")
        return ok
    }

    /// Title templates: saving takes style, color, position, size, in and out (not the text or the moment);
    /// applying puts them on another layer without touching its text; the same name replaces; deleting removes; a podcast's
    /// don't mix with this Mac's; a template saved with fewer fields opens with sane values.
    static func titlePresetsTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        let slug = "prueba-plantillas-\(Int(Date().timeIntervalSince1970))"
        defer { UserDefaults.standard.removeObject(forKey: "estudio.titulos.\(slug)"); UserDefaults.standard.removeObject(forKey: "estudio.titulos.\(slug)-mia") }
        var a = VideoLayer(id: 1, kind: .text, start: 10)
        a.text = "Sam"; a.style = .box; a.color = "#FFCC00"; a.x = 0.2; a.y = 0.85; a.scale = 1.3; a.duration = 6
        a.enter = TitleMotion(kind: .rise, duration: 0.5); a.exit = TitleMotion(kind: .fade, duration: 0.3)
        TitlePresets.add(name: "Nombre abajo", from: a, podcast: slug)
        let saved = TitlePresets.all(podcast: slug)
        check(saved.count == 1 && saved[0].name == "Nombre abajo" && saved[0].style == .box && saved[0].y == 0.85 && saved[0].enter?.kind == .rise, "saved with its style, position and in")
        var b = VideoLayer(id: 2, kind: .text, start: 40)
        b.text = "Alex"
        saved[0].apply(to: &b)
        check(b.text == "Alex" && b.start == 40, "applying doesn't touch the text or the moment")
        check(b.style == .box && b.color == "#FFCC00" && b.x == 0.2 && b.y == 0.85 && b.scale == 1.3 && b.duration == 6 && b.exit?.kind == .fade, "applying sets style, color, position, size, duration and out")
        a.color = "#FFFFFF"
        TitlePresets.add(name: "Nombre abajo", from: a, podcast: slug)
        check(TitlePresets.all(podcast: slug).count == 1 && TitlePresets.all(podcast: slug)[0].color == "#FFFFFF", "saving with the same name replaces")
        check(!TitlePresets.all().contains { $0.name == "Nombre abajo" }, "the podcast's don't appear among this Mac's")
        TitlePresets.remove(saved[0].id, podcast: slug)
        check(TitlePresets.all(podcast: slug).count == 1, "deleting by an old id doesn't touch the replaced one")
        TitlePresets.remove(TitlePresets.all(podcast: slug)[0].id, podcast: slug)
        check(TitlePresets.all(podcast: slug).isEmpty, "deleting removes it")
        if let old = try? JSONDecoder().decode(TitlePresets.Item.self, from: Data(#"{"name":"Vieja","style":"label"}"#.utf8)) {
            check(old.style == .label && old.x == 0.5 && old.scale == 1 && old.enter == nil, "a template with fewer fields opens with sane values")
        } else { check(false, "doesn't decode a template with fewer fields") }
        print(ok ? "OK title templates" : "FAIL title templates")
        return ok
    }

    /// Multicam: cutting live (keys 1–4) creates a manual span until the next cut, trims the one covering that
    /// second and replaces one starting there; on camera switch, the crossfade blends and the smooth zoom enlarges.
    static func multicamTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var v = StudioVideoSettings()
        v.liveCut(to: 2, at: 10, duration: 100)
        check(v.cuts.count == 1 && v.cuts[0].start == 10 && v.cuts[0].end == 100 && v.cuts[0].lane == 2, "the first live cut lasts until the end")
        v.liveCut(to: 1, at: 30, duration: 100)
        check(v.cuts.count == 2 && v.cuts[0].end == 30 && v.cuts[1].start == 30 && v.cuts[1].lane == 1, "the next one trims the previous and lasts until the end")
        v.liveCut(to: 3, at: 20, duration: 100)
        check(v.cuts.map { [$0.start, $0.end] } == [[10, 20], [20, 30], [30, 100]] && v.cuts[1].lane == 3, "cutting in the middle splits the span and ends at the next cut (\(v.cuts.map { "\($0.start)-\($0.end)" }))")
        v.liveCut(to: 2, at: 20.02, duration: 100)
        check(v.cuts.count == 3 && v.cuts[1].lane == 2 && v.cuts[1].start == 20.02, "cutting at almost the same second replaces instead of stacking")
        if let old = try? JSONDecoder().decode(StudioVideoSettings.self, from: Data(#"{"followSpeaker":true}"#.utf8)) { check(old.switchTransition == nil && old.isDefault, "an old project opens with a hard cut") }
        else { check(false, "doesn't decode old settings") }
        // Transitions on switch: two cameras (1 red, 2 green), switch at 5 s
        let size = CGSize(width: 640, height: 360)
        let frames: [Int: CIImage] = [1: solid(1, 0, 0, size), 2: solid(0, 1, 0, size)]
        let s = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 5, lane: 2)])
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let seco = mean(s.render(frames: frames, time: 5.05), box, size: size)
        check(seco.g > 0.9 && seco.r < 0.1, "no transition: past 5 s the new camera is already shown")
        s.switchTransition = Transition(kind: .fade, duration: 0.4)
        let mid = mean(s.render(frames: frames, time: 5.2), box, size: size)
        let after = mean(s.render(frames: frames, time: 5.6), box, size: size)
        let before = mean(s.render(frames: frames, time: 4.9), box, size: size)
        check(mid.r > 0.25 && mid.g > 0.25 && mid.r < 0.75 && mid.g < 0.75, String(format: "fade: mid-switch the two are blended (%.2f red, %.2f green)", mid.r, mid.g))
        check(after.g > 0.9 && after.r < 0.1 && before.r > 0.9, "fade: before the switch only the old one, after only the new one")
        // A manual span that ends is also a switch
        s.cameraSpans = [RenderScene.CameraSpan(start: 6, end: 8, lane: 1, template: nil)]
        let endSpan = mean(s.render(frames: frames, time: 8.2), box, size: size)
        check(endSpan.r > 0.25 && endSpan.g > 0.25, "when a manual span ends it also fades to the automatic one")
        s.cameraSpans = []
        s.switchTransition = Transition(kind: .zoom, duration: 0.4)
        // Smooth zoom: camera 2 is green with an 8 px blue border; right at the switch it comes in 4 % larger and the border is outside the frame
        let green = solid(0, 1, 0, CGSize(width: 624, height: 344)).transformed(by: .init(translationX: 8, y: 8)).composited(over: solid(0, 0, 1, size))
        let edge = CGRect(x: 0, y: 0.45, width: 0.01, height: 0.1)   // the first 6 px: blue border, except with the zoom (it goes 12 px outside)
        let zoomed = mean(s.render(frames: [1: frames[1]!, 2: green], time: 5.02), edge, size: size)
        let settled = mean(s.render(frames: [1: frames[1]!, 2: green], time: 6), edge, size: size)
        check(zoomed.b < 0.5 && settled.b > 0.8, String(format: "smooth zoom: on switching it comes in larger (blue border outside: %.2f) and then settles (%.2f)", zoomed.b, settled.b))
        print(ok ? "OK multicam" : "FAIL multicam")
        return ok
    }

    /// Color: exposure, temperature, saturation and skin do what they say on a frame; a .cube is imported,
    /// applied and its intensity blends it; per-camera and whole-track color reach the drawn frame and the
    /// b-roll; matching cameras proposes exposure and gain; old projects open without color.
    static func colorTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        // `mean` returns linear values (no color space): 0.40 sRGB ≈ 0.13 linear
        let size = CGSize(width: 64, height: 64)
        let box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let gray = solid(0.4, 0.4, 0.4, size)
        var g = ColorGrade(); g.exposure = 1
        let bright = mean(g.apply(to: gray), box, size: size)
        check(bright.r > 0.22 && bright.r < 0.32, String(format: "exposure +1 EV: gray 0.40 (0.13 linear) doubles (%.2f linear)", bright.r))
        g = ColorGrade(); g.temperature = 60
        let warm = mean(g.apply(to: gray), box, size: size)
        check(warm.r > warm.b + 0.02, String(format: "temperature +60: more red than blue (%.2f / %.2f)", warm.r, warm.b))
        g.temperature = -60
        let cool = mean(g.apply(to: gray), box, size: size)
        check(cool.b > cool.r + 0.02, String(format: "temperature −60: more blue than red (%.2f / %.2f)", cool.r, cool.b))
        let red = solid(0.8, 0.2, 0.2, size)
        g = ColorGrade(); g.saturation = -100
        let desat = mean(g.apply(to: red), box, size: size)
        check(abs(desat.r - desat.g) < 0.05 && abs(desat.g - desat.b) < 0.05, "saturation −100: becomes gray")
        g = ColorGrade(); g.contrast = 50
        let dark = mean(g.apply(to: solid(0.25, 0.25, 0.25, size)), box, size: size)
        check(dark.r < 0.22, String(format: "contrast +50: the darks go down (%.2f)", dark.r))
        check(ColorGrade().isEmpty && !g.isEmpty, "an untouched color is empty")
        // .cube: a 2×2×2 LUT that inverts colors
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lut-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); LUTLibrary.remove("prueba-invertir.cube") }
        let cube = dir.appendingPathComponent("prueba-invertir.cube")
        let rows = (0..<8).map { i -> String in
            let r = Double(i % 2), gg = Double((i / 2) % 2), b = Double(i / 4)
            return "\(1 - r) \(1 - gg) \(1 - b)"
        }
        try? ("TITLE \"invertir\"\nLUT_3D_SIZE 2\n# comentario\n" + rows.joined(separator: "\n") + "\n").write(to: cube, atomically: true, encoding: .utf8)
        check(LUTLibrary.parse(cube)?.size == 2, "the .cube is read (size 2)")
        check(LUTLibrary.importCube(cube) == "prueba-invertir.cube" && LUTLibrary.names().contains("prueba-invertir.cube"), "importing copies it to the library")
        g = ColorGrade(); g.lut = "prueba-invertir.cube"
        let inv = mean(g.apply(to: red), box, size: size)
        check(inv.r < 0.1 && inv.g > 0.5, String(format: "the LUT inverts (red → cyan: %.2f / %.2f)", inv.r, inv.g))
        g.amount = 0.5
        let half = mean(g.apply(to: red), box, size: size)
        check(half.r > 0.2 && half.r < 0.45, String(format: "intensity 50 %%: halfway between 0.60 and 0.03 (%.2f)", half.r))
        check(LUTLibrary.parse(dir.appendingPathComponent("no-existe.cube")) == nil, "a file that isn't a LUT isn't imported")
        let bad = dir.appendingPathComponent("malo.cube"); try? "LUT_3D_SIZE 2\n0 0 0\n".write(to: bad, atomically: true, encoding: .utf8)
        check(LUTLibrary.importCube(bad) == nil, "an incomplete .cube is rejected")
        // In the scene: per-camera and whole-track color
        let fsize = CGSize(width: 640, height: 360)
        let frames: [Int: CIImage] = [1: solid(0.4, 0.4, 0.4, fsize), 2: solid(0.4, 0.4, 0.4, fsize)]
        let sc = scene(layout: .sideBySide, switches: [SpeakerSwitch(time: 0, lane: 1)])
        var lg = ColorGrade(); lg.exposure = 1
        sc.laneGrade = [1: lg]
        let f = sc.render(frames: frames, time: 1)
        let left = mean(f, CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2), size: fsize), right = mean(f, CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2), size: fsize)
        check(left.r > right.r + 0.1, String(format: "per-camera color: only camera 1 brightens (%.2f vs %.2f)", left.r, right.r))
        var gg = ColorGrade(); gg.saturation = -100
        sc.globalGrade = gg
        let blue = solid(0.2, 0.2, 0.9, CGSize(width: 320, height: 180))
        sc.brolls = [RenderScene.BRoll(trackID: nil, image: blue, start: 0, end: 5, fill: true, placement: "full")]
        let fb = mean(sc.render(frames: frames, time: 2), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: fsize)
        check(abs(fb.r - fb.b) < 0.08, String(format: "whole track: also desaturates the b-roll (%.2f / %.2f)", fb.r, fb.b))
        // Mask: the camera's color only inside the ellipse; outside, darkened if asked; follows keyframes
        let sm = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        sm.laneGrade = [1: lg]                       // +1 EV
        var mask = ShapeMask(); mask.shape = .ellipse; mask.x = 0.25; mask.y = 0.5; mask.w = 0.3; mask.h = 0.5; mask.feather = 0
        sm.laneMask = [1: mask]
        let fm = sm.render(frames: [1: solid(0.4, 0.4, 0.4, fsize)], time: 1)
        let inside = mean(fm, CGRect(x: 0.22, y: 0.45, width: 0.06, height: 0.1), size: fsize), outside = mean(fm, CGRect(x: 0.7, y: 0.45, width: 0.1, height: 0.1), size: fsize)
        check(inside.r > outside.r + 0.1, String(format: "mask: inside brightens (%.2f), outside doesn't (%.2f)", inside.r, outside.r))
        mask.dimOutside = 1; sm.laneMask = [1: mask]
        let fd = mean(sm.render(frames: [1: solid(0.4, 0.4, 0.4, fsize)], time: 1), CGRect(x: 0.7, y: 0.45, width: 0.1, height: 0.1), size: fsize)
        check(fd.r < outside.r * 0.5, String(format: "darken outside: the outside goes down (%.2f → %.2f)", outside.r, fd.r))
        mask.dimOutside = 0; mask.invert = true; sm.laneMask = [1: mask]
        let fi = sm.render(frames: [1: solid(0.4, 0.4, 0.4, fsize)], time: 1)
        let insideI = mean(fi, CGRect(x: 0.22, y: 0.45, width: 0.06, height: 0.1), size: fsize), outsideI = mean(fi, CGRect(x: 0.7, y: 0.45, width: 0.1, height: 0.1), size: fsize)
        check(outsideI.r > insideI.r + 0.1, "inverted: the color goes outside")
        mask.invert = false
        var ma = LayerAnimation(); ma.write(LayerAnimation.x, t: 0, v: 0.25, ease: .linear); ma.write(LayerAnimation.x, t: 10, v: 0.75)
        mask.animation = ma; sm.laneMask = [1: mask]
        let f9 = sm.render(frames: [1: solid(0.4, 0.4, 0.4, fsize)], time: 9.9)
        let leftLate = mean(f9, CGRect(x: 0.22, y: 0.45, width: 0.06, height: 0.1), size: fsize), rightLate = mean(f9, CGRect(x: 0.72, y: 0.45, width: 0.06, height: 0.1), size: fsize)
        check(rightLate.r > leftLate.r + 0.1, "the mask follows the keyframes: at the end it's on the right")
        if let oldLane = try? JSONDecoder().decode(Lane.self, from: Data(#"{"id":1,"name":"Ana","clips":[]}"#.utf8)) { check(oldLane.mask == nil, "an old track opens without a mask") }
        // Match cameras
        let fix = CameraMatch.fix(camera: [60, 60, 60], reference: [120, 120, 120])
        check(abs(fix.exposure - 1) < 0.01 && fix.gain.allSatisfy { abs($0 - 1) < 0.02 }, "camera at half brightness: +1 EV and no tint change (\(fix))")
        let tint = CameraMatch.fix(camera: [100, 100, 130], reference: [100, 100, 100])
        check(abs(tint.exposure) < 0.1 && tint.gain[2] < 0.85 && abs(tint.gain[0] - 1) < 0.06, "bluish camera: lowers the blue, not the brightness (\(tint))")
        // Old projects
        if let old = try? JSONDecoder().decode(Lane.self, from: Data(#"{"id":1,"name":"Ana","clips":[]}"#.utf8)) { check(old.grade == nil, "a track saved earlier opens without color") }
        else { check(false, "doesn't decode an old track") }
        print(ok ? "OK color" : "FAIL color")
        return ok
    }

    /// Proxies: only recordings above 1080p request one; the proxy is 960 wide, same duration, and the
    /// preview uses it while the export goes to the original; when off, they aren't used.
    static func proxyTest() async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        guard FFmpeg.isAvailable else { print("  (no ffmpeg: proxies aren't tested)"); return true }
        let slug = "proxy-prueba-\(Int(Date().timeIntervalSince1970))"
        let folder = ProjectStore.folder(for: slug)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wasOn = ProxyStore.enabled
        defer { ProxyStore.enabled = wasOn }
        do {
            let big = folder.appendingPathComponent("media/grande.mp4"), small = folder.appendingPathComponent("media/chico.mp4")
            _ = try await FFmpeg.run(["-f", "lavfi", "-i", "color=c=red:s=2560x1440:d=3:r=24", "-c:v", "mpeg4", "-q:v", "5", "-pix_fmt", "yuv420p", big.path])
            _ = try await FFmpeg.run(["-f", "lavfi", "-i", "color=c=blue:s=1280x720:d=3:r=24", "-c:v", "mpeg4", "-q:v", "5", "-pix_fmt", "yuv420p", small.path])
            let needBig = await ProxyStore.needsProxy(big), needSmall = await ProxyStore.needsProxy(small)
            check(needBig && !needSmall, "the 1440p one asks for a proxy, the 720p one doesn't")
            var p = Project(id: slug, name: "Proxy", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
            p.media = [SourceMedia(id: 1, originalName: "grande.mp4", file: "media/grande.mp4", kind: .video, duration: 3),
                       SourceMedia(id: 2, originalName: "chico.mp4", file: "media/chico.mp4", kind: .video, duration: 3)]
            p.lanes = [Lane(id: 1, name: "Ana", participantId: nil, clips: [LaneClip(mediaId: 1, srcIn: 0, srcOut: 3)])]
            let pend = await ProxyStore.pending(project: p)
            check(pend.map(\.id) == [1], "only the large one is pending (\(pend.map(\.id)))")
            try await ProxyStore.make(p.media[0], project: slug)
            check(ProxyStore.exists(mediaId: 1, project: slug), "the proxy stays in the project cache")
            let pa = AVURLAsset(url: ProxyStore.url(mediaId: 1, project: slug))
            let size = try await pa.loadTracks(withMediaType: .video).first!.load(.naturalSize)
            let dur = try await pa.load(.duration).seconds
            check(size.width <= 960 && abs(dur - 3) < 0.15, String(format: "measures %.0f px wide and lasts %.2f s", size.width, dur))
            let left = await ProxyStore.pending(project: p)
            check(left.isEmpty, "nothing is pending anymore")
            // The preview uses the proxy; the export, the original
            ProxyStore.enabled = true
            let prev = try await CompositionBuilder.build(project: p, format: .landscape, energy: nil, preview: true)
            let exp = try await CompositionBuilder.build(project: p, format: .landscape, energy: nil, preview: false)
            func width(_ b: BuiltComposition) async -> Double {
                guard let t = try? await b.asset.loadTracks(withMediaType: .video).first, let s = try? await t.load(.naturalSize) else { return 0 }
                return s.width
            }
            let wp = await width(prev), we = await width(exp)
            check(wp <= 960 && we >= 2560, String(format: "preview with proxy (%.0f px), export with the original (%.0f px)", wp, we))
            ProxyStore.enabled = false
            let off = try await CompositionBuilder.build(project: p, format: .landscape, energy: nil, preview: true)
            let wo = await width(off)
            check(wo >= 2560, "with proxies off the preview uses the original")
            ProxyStore.removeAll(project: slug)
            check(!ProxyStore.exists(mediaId: 1, project: slug), "deleting the proxies removes them")
        } catch { check(false, "proxies: \(error.localizedDescription)") }
        print(ok ? "OK proxies" : "FAIL proxies")
        return ok
    }

    /// Polish: the shortcut list doesn't repeat keys; a project saved by an old version (with nothing from Studio) opens
    /// with everything at its default and doesn't say «ajustado en Studio»; Studio settings survive saving and reopening.
    static func polishTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        check(StudioShortcuts.duplicates.isEmpty, "shortcuts don't repeat keys (\(StudioShortcuts.duplicates))")
        check(StudioShortcuts.all.count >= 15, "the shortcut list is complete (\(StudioShortcuts.all.count))")
        // A project as 0.3x saved it: no chains, keyframes, color, masks, speed, queue or review
        let old = #"""
        {"id":"viejo","name":"Viejo","podcastName":"P","createdAt":700000000,"importedFrom":"tracks","duration":0,
         "media":[{"id":1,"originalName":"a.mp4","file":"media/a.mp4","kind":"video","duration":60}],
         "lanes":[{"id":1,"name":"Ana","clips":[{"mediaId":1,"srcIn":0,"srcOut":60}]}],
         "overlays":[{"id":1,"kind":"text","start":5,"text":"Hola"}],
         "brolls":[{"id":1,"file":"broll/b.mp4","start":10}],
         "audioLane":[{"id":1,"mediaId":1,"tlStart":0,"srcOut":20}],
         "cuts":[],"words":[]}
        """#
        if let p = try? JSONDecoder().decode(Project.self, from: Data(old.utf8)) {
            check(!p.videoTunedInStudio, "an old project isn't «ajustado en Studio»")
            check(p.studioVideo.isDefault && p.grade == nil && p.lanes[0].grade == nil && p.lanes[0].mask == nil && p.lanes[0].chain == nil, "cameras, color, mask and chain at their defaults")
            check(p.brolls[0].speed == 1 && p.brolls[0].speedEnd == nil && p.brolls[0].transitionIn == nil && p.audioLane[0].speed == 1, "default speed and transitions")
            check(p.overlays[0].animation == nil && p.overlays[0].enter == nil && p.review == nil && !p.matchVoices && p.fix.roomTone, "layers without keyframes, no review, room tone on by default")
            // Round trip with Studio settings
            var q = p
            q.studioVideo.liveCut(to: 1, at: 10, duration: 60); q.studioVideo.switchTransition = Transition(kind: .zoom, duration: 0.3)
            var g = ColorGrade(); g.temperature = 20; q.lanes[0].grade = g
            var m = ShapeMask(); m.feather = 10; q.lanes[0].mask = m
            q.brolls[0].speed = 2; q.brolls[0].speedEnd = 0.5
            var a = LayerAnimation(); a.write(LayerAnimation.x, t: 5, v: 0.2); q.overlays[0].animation = a
            if let d = try? JSONEncoder().encode(q), let r = try? JSONDecoder().decode(Project.self, from: d) {
                check(r == q, "Studio settings survive saving and reopening")
                check(r.videoTunedInStudio, "and the project is «ajustado en Studio»")
            } else { check(false, "couldn't save and reopen") }
        } else {
            var why = ""
            do { _ = try JSONDecoder().decode(Project.self, from: Data(old.utf8)) } catch { why = "\(error)" }
            check(false, "doesn't open a project from an old version: \(why)")
        }
        print(ok ? "OK polish: shortcuts and migration" : "FAIL polish")
        return ok
    }

    /// Shared review: the second of the reviewed file (with intro and cuts) maps to the episode second, and the
    /// link with its comments is saved and loaded with the project.
    static func reviewTest() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }
        var r = ReviewLink(token: "abc", url: "https://postpod.castmedia.space/r/abc", sentAt: Date(), introDuration: 4,
                           keep: [EditEngine.Span(start: 0, end: 60), EditEngine.Span(start: 90, end: 200)])
        let c1 = ReviewComment(id: 1, t: 34, author: "Caro", text: "aquí", resolved: false)       // 30 s of content → 30 s of the episode
        let c2 = ReviewComment(id: 2, t: 74, author: "", text: "allá", resolved: true)            // 70 s of content → 60 + 10 = 100 s of the episode
        check(abs(r.timelineTime(c1) - 30) < 1e-9 && abs(r.timelineTime(c2) - 100) < 1e-9, "the file second maps to the episode second skipping intro and cuts (\(r.timelineTime(c1)), \(r.timelineTime(c2)))")
        check(abs(ReviewLink(token: "x", url: "u", sentAt: Date()).timelineTime(c1) - 34) < 1e-9, "without intro or cuts, the same second")
        r.comments = [c1, c2]
        var p = Project(id: "rev", name: "Rev", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        p.review = r
        do {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let back = try dec.decode(Project.self, from: try enc.encode(p))
            check(back.review?.token == "abc" && back.review?.comments.count == 2 && back.review?.comments[1].resolved == true, "the link and the comments are saved with the project")
            var obj = try JSONSerialization.jsonObject(with: try enc.encode(p)) as! [String: Any]
            obj["review"] = nil
            let old = try dec.decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
            check(old.review == nil, "a project without review opens the same")
        } catch { check(false, "save/load: \(error)") }
        let model = TimelineModel(project: p, energy: nil)
        check(model.reviewMarks.map(\.t) == [30, 100] && model.reviewMarks[1].resolved, "the timeline gets the marks at the episode second")
        print(ok ? "OK shared review" : "FAIL shared review")
        return ok
    }

    static func videoStudioTest() -> Bool {
        let size = CGSize(width: 640, height: 360)
        let frames: [Int: CIImage] = [1: solid(1, 0, 0, CGSize(width: 1280, height: 720)), 2: solid(0, 1, 0, CGSize(width: 1280, height: 720))]
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }

        // 1) Keyframe interpolation: linear, smooth and hold
        var a = LayerAnimation()
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .linear); a.write(LayerAnimation.x, t: 10, v: 1)
        check(abs((a.value(LayerAnimation.x, at: 5) ?? -1) - 0.5) < 1e-9, "linear keyframe: halfway it's 0.5")
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .smooth)
        let sm = a.value(LayerAnimation.x, at: 2.5) ?? -1
        check(sm > 0.1 && sm < 0.25, "smooth keyframe: starts slowly (\(String(format: "%.3f", sm)) at a quarter)")
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .hold)
        check(abs((a.value(LayerAnimation.x, at: 9.9) ?? -1) - 0) < 1e-9 && abs((a.value(LayerAnimation.x, at: 10) ?? -1) - 1) < 1e-9, "hold keyframe: jumps right at the next one")
        check(a.value(LayerAnimation.y, at: 3) == nil, "a parameter without keyframes returns nil (uses the fixed value)")

        // 2) A layer with position keyframes moves in the drawn frame
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
        check(leftAt0.b > 0.7 && leftAt0.r < 0.3, "layer with keyframes: at the start it's on the left (blue over red)")
        check(leftAt9.r > 0.7 && leftAt9.b < 0.3 && rightAt9.b > 0.7, "layer with keyframes: at the end it's on the right")
        // opacity at 0 → not visible
        anim.write(LayerAnimation.opacity, t: 0, v: 0, ease: .hold); anim.write(LayerAnimation.opacity, t: 10, v: 0)
        card.anim = anim; s1.overlays = [card]
        let fo = s1.render(frames: frames, time: 0.5)
        let hidden = mean(fo, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        check(hidden.r > 0.7 && hidden.b < 0.3, "opacity keyframe 0: the layer isn't visible")

        // 3) Manual camera cuts beat who's speaking, and so does the span's template
        let sw = [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 5, lane: 2)]
        let s2 = scene(layout: .solo, switches: sw)
        s2.cameraSpans = [RenderScene.CameraSpan(start: 6, end: 8, lane: 1, template: nil),
                          RenderScene.CameraSpan(start: 8, end: 9, lane: nil, template: .sideBySide)]
        let c5 = mean(s2.render(frames: frames, time: 5.5), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: size)
        let c7 = mean(s2.render(frames: frames, time: 7), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: size)
        check(c5.g > 0.7 && c5.r < 0.3, "no manual span: at 5.5 s the speaker is shown (green)")
        check(c7.r > 0.7 && c7.g < 0.3, "manual span 6–8 s: the pinned person (red) is shown even if the other speaks")
        let f8 = s2.render(frames: frames, time: 8.5)
        let l8 = mean(f8, CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2), size: size), r8 = mean(f8, CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2), size: size)
        check(l8.r > 0.6 && r8.g > 0.6, "manual span with Side by side template: red on the left, green on the right")
        check(s2.activeLane(at: 7).lane == 1 && s2.activeLane(at: 9.5).lane == 2, "outside the span the automatic one returns")

        // 4) Minimum hold: very close switches are postponed or skipped; «sigue a quien habla» off = one camera
        let rapid = [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 1, lane: 2), SpeakerSwitch(time: 1.8, lane: 1), SpeakerSwitch(time: 6, lane: 2)]
        var st = StudioVideoSettings(); st.minHold = 2.5
        let held = AudioAnalysis.cameraSwitches(rapid, settings: st)
        check(held.count == 2 && held[1].lane == 2 && held[1].time == 6, "hold 2.5 s: the 1 s round trip is skipped, leaving 0→1 and 6→2 (\(held.map { "\($0.time):\($0.lane)" }))")
        var st2 = StudioVideoSettings(); st2.minHold = 2.5
        let late = AudioAnalysis.cameraSwitches([SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 1, lane: 2)], settings: st2)
        check(late.count == 2 && abs(late[1].time - 2.5) < 1e-9, "a switch at 1 s is postponed to 2.5 s")
        st2.followSpeaker = false
        check(AudioAnalysis.cameraSwitches(rapid, settings: st2).count == 1, "not following the speaker: a single camera")

        // 5) «To black» transition on a b-roll: mid-transition the frame is dark; «cut» comes in whole
        let s3 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let white = solid(1, 1, 1, CGSize(width: 1280, height: 720))
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .black, duration: 1))]
        let mid = mean(s3.render(frames: frames, time: 2.5), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        let after = mean(s3.render(frames: frames, time: 3.5), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        check(mid.r < 0.15 && mid.g < 0.15 && mid.b < 0.15, "to-black transition: halfway it's dark (\(String(format: "%.2f", mid.r)))")
        check(after.r > 0.9 && after.g > 0.9, "after the transition the b-roll is fully visible")
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .cut, duration: 1))]
        let cutIn = mean(s3.render(frames: frames, time: 2.05), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        check(cutIn.r > 0.9, "cut transition: comes in whole from the first frame")
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .slide, duration: 1))]
        let slide = s3.render(frames: frames, time: 2.5)
        let sl = mean(slide, CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2), size: size), sr = mean(slide, CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2), size: size)
        check(sl.r > 0.9 && sl.g > 0.9 && sr.g < 0.3, "slide transition: halfway it already covers the left and not yet the right")

        // 5b) Title ins and outs: rise leaves the layer lower halfway; type reveals it left
        //     to right; fade on out turns it off; with no in chosen, the simple out still works
        let s4 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let wide = solid(0, 0, 1, CGSize(width: 320, height: 60))
        var tc = RenderScene.OverlayCard(id: 9, start: 2, end: 8, image: wide, cx: 0.5, cy: 0.5, animate: true)
        tc.enter = TitleMotion(kind: .rise, duration: 1)
        s4.overlays = [tc]
        // The layer occupies 0.417–0.583 of the height in place; a third into the rise it's about 0.04 lower:
        // the 0.42–0.45 strip (its top edge) is empty while rising and covered on arrival.
        let risen = s4.render(frames: frames, time: 2.3)        // a third into the rise
        let topEdgeRising = mean(risen, CGRect(x: 0.45, y: 0.42, width: 0.1, height: 0.03), size: size)
        let topEdgeSettled = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.42, width: 0.1, height: 0.03), size: size)
        check(topEdgeRising.r > 0.6 && topEdgeSettled.b > 0.7, "«subir» in: a third of the way the layer is lower than its place")
        let settled = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        check(settled.b > 0.7, "after the in the layer is in its place and whole")
        tc.enter = TitleMotion(kind: .reveal, duration: 1)
        s4.overlays = [tc]
        let half = s4.render(frames: frames, time: 2.5)
        let leftHalf = mean(half, CGRect(x: 0.27, y: 0.46, width: 0.08, height: 0.08), size: size)
        let rightHalf = mean(half, CGRect(x: 0.65, y: 0.46, width: 0.08, height: 0.08), size: size)
        check(leftHalf.b > 0.7 && rightHalf.r > 0.7, "«escribir» in: halfway the left is visible and not yet the right")
        tc.enter = nil; tc.exit = TitleMotion(kind: .fade, duration: 1)
        s4.overlays = [tc]
        let fading = mean(s4.render(frames: frames, time: 7.8), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        let shown = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        check(fading.b < shown.b - 0.3, "«fundido» out: at the end the layer is fading out")

        // 5c) Crossfade: two overlapping music clips cross by themselves (curved fades the length of the overlap) and
        //     when separated the cross disappears; the sum of powers in the middle of the cross is ~1 (equal power)
        var pm = Project(id: "x", name: "x", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        pm.audioLane = [AudioLaneClip(id: 1, mediaId: 1, tlStart: 0, srcIn: 0, srcOut: 10), AudioLaneClip(id: 2, mediaId: 1, tlStart: 8.8, srcIn: 0, srcOut: 10)]
        pm.crossfadeOverlaps(touching: 2)
        check(abs(pm.audioLane[0].fadeOut - 1.2) < 1e-9 && abs(pm.audioLane[1].fadeIn - 1.2) < 1e-9 && pm.audioLane[0].crossfade && pm.audioLane[1].crossfade,
              "dos clips solapados 1,2 s se cruzan con fades de 1,2 s")
        pm.audioLane[1].tlStart = 12; pm.crossfadeOverlaps(touching: 2)
        check(pm.audioLane[0].fadeOut == 0 && pm.audioLane[1].fadeIn == 0, "when separated, the crossfade is removed")
        pm.crossfade(1, with: 2, seconds: 2)
        check(abs(pm.audioLane[1].tlStart - 8) < 1e-9 && abs(pm.audioLane[0].fadeOut - 2) < 1e-9, "«Cruzar con el siguiente» moves the second clip earlier and sets the fades")
        let eqp = sin(0.5 * Double.pi / 2)
        check(abs(eqp * eqp + eqp * eqp - 1) < 1e-9, "equal-power fades: in the middle of the crossfade the powers add up to 1")

        // 6) Save and load: the project keeps keyframes, transitions and cuts; an old one (without those fields) opens the same
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
            check(back.videoTunedInStudio && !Project(id: "x", name: "x", podcastName: nil, createdAt: Date(), importedFrom: "tracks").videoTunedInStudio, "«ajustado en Studio» is detected only when there's something")
            // a project without the new fields
            var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            obj["studioVideo"] = nil
            var ov = obj["overlays"] as! [[String: Any]]; ov[0]["animation"] = nil; ov[0]["enter"] = nil; obj["overlays"] = ov
            var bs = obj["brolls"] as! [[String: Any]]; bs[0]["transitionIn"] = nil; obj["brolls"] = bs
            let old = try dec.decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
            check(old.overlays.first?.animation == nil && old.overlays.first?.enter == nil && old.brolls.first?.transitionIn == nil && old.studioVideo.isDefault, "an old project opens with the usual values")
        } catch { check(false, "save/load: \(error)") }

        print(ok ? "OK Studio · Video: keyframes, camera cuts, hold, transitions, title ins and saving" : "FAIL Studio · Video")
        return ok
    }
}
