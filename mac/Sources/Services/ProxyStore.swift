import Foundation
import AVFoundation

/// Proxys: copias livianas (960×540, H.264) de las grabaciones grandes (más de 1080p) para que la vista previa y
/// Studio respondan al instante. Se guardan en la caché del proyecto; el export usa siempre los originales.
/// Mismos tiempos y misma rotación que el original: lo que se ve con el proxy es lo que sale con el original.
enum ProxyStore {
    static let maxOriginalWidth = 1920.0          // por encima de esto conviene un proxy
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

    /// ¿Esta grabación merece proxy? Video con más de 1920 px de ancho (o de alto, si es vertical).
    static func needsProxy(_ file: URL) async -> Bool {
        let a = AVURLAsset(url: file)
        guard let v = try? await a.loadTracks(withMediaType: .video).first,
              let size = try? await v.load(.naturalSize) else { return false }
        return max(size.width, size.height) > maxOriginalWidth + 1
    }

    /// Los archivos del proyecto que piden proxy y aún no lo tienen.
    static func pending(project: Project) async -> [SourceMedia] {
        var out: [SourceMedia] = []
        for m in project.media where m.hasVideo && m.kind == .video {
            if exists(mediaId: m.id, project: project.id) { continue }
            if await needsProxy(ProjectStore.url(m.file, in: project.id)) { out.append(m) }
        }
        return out
    }

    /// Genera el proxy de una grabación (en un archivo temporal que se renombra al terminar, para no dejar medios).
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
