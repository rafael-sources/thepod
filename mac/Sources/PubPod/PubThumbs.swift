import SwiftUI
import AVFoundation

/// Miniaturas para pubPod: un cuadro del episodio (16:9) y de cada reel (9:16), tal como se ven en el editor.
/// Se guardan en la caché del proyecto y se rehacen solas cuando el proyecto cambia.
@MainActor
final class PubThumbs: ObservableObject {
    static let shared = PubThumbs()
    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    /// Clave estable: proyecto + lo que se ve + un sello de cambios.
    static func key(_ p: Project, reel: Reel?) -> String {
        let stamp = "\(p.cuts.count)-\(Int(p.duration))-\(p.reelLook.layout.rawValue)-\(p.lanes.count)"
        if let reel { return "\(p.id)/reel-\(reel.id.uuidString)-\(Int(reel.start))-\(Int(reel.end))-\(stamp)" }
        return "\(p.id)/episodio-\(stamp)"
    }

    func image(_ p: Project, reel: Reel?) -> NSImage? {
        let k = Self.key(p, reel: reel)
        if let img = images[k] { return img }
        let file = ProjectStore.cacheFolder(for: p.id).appendingPathComponent("pub-" + (reel.map { "reel-\($0.id.uuidString)" } ?? "episodio") + ".jpg")
        if let img = NSImage(contentsOf: file), !inFlight.contains(k), FileManager.default.fileExists(atPath: file.path) {
            images[k] = img
            // Si cambió el proyecto, se rehace en segundo plano
            if (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                render(p, reel: reel, key: k, to: file)
            }
            return img
        }
        if !inFlight.contains(k) { render(p, reel: reel, key: k, to: file) }
        return nil
    }

    private func render(_ p: Project, reel: Reel?, key k: String, to file: URL) {
        inFlight.insert(k)
        Task { [weak self] in
            defer { self?.inFlight.remove(k) }
            do {
                let project = reel.map { p.applying(p.look(for: $0), reel: $0) } ?? p
                let format: ExportFormat = reel == nil ? .landscape : .vertical
                let window: EditEngine.Span? = reel.map { ($0.start, $0.end) }
                let built = try await CompositionBuilder.build(project: project, format: format, window: window,
                                                               energy: AudioAnalysis.loadEnergy(p.id))
                let gen = AVAssetImageGenerator(asset: built.asset)
                gen.videoComposition = built.videoComposition
                gen.maximumSize = CGSize(width: 640, height: 640)
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
                let tl = reel.map { $0.start + min(2, $0.length / 2) } ?? (p.reels.first.map { $0.start + 1 } ?? p.duration * 0.25)
                let outT = (EditEngine.toOutput(tl, keep: built.keep) ?? 0) + (reel == nil ? built.introDuration : 0)
                let (cg, _) = try await gen.image(at: CMTime(seconds: max(0.1, outT), preferredTimescale: 600))
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                if let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                    try? data.write(to: file, options: .atomic)
                }
                self?.images[k] = img
            } catch {
                // Sin miniatura: la tarjeta queda con su fondo gris
            }
        }
    }
}

/// Miniatura con su fondo gris mientras se calcula.
struct PubThumb: View {
    let project: Project
    var reel: Reel? = nil
    let size: CGSize
    var radius: CGFloat = 9
    @ObservedObject private var thumbs = PubThumbs.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.17))
            if let img = thumbs.image(project, reel: reel) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.35), value: thumbs.images.count)
    }
}
