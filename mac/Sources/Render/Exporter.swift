import AVFoundation

enum Exporter {
    enum Failure: LocalizedError {
        case session
        var errorDescription: String? { String(localized: "No se pudo iniciar la exportación.") }
    }

    /// Renders the project (or a window of it, e.g. a reel) to ~/Movies/postPod/<slug>/exports.
    /// Separate tracks (48 kHz WAV): one per person with their cuts, fades, volume line and beeps,
    /// and one with the music and effects. To finish in Logic, Audition or Reaper.
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
        // The A/B («Sin procesar») is only for listening: the export always carries the voice chain
        await MainActor.run { VoiceChainRegistry.shared.bypassAll = false }
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
            // Final volume for Spotify/Apple (−16 LUFS): measured and corrected in the same MP3 conversion
            var af: [String] = []
            if project.normalizeLoudness, let lufs = await AudioAnalysis.loudness(m4a), abs(lufs + 16) > 0.7 {
                af = ["-af", String(format: "volume=%.2fdB,alimiter=limit=0.89:level=0", -16 - lufs)]
            }
            // Chapters inside the MP3 (Apple Podcasts and others show them)
            let chap = window == nil ? chapterFile(chapterList(project: project, keep: built.keep, introDuration: 0,
                                                               total: built.duration), total: built.duration) : nil
            defer { if let chap { try? FileManager.default.removeItem(at: chap) } }
            // The full transcript inside the MP3 (ID3 lyrics tag, shown by VLC, Apple Music and others)
            let lyrics: [String] = (window == nil && project.isTranscribed) ? ["-metadata", "lyrics=" + transcriptText(project: project)] : []
            try await FFmpeg.run(["-i", m4a.path] + (chap.map { ["-i", $0.path, "-map", "0:a", "-map_chapters", "1"] } ?? [])
                                 + af + ["-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "3",
                                  "-metadata", "title=\(episodeTitle(project))", "-metadata", "artist=\(project.podcastName ?? "")"] + lyrics + [mp3.path],
                                 duration: built.duration) { progress(0.8 + 0.2 * $0) }
            try? FileManager.default.removeItem(at: m4a)
            if window == nil {
                writeSidecars(project: project, next: mp3, chapters: chapterList(project: project, keep: built.keep, introDuration: 0, total: built.duration))
                if let m = await LoudnessReport.measure(mp3) { LoudnessReport.writePDF(project: project, file: mp3, format: format, measure: m, target: -16) }
            }
            return mp3
        }

        var url = folder.appendingPathComponent(name + ".mp4")
        let meta = metadata(project: project)
        // H.264 plays everywhere (WhatsApp, TikTok, YouTube); HEVC exports faster and is half the size.
        let preset = project.exportHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        let fix = project.normalizeLoudness && FFmpeg.isAvailable
        try await run(asset: built.asset, preset: preset, videoComposition: built.videoComposition,
                      audioMix: built.audioMix, to: url, type: .mp4, metadata: meta) { progress($0 * (fix ? 0.95 : 1)) }
        // Final volume: measure and, if needed, correct only the audio (the video is copied as is, it's fast).
        // The video goes to YouTube/Instagram/TikTok, which normalize to −14 LUFS: it's delivered already at that level
        // (audio only, for Spotify/Apple, goes to −16).
        let target = -14.0
        if fix, let lufs = await AudioAnalysis.loudness(url), abs(lufs - target) > 0.7 {
            let fixed = folder.appendingPathComponent(name + "_vol.mp4")
            do {
                try await FFmpeg.run(["-i", url.path, "-map", "0", "-c:v", "copy",
                                      "-af", String(format: "volume=%.2fdB,alimiter=limit=0.89:level=0", target - lufs),
                                      "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", fixed.path])
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: fixed, to: url)
            } catch { try? FileManager.default.removeItem(at: fixed) }
        }
        url = url.standardizedFileURL
        if window == nil {
            let total = built.introDuration + EditEngine.outputDuration(built.keep)
            let chapters = chapterList(project: project, keep: built.keep, introDuration: built.introDuration, total: total)
            // Chapters and subtitles inside the video (QuickTime, VLC, Apple TV and Plex show them; YouTube takes the
            // chapters from the description and the subtitles from the .srt that goes alongside)
            let chap = chapterFile(chapters, total: built.duration)
            var srtTmp: URL?
            if project.isTranscribed {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("subs-\(UUID().uuidString).srt")
                if (try? srt(project: project).write(to: u, atomically: true, encoding: .utf8)) != nil { srtTmp = u }
            }
            if FFmpeg.isAvailable, chap != nil || srtTmp != nil {
                let with = folder.appendingPathComponent(name + "_cap.mp4")
                var args = ["-i", url.path]
                var idx = 1, chapIdx = -1, subIdx = -1
                if let chap { args += ["-i", chap.path]; chapIdx = idx; idx += 1 }
                if let srtTmp { args += ["-i", srtTmp.path]; subIdx = idx; idx += 1 }
                args += ["-map", "0", "-map_metadata", "0"]
                if chapIdx >= 0 { args += ["-map_chapters", "\(chapIdx)"] }
                if subIdx >= 0 { args += ["-map", "\(subIdx)", "-c:s", "mov_text", "-metadata:s:s:0", "language=\(project.language == "en" ? "eng" : "spa")"] }
                args += ["-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart", with.path]
                do {
                    try await FFmpeg.run(args)
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: with, to: url)
                } catch { try? FileManager.default.removeItem(at: with) }
            }
            if let chap { try? FileManager.default.removeItem(at: chap) }
            if let srtTmp { try? FileManager.default.removeItem(at: srtTmp) }
            writeSidecars(project: project, next: url, chapters: chapters)
            if let m = await LoudnessReport.measure(url) { LoudnessReport.writePDF(project: project, file: url, format: format, measure: m, target: target) }
            try? notes(project: project, keep: built.keep, introDuration: built.introDuration)
                .write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
        progress(1)
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
    /// Chapters in the exported file's time, with YouTube's rules so it shows them:
    /// the first at 00:00, at least 3, and each 10 s or longer. Those within 10 s of the
    /// previous (or the end) are skipped; if fewer than 3 remain, there are no chapters.
    static func chapterList(project p: Project, keep: [EditEngine.Span], introDuration: Double,
                            total: Double) -> [(time: Double, title: String)] {
        let raw = p.chapters.compactMap { c -> (Double, String)? in
            let title = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let o = EditEngine.toOutput(c.time, keep: keep)
                    ?? keep.firstIndex(where: { $0.start >= c.time }).map({ EditEngine.outputDuration(Array(keep.prefix($0))) })
            else { return nil }
            return (introDuration + o, title)
        }.sorted { $0.0 < $1.0 }
        var out: [(time: Double, title: String)] = []
        for (t, title) in raw {
            if out.isEmpty {
                if t >= 10 { out.append((0, introDuration > 0 ? String(localized: "Intro") : String(localized: "Inicio"))) }
                else { out.append((0, title)); continue }       // the first is moved to 00:00
            }
            guard t - out.last!.time >= 10, total - t >= 10 else { continue }
            out.append((t, title))
        }
        return out.count >= 3 ? out : []
    }

    /// Chapters file for ffmpeg (nil if none).
    static func chapterFile(_ chapters: [(time: Double, title: String)], total: Double) -> URL? {
        guard !chapters.isEmpty else { return nil }
        func esc(_ s: String) -> String {
            var o = ""
            for ch in s {
                if ch == "\n" || ch == "\r" { o.append(" "); continue }
                if "=;#\\".contains(ch) { o.append("\\") }
                o.append(ch)
            }
            return o
        }
        var txt = ";FFMETADATA1\n"
        for (i, c) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].time : total
            txt += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(c.time * 1000))\nEND=\(Int(end * 1000))\ntitle=\(esc(c.title))\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capitulos-\(UUID().uuidString).txt")
        return (try? txt.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

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
    /// `introDuration`: how long the video intro lasts (chapters are shifted by that). The MP3 has no intro.
    static func notes(project p: Project, keep: [EditEngine.Span], introDuration: Double = 0) -> String {
        var out = episodeTitle(p) + "\n\n"
        if let d = p.episode.description, !d.isEmpty { out += d + "\n\n" }
        let chapters = chapterList(project: p, keep: keep, introDuration: introDuration,
                                   total: introDuration + EditEngine.outputDuration(keep))
        if !chapters.isEmpty {
            out += String(localized: "Capítulos\n")
            for c in chapters { out += "\(EditEngine.clock(c.time)) \(c.title)\n" }
            out += "\n"
        }
        let people = p.lanes.map { lane -> String in
            let n = p.laneName(lane.id)
            return p.participant(forLane: lane.id)?.handle.map { "\(n) (\($0))" } ?? n
        }
        if !people.isEmpty { out += String(localized: "Con: ") + people.joined(separator: ", ") + "\n" }
        if !p.sponsors.isEmpty {
            out += String(localized: "\nPatrocinan:\n")
            for s in p.sponsors { out += "• \(s.name)" + (s.url.map { " — \($0)" } ?? "") + "\n" }
        }
        if !p.episode.links.isEmpty {
            out += String(localized: "\nEnlaces:\n") + p.episode.links.map { "• \($0)" }.joined(separator: "\n") + "\n"
        }
        if let pd = p.episode.podcastDescription, !pd.isEmpty { out += "\n— \(p.podcastName ?? "")\n\(pd)\n" }
        return out
    }
}

extension Exporter {
    /// SRT subtitles over the already edited video (no cuts), shifted by the intro if any.
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

    /// WebVTT subtitles (the Podcasting 2.0 and web «transcript» format), with who speaks on each line.
    static func vtt(project p: Project) -> String {
        let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts)
        let lines = EditEngine.captionLines(words: p.captionWords, keep: keep, vertical: false, uppercase: false)
        let shift = p.intro.map { max(1, $0.seconds) } ?? 0
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded()); let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
            return String(format: "%02d:%02d:%02d.%03d", h, m, s, f)
        }
        let words = p.captionWords.sorted { $0.s < $1.s }
        func lane(at o: Double) -> Int? { let t = EditEngine.toTimeline(o, keep: keep); return words.last(where: { $0.s <= t + 0.05 })?.lane }
        var out = "WEBVTT\n\n"
        for (i, l) in lines.enumerated() {
            let who = lane(at: l.start).map { p.laneName($0) }?.replacingOccurrences(of: ">", with: "") ?? ""
            out += "\(i + 1)\n\(ts(l.start + shift)) --> \(ts(max(l.start + 0.5, l.end) + shift))\n\(who.isEmpty ? "" : "<v \(who)>")\(l.text)\n\n"
        }
        return out
    }

    /// Chapters in Podcasting 2.0 JSON (read by Apple Podcasts, Pocket Casts, Overcast…).
    static func chaptersJSON(_ chapters: [(time: Double, title: String)]) -> String? {
        guard !chapters.isEmpty else { return nil }
        let items: [[String: Any]] = chapters.map { ["startTime": ($0.time * 1000).rounded() / 1000, "title": $0.title] }
        let obj: [String: Any] = ["version": "1.2.0", "chapters": items]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// The files accompanying a full export: subtitles (.srt and .vtt) and chapters (.chapters.json).
    /// Players and platforms that understand them take them from there; for the rest they're harmless.
    @discardableResult
    static func writeSidecars(project p: Project, next url: URL, chapters: [(time: Double, title: String)]) -> [URL] {
        var out: [URL] = []
        let base = url.deletingPathExtension()
        if p.isTranscribed {
            let srtURL = base.appendingPathExtension("srt"), vttURL = base.appendingPathExtension("vtt")
            if (try? srt(project: p).write(to: srtURL, atomically: true, encoding: .utf8)) != nil { out.append(srtURL) }
            if (try? vtt(project: p).write(to: vttURL, atomically: true, encoding: .utf8)) != nil { out.append(vttURL) }
        }
        if let json = chaptersJSON(chapters) {
            let u = base.appendingPathExtension("chapters.json")
            if (try? json.write(to: u, atomically: true, encoding: .utf8)) != nil { out.append(u) }
        }
        return out
    }

    /// Plain-text transcript, with the speaker's name at each change of person.
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
