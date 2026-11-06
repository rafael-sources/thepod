import SwiftUI
import AppKit

/// Deliver → Cover: the episode image. A carousel of captures where everyone
/// is smiling and sharp; pick one, or capture by hand the second where the episode is paused.
struct CoverStep: View {
    @ObservedObject var session: ProjectSession
    @State private var preview: NSImage?
    @State private var previewTime: Double?

    private var candidates: [CoverCandidate] { session.project.coverCandidates }
    private var chosen: CoverCandidate? {
        guard let t = session.project.coverTime else { return nil }
        return candidates.first { abs($0.time - t) < 0.05 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: String(localized: "Portada"),
                           subtitle: String(localized: "La imagen del episodio: va a Instagram como portada y sirve de miniatura para YouTube."),
                           step: .cover)

                Card {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Buscar las mejores capturas").font(.headline)
                            Text("Recorre el episodio y propone los segundos donde todas las personas salen sonriendo, con los ojos abiertos y la imagen nítida. Tarda alrededor de un minuto por cada media hora de episodio.")
                                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                            if let d = session.project.coverScannedAt {
                                Text(String(localized: "Última búsqueda: \(d.formatted(date: .abbreviated, time: .shortened)) · \(candidates.count) capturas"))
                                    .font(.caption2).foregroundStyle(Theme.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Button {
                                session.findCoverCandidates()
                            } label: {
                                Label(candidates.isEmpty ? String(localized: "Buscar las mejores capturas") : String(localized: "Buscar de nuevo"), systemImage: "face.smiling")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isBusy || !hasVideo)
                            Button {
                                session.addCoverCandidateAtPlayhead()
                            } label: {
                                Label("Capturar aquí · \(EditEngine.clock(session.playheadTimeline))", systemImage: "camera")
                            }
                            .disabled(session.isBusy || !hasVideo)
                        }
                    }
                    if !hasVideo {
                        Text("Este episodio no tiene video: la portada se arma con el fondo y el logo del podcast.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }

                if !candidates.isEmpty {
                    Card {
                        HStack {
                            Text("Elige una").font(.headline)
                            Spacer()
                            let smiling = candidates.filter { $0.allSmiling }.count
                            if smiling > 0 {
                                Label("\(smiling) con todos sonriendo", systemImage: "face.smiling.inverse")
                                    .font(.caption).foregroundStyle(Theme.good)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(candidates) { c in
                                    CoverCandidateCard(project: session.project, candidate: c,
                                                       selected: chosen?.id == c.id) {
                                        session.project.coverTime = c.time
                                    } preview: {
                                        session.seek(timeline: c.time, play: false)
                                    } remove: {
                                        session.project.coverCandidates.removeAll { $0.id == c.id }
                                        if session.project.coverTime == c.time { session.project.coverTime = nil }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(height: 196)
                    }
                }

                Card {
                    HStack {
                        Text("La portada").font(.headline)
                        Spacer()
                        if session.project.coverTime != nil {
                            Button("Volver a la de siempre") { session.project.coverTime = nil }
                                .controlSize(.small)
                        }
                        Button {
                            session.saveCover()
                        } label: { Label("Guardar portada (.jpg)", systemImage: "square.and.arrow.down") }
                        .disabled(session.isBusy)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.12))
                            if let img = preview {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(width: 384, height: 216)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Segundo \(EditEngine.clock(session.coverTimeline))").font(.callout.bold()).monospacedDigit()
                            if let c = chosen {
                                Text(c.allSmiling ? String(localized: "Todas las personas sonríen") : (c.faces == 0 ? String(localized: "Elegida a mano") : String(localized: "No todas sonríen")))
                                    .font(.caption).foregroundStyle(c.allSmiling ? Theme.good : Theme.secondary)
                            } else if session.project.coverTime == nil {
                                Text(session.project.reels.isEmpty ? String(localized: "A un cuarto del episodio, como siempre.") : String(localized: "Un segundo después del primer reel, como siempre."))
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Text("Sale con el diseño, el logo y el fondo del episodio, en 16:9. Es la imagen que pub manda a Instagram con el episodio completo.")
                                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(28)
        }
        .task(id: session.coverTimeline) { await loadPreview() }
        .onChange(of: session.project.coverScannedAt) { _ in Task { await loadPreview() } }
    }

    private var hasVideo: Bool {
        session.project.lanes.contains { l in
            l.clips.first.flatMap { session.project.mediaItem($0.mediaId) }.map { $0.kind == .video && $0.hasVideo } ?? false
        }
    }

    private func loadPreview() async {
        let t = session.coverTimeline
        if let c = chosen, let img = NSImage(contentsOf: ProjectStore.cacheFolder(for: session.project.id).appendingPathComponent(c.file)) {
            preview = img; previewTime = t; return
        }
        guard previewTime != t || preview == nil else { return }
        preview = nil
        if let cg = try? await CoverScout.render(project: session.project, at: t, energy: session.energy, maxSize: 960) {
            preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)); previewTime = t
        }
    }
}

/// A carousel card: the capture, the second and whether everyone smiles.
struct CoverCandidateCard: View {
    let project: Project
    let candidate: CoverCandidate
    let selected: Bool
    let choose: () -> Void
    let preview: () -> Void
    let remove: () -> Void
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.14))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 256, height: 144)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(width: 256, height: 144)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 3))
                if candidate.allSmiling {
                    Image(systemName: "face.smiling.inverse")
                        .font(.caption).foregroundStyle(.black)
                        .padding(5).background(Circle().fill(Theme.good)).padding(6)
                }
                if hover {
                    Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { preview() }
            .onTapGesture { choose() }
            .onHover { hover = $0 }
            HStack {
                Text(EditEngine.clock(candidate.time)).font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? Theme.accent : .primary)
                Spacer()
                if candidate.faces > 0 {
                    Text(candidate.allSmiling ? String(localized: "sonríen") : "\(candidate.faces) \(candidate.faces == 1 ? String(localized: "cara") : String(localized: "caras"))")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                } else {
                    Text("a mano").font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 256)
        }
        .task(id: candidate.file) {
            image = NSImage(contentsOf: ProjectStore.cacheFolder(for: project.id).appendingPathComponent(candidate.file))
        }
        .help(selected ? String(localized: "Es la portada. Doble clic para ir a ese segundo.") : String(localized: "Clic: usar de portada. Doble clic: ir a ese segundo."))
    }
}
