import SwiftUI
import AVFoundation

/// Multicámara: los ángulos del episodio en una tira; clic o tecla 1–4 corta a esa cámara en el segundo actual.
/// El corte queda como tramo a mano (borde punteado en la pista Cámaras) hasta el siguiente corte.
struct MulticamStrip: View {
    @ObservedObject var session: ProjectSession
    @Binding var selectedCut: UUID?
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var tick = 0

    private var cameras: [Lane] { session.project.lanes.filter { session.project.laneHasVideo($0.id) } }

    var body: some View {
        let cams = cameras
        let t = session.playheadTimeline
        let live = session.liveLane(at: t)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Multicámara").font(.caption.bold())
                Text(String(localized: "clic o tecla 1–\(min(4, max(1, cams.count))) corta aquí")).font(.caption2).foregroundStyle(Theme.secondary)
                if let tr = session.project.studioVideo.switchTransition, tr.kind != .cut {
                    Text("al cambiar: \(tr.kind == .zoom ? String(localized: "zoom suave") : String(localized: "fundido")) \(String(format: "%.1f s", tr.duration))").font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)
            ForEach(Array(cams.prefix(4).enumerated()), id: \.element.id) { i, lane in
                angle(i + 1, lane, live: live == lane.id)
            }
            if cams.isEmpty {
                Text("Este episodio no tiene cámaras: es solo audio.").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .task(id: cams.map(\.id)) { await loadThumbs(cams) }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
        .background {
            // Teclas 1–4 sin modificador: cortar a esa cámara
            ForEach(Array(cams.prefix(4).enumerated()), id: \.element.id) { i, lane in
                Button("") { cut(to: lane.id) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: []).hidden()
            }
        }
    }

    private func angle(_ n: Int, _ lane: Lane, live: Bool) -> some View {
        Button { cut(to: lane.id) } label: {
            VStack(spacing: 4) {
                Group {
                    if let img = thumbs[lane.id] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(Color.white.opacity(0.06)) }
                }
                .frame(width: 112, height: 63).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(live ? Theme.accent : Color.white.opacity(0.12), lineWidth: live ? 2 : 1))
                .overlay(alignment: .topLeading) {
                    Text("\(n)").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(live ? Theme.accent : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(live ? Color.black : .white).padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if live {
                        Text("AL AIRE").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.black).padding(4)
                    }
                }
                Text(session.project.laneName(lane.id)).font(.caption2).lineLimit(1).frame(width: 112)
                    .foregroundStyle(live ? Theme.accent : Theme.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(String(localized: "Cortar a \(session.project.laneName(lane.id)) en este segundo (tecla \(n))"))
    }

    private func cut(to lane: Int) {
        let c = session.liveCut(to: lane)
        selectedCut = c.id
        session.selectedTrack = nil
    }

    /// Una miniatura por cámara (un cuadro del medio de su grabación), una sola vez.
    private func loadThumbs(_ cams: [Lane]) async {
        for lane in cams where thumbs[lane.id] == nil {
            guard let clip = lane.clips.first, let m = session.project.mediaItem(clip.mediaId), m.hasVideo else { continue }
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: ProjectStore.url(m.file, in: session.project.id)))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 240)
            let at = CMTime(seconds: clip.srcIn + clip.length * 0.3, preferredTimescale: 600)
            if let cg = try? await gen.image(at: at).image {
                thumbs[lane.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }
}

extension ProjectSession {
    /// Cortar a una cámara en el segundo actual (multicámara en vivo).
    @discardableResult
    func liveCut(to lane: Int) -> CameraCut {
        project.studioVideo.liveCut(to: lane, at: playheadTimeline, duration: project.duration)
    }

    /// Qué cámara está al aire en `t` (tiempo del episodio): el tramo a mano, o quien habla según la vista previa.
    func liveLane(at t: Double) -> Int? {
        if let c = project.studioVideo.cut(at: t), let l = c.lane { return l }
        guard let b = built, let sc = b.scene, let o = EditEngine.toOutput(t, keep: b.keep) else { return project.lanes.first?.id }
        return sc.activeLane(at: o).lane
    }
}
