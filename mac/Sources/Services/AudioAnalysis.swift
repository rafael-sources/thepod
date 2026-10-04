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

    // MARK: ffmpeg-based jobs

    /// "Studio in a box" chain from postPod web, written once per media file.
    static func enhancedRel(mediaId: Int, strong: Bool) -> String { strong ? "media/enhanced_\(mediaId)_nn.m4a" : "media/enhanced_\(mediaId).m4a" }

    static func enhance(media: SourceMedia, slug: String, strong: Bool = false, progress: @escaping (Double) -> Void) async throws -> String {
        let rel = enhancedRel(mediaId: media.id, strong: strong)
        let dest = ProjectStore.url(rel, in: slug)
        if FileManager.default.fileExists(atPath: dest.path) { return rel }
        let chain = (strong ? FFmpeg.strongSpeechChain : nil) ?? FFmpeg.speechChain
        // Unique temp name: two windows/processes working on the same project must never clobber each other.
        let tmp = ProjectStore.cacheFolder(for: slug).appendingPathComponent("enhancing_\(media.id)_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await FFmpeg.run(["-i", ProjectStore.url(media.file, in: slug).path, "-vn",
                              "-af", chain, "-ar", "48000", "-c:a", "aac", "-b:a", "192k", tmp.path],
                             duration: media.duration, progress: progress)
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
        guard let out = try? await FFmpeg.run(["-i", url.path, "-vn", "-af", "ebur128=framelog=quiet", "-f", "null", "-"], allowFailure: true)
        else { return nil }
        // En el resumen final: "I:         -16.3 LUFS"
        guard let r = out.range(of: #"I:\s+(-?[0-9.]+) LUFS"#, options: [.regularExpression, .backwards]) else { return nil }
        let num = out[r].replacingOccurrences(of: "I:", with: "").replacingOccurrences(of: "LUFS", with: "").trimmingCharacters(in: .whitespaces)
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
