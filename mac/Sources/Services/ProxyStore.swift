import Foundation
import AVFoundation

/// Proxies: lightweight copies (960×540, H.264) of large recordings (above 1080p) so the preview and
/// Studio respond instantly. Saved in the project cache; the export always uses the originals.
/// Same timings and rotation as the original: what's seen with the proxy is what comes out with the original.
enum ProxyStore {
    static let maxOriginalWidth = 1920.0          // above this a proxy is worthwhile
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "proxys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "proxys") }
    }

    static func url(mediaId: Int, project slug: String) -> URL {
        ProjectStore.cacheFolder(for: slug).appendingPathComponent("proxy-\(mediaId).mp4")
    }
    static func exists(mediaId: Int, project slug: String) -> Bool {
        FileManager.default.fileExists(atPath: url(mediaId: mediaId, project: slug).path)
    }

    /// Does this recording deserve a proxy? Video wider than 1920 px (or taller, if vertical).
    static func needsProxy(_ file: URL) async -> Bool {
        let a = AVURLAsset(url: file)
        guard let v = try? await a.loadTracks(withMediaType: .video).first,
              let size = try? await v.load(.naturalSize) else { return false }
        return max(size.width, size.height) > maxOriginalWidth + 1
    }

    /// The project files that want a proxy and don't have one yet.
    static func pending(project: Project) async -> [SourceMedia] {
        var out: [SourceMedia] = []
        for m in project.media where m.hasVideo && m.kind == .video {
            if exists(mediaId: m.id, project: project.id) { continue }
            if await needsProxy(ProjectStore.url(m.file, in: project.id)) { out.append(m) }
        }
        return out
    }

    /// Generates a recording's proxy (into a temp file renamed when done, so nothing is left half-written).
    static func make(_ m: SourceMedia, project slug: String, progress: ((Double) -> Void)? = nil) async throws {
        let src = ProjectStore.url(m.file, in: slug)
        let dest = url(mediaId: m.id, project: slug)
        let tmp = dest.appendingPathExtension("tmp.mp4")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let asset = AVURLAsset(url: src)
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) else { throw Failure.noExporter }
        s.outputURL = tmp; s.outputFileType = .mp4; s.shouldOptimizeForNetworkUse = false
        let poll = Task { while !Task.isCancelled { progress?(Double(s.progress)); try? await Task.sleep(nanoseconds: 500_000_000) } }
        await s.export()
        poll.cancel()
        if let e = s.error { try? FileManager.default.removeItem(at: tmp); throw e }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func removeAll(project slug: String) {
        let folder = ProjectStore.cacheFolder(for: slug)
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("proxy-") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    enum Failure: LocalizedError {
        case noExporter
        var errorDescription: String? { String(localized: "No se pudo preparar el proxy de este video.") }
    }
}
