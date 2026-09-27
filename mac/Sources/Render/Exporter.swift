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
                                  "-metadata", "title=\(project.name)", mp3.path],
                                 duration: built.duration) { progress(0.8 + 0.2 * $0) }
            try? FileManager.default.removeItem(at: m4a)
            return mp3
        }

        let url = folder.appendingPathComponent(name + ".mp4")
        let preset = AVAssetExportPresetHighestQuality   // H.264: plays everywhere (WhatsApp, TikTok, YouTube)
        try await run(asset: built.asset, preset: preset, videoComposition: built.videoComposition,
                      audioMix: built.audioMix, to: url, type: .mp4, progress: progress)
        return url
    }

    private static func run(asset: AVAsset, preset: String, videoComposition: AVVideoComposition?,
                            audioMix: AVAudioMix?, to url: URL, type: AVFileType,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure.session }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.shouldOptimizeForNetworkUse = true
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

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
