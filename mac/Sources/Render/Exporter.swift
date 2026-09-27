import AVFoundation

enum Exporter {
    enum Failure: LocalizedError {
        case session
        var errorDescription: String? { "No se pudo iniciar la exportación." }
    }

    /// Renders the project (or a window of it, e.g. a reel) to ~/Movies/postPod/<slug>/exports.
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
            try await FFmpeg.run(["-i", m4a.path, "-c:a", "libmp3lame", "-b:a", "192k", "-id3v2_version", "3",
                                  "-metadata", "title=\(episodeTitle(project))", "-metadata", "artist=\(project.podcastName ?? "")", mp3.path],
                                 duration: built.duration) { progress(0.8 + 0.2 * $0) }
            try? FileManager.default.removeItem(at: m4a)
            return mp3
        }

        let url = folder.appendingPathComponent(name + ".mp4")
        let meta = metadata(project: project)
        let preset = AVAssetExportPresetHighestQuality   // H.264: plays everywhere (WhatsApp, TikTok, YouTube)
        try await run(asset: built.asset, preset: preset, videoComposition: built.videoComposition,
                      audioMix: built.audioMix, to: url, type: .mp4, metadata: meta, progress: progress)
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

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
