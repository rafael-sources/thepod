import AVFoundation

enum Exporter {
    enum Failure: LocalizedError {
        case session
        var errorDescription: String? { "No se pudo iniciar la exportación." }
    }

    /// Renders the project (or a window of it, e.g. a reel) to ~/Movies/postPod/<slug>/exports.
    /// Pistas por separado (WAV 48 kHz): una por persona con sus cortes, fades, línea de volumen y pitidos,
    /// y una con la música y los efectos. Para terminar en Logic, Audition o Reaper.
    static func exportStems(project: Project, energy: EnergyMap?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let stamp = DateFormatter.fileStamp.string(from: Date())
        let folder = ProjectStore.exportsFolder(for: project.id).appendingPathComponent("pistas_\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var jobs: [(name: String, project: Project)] = []
        for lane in project.lanes {
            var p = project
            p.audioLane = []
            p.intro = nil; p.outro = nil
            for i in p.lanes.indices { p.lanes[i].muted = p.lanes[i].id != lane.id; p.lanes[i].solo = false }
            jobs.append((ProjectStore.slugify(project.laneName(lane.id)), p))
        }
        if !project.audioLane.isEmpty {
            var p = project
            p.intro = nil; p.outro = nil
            for i in p.lanes.indices { p.lanes[i].muted = true; p.lanes[i].solo = false }
            jobs.append(("musica-y-efectos", p))
        }
        let n = Double(max(1, jobs.count))
        for (k, job) in jobs.enumerated() {
            let built = try await CompositionBuilder.build(project: job.project, format: .audio, window: nil, energy: energy)
            let m4a = folder.appendingPathComponent(job.name + ".m4a")
            try await run(asset: built.asset, preset: AVAssetExportPresetAppleM4A, videoComposition: nil,
                          audioMix: built.audioMix, to: m4a, type: .m4a) { progress((Double(k) + $0 * 0.8) / n) }
            if FFmpeg.isAvailable {
                let wav = folder.appendingPathComponent(job.name + ".wav")
                try await FFmpeg.run(["-i", m4a.path, "-ar", "48000", "-c:a", "pcm_s24le", wav.path], duration: built.duration) { progress((Double(k) + 0.8 + 0.2 * $0) / n) }
                try? FileManager.default.removeItem(at: m4a)
            }
        }
        progress(1)
        return folder
    }

    static func export(project: Project, format: ExportFormat, window: EditEngine.Span? = nil,
                       baseName: String? = nil, energy: EnergyMap?, layout: LayoutTemplate? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let built = try await CompositionBuilder.build(project: project, format: format, window: window, energy: energy, layoutOverride: layout)
        let folder = ProjectStore.exportsFolder(for: project.id)
        let stamp = DateFormatter.fileStamp.string(from: Date())
        let name = ProjectStore.slugify(baseName ?? project.name) + "_\(format.fileSuffix)_\(stamp)"

        if format == .audio {
            let m4a = folder.appendingPathComponent(name + ".m4a")
            try await run(asset: built.asset, preset: AVAssetExportPresetAppleM4A, videoComposition: nil,
                          audioMix: built.audioMix, to: m4a, type: .m4a) { progress($0 * (FFmpeg.isAvailable ? 0.8 : 1)) }
            guard FFmpeg.isAvailable else { return m4a }
            let mp3 = folder.appendingPathComponent(name + ".mp3")
            // Volumen final para Spotify/Apple (−16 LUFS): se mide y se corrige en la misma conversión a MP3
            var af: [String] = []
            if project.normalizeLoudness, let lufs = await AudioAnalysis.loudness(m4a), abs(lufs + 16) > 0.7 {
                af = ["-af", String(format: "volume=%.2fdB,alimiter=limit=0.89:level=0", -16 - lufs)]
            }
            try await FFmpeg.run(["-i", m4a.path] + af + ["-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "3",
                                  "-metadata", "title=\(episodeTitle(project))", "-metadata", "artist=\(project.podcastName ?? "")", mp3.path],
                                 duration: built.duration) { progress(0.8 + 0.2 * $0) }
            try? FileManager.default.removeItem(at: m4a)
            return mp3
        }

        var url = folder.appendingPathComponent(name + ".mp4")
        let meta = metadata(project: project)
        // H.264 se ve en todas partes (WhatsApp, TikTok, YouTube); HEVC es más rápido de exportar y pesa la mitad.
        let preset = project.exportHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        let fix = project.normalizeLoudness && FFmpeg.isAvailable
        try await run(asset: built.asset, preset: preset, videoComposition: built.videoComposition,
                      audioMix: built.audioMix, to: url, type: .mp4, metadata: meta) { progress($0 * (fix ? 0.95 : 1)) }
        // Volumen final: medir y, si hace falta, corregir solo el audio (el video se copia tal cual, es rápido)
        if fix, let lufs = await AudioAnalysis.loudness(url), abs(lufs + 16) > 0.7 {
            let fixed = folder.appendingPathComponent(name + "_vol.mp4")
            do {
                try await FFmpeg.run(["-i", url.path, "-map", "0", "-c:v", "copy",
                                      "-af", String(format: "volume=%.2fdB,alimiter=limit=0.89:level=0", -16 - lufs),
                                      "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", fixed.path])
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: fixed, to: url)
            } catch { try? FileManager.default.removeItem(at: fixed) }
        }
        progress(1)
        url = url.standardizedFileURL
        if window == nil {
            try? notes(project: project, keep: built.keep).write(to: url.deletingPathExtension().appendingPathExtension("txt"),
                                                                 atomically: true, encoding: .utf8)
        }
        return url
    }

    private static func run(asset: AVAsset, preset: String, videoComposition: AVVideoComposition?,
                            audioMix: AVAudioMix?, to url: URL, type: AVFileType, metadata: [AVMetadataItem] = [],
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.session }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.shouldOptimizeForNetworkUse = true
        session.metadata = metadata
        let watcher = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: type)
        progress(1)
    }
}

extension Exporter {
    static func episodeTitle(_ p: Project) -> String {
        if let t = p.episode.title, !t.isEmpty {
            let prefix = p.episode.number.map { "Ep \($0): " } ?? ""
            return prefix + t
        }
        return p.name
    }

    static func metadata(project p: Project) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        return [item(.commonIdentifierTitle, episodeTitle(p)),
                item(.commonIdentifierDescription, p.episode.description),
                item(.commonIdentifierArtist, p.podcastName),
                item(.commonIdentifierAlbumName, p.podcastName)].compactMap { $0 }
    }

    /// Ready-to-paste text for YouTube / Spotify / Apple: title, description, chapters, guests, sponsors.
    static func notes(project p: Project, keep: [EditEngine.Span]) -> String {
        var out = episodeTitle(p) + "\n\n"
        if let d = p.episode.description, !d.isEmpty { out += d + "\n\n" }
        else if let s = p.aiSummary { out += s + "\n\n" }
        let chapters = p.chapters.compactMap { c -> (Double, String)? in
            guard let o = EditEngine.toOutput(c.time, keep: keep)
                    ?? keep.firstIndex(where: { $0.start >= c.time }).map({ EditEngine.outputDuration(Array(keep.prefix($0))) })
            else { return nil }
            return (o, c.title)
        }
        if !chapters.isEmpty {
            out += "Capítulos\n"
            if chapters.first!.0 > 1 { out += "00:00 Inicio\n" }
            for c in chapters { out += "\(EditEngine.clock(c.0)) \(c.1)\n" }
            out += "\n"
        }
        let people = p.lanes.map { lane -> String in
            let n = p.laneName(lane.id)
            return p.participant(forLane: lane.id)?.handle.map { "\(n) (\($0))" } ?? n
        }
        if !people.isEmpty { out += "Con: " + people.joined(separator: ", ") + "\n" }
        if !p.sponsors.isEmpty {
            out += "\nPatrocinan:\n"
            for s in p.sponsors { out += "• \(s.name)" + (s.url.map { " — \($0)" } ?? "") + "\n" }
        }
        if !p.episode.links.isEmpty {
            out += "\nEnlaces:\n" + p.episode.links.map { "• \($0)" }.joined(separator: "\n") + "\n"
        }
        if let pd = p.episode.podcastDescription, !pd.isEmpty { out += "\n— \(p.podcastName ?? "")\n\(pd)\n" }
        return out
    }
}

extension Exporter {
    /// Subtítulos en SRT sobre el video ya editado (sin cortes), corridos el intro si lo hay.
    static func srt(project p: Project) -> String {
        let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts)
        let lines = EditEngine.captionLines(words: p.captionWords, keep: keep, vertical: false, uppercase: false)
        let shift = p.intro.map { max(1, $0.seconds) } ?? 0
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded()); let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, f)
        }
        var out = ""
        for (i, l) in lines.enumerated() {
            out += "\(i + 1)\n\(ts(l.start + shift)) --> \(ts(max(l.start + 0.5, l.end) + shift))\n\(l.text)\n\n"
        }
        return out
    }

    /// Transcripción en texto corrido, con el nombre de quien habla en cada cambio de persona.
    static func transcriptText(project p: Project) -> String {
        let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts)
        let words = p.captionWords.filter { w in keep.contains { w.s >= $0.start - 0.05 && w.s < $0.end } }.sorted { $0.s < $1.s }
        var out = episodeTitle(p) + "\n\n"
        var lane = -1
        var para: [String] = []
        for w in words {
            if w.lane != lane {
                if !para.isEmpty { out += para.joined(separator: " ") + "\n\n"; para = [] }
                lane = w.lane
                let t = EditEngine.toOutput(w.s, keep: keep) ?? w.s
                out += "[\(EditEngine.clock(t))] \(p.laneName(lane)):\n"
            }
            para.append(w.w)
        }
        if !para.isEmpty { out += para.joined(separator: " ") + "\n" }
        return out
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
