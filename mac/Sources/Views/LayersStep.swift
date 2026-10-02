import SwiftUI
import AVFoundation

// MARK: - Textos y stickers (capas encima del video)

struct LayersStep: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: "Textos, stickers y b-roll",
                               subtitle: "Pon un título, una imagen o un emoji encima del video, o un b-roll que tape la pantalla un rato. Se agrega donde está el video ahora.")
                    Card {
                        Text("Agregar").font(.headline)
                        HStack(spacing: 10) {
                            addButton("Texto", "textformat") { _ = session.addOverlay(kind: .text, text: "Escribe aquí") }
                            addButton("Imagen", "photo") { session.chooseOverlayImage() }
                            addButton("Sticker", "face.smiling") { _ = session.addOverlay(kind: .sticker, text: "🔥") }
                        }
                        Button {
                            let id = session.addOverlay(kind: .text, text: session.project.name)
                            if let i = session.project.overlays.firstIndex(where: { $0.id == id }) {
                                session.project.overlays[i].style = .box
                                session.project.overlays[i].start = 0
                                (session.project.overlays[i].x, session.project.overlays[i].y) = VideoLayer.anchor(row: 0, col: 0)
                            }
                        } label: { Label("Título del episodio al inicio", systemImage: "text.badge.star") }
                        .controlSize(.small)
                    }
                    Card {
                        Text(session.project.overlays.isEmpty ? "Todavía no hay capas" : "En este episodio").font(.headline)
                        if session.project.overlays.isEmpty {
                            Text("Cada capa aparece unos segundos y se va sola. Al tocarla se edita debajo del video: texto, estilo, color, posición, tamaño y cuánto dura.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                        ForEach(session.project.overlays.sorted { $0.start < $1.start }) { o in
                            row(o)
                        }
                    }
                    Card {
                        HStack {
                            Text("B-roll").font(.headline)
                            Spacer()
                            Button { session.chooseBRoll() } label: { Label("Agregar video o imagen…", systemImage: "film") }.controlSize(.small)
                        }
                        Text("Un video o una foto que tapa la pantalla unos segundos mientras la voz sigue (por ejemplo, mientras cuentan una anécdota). Entra y sale con un fundido corto.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        ForEach(session.project.brolls.sorted { $0.start < $1.start }) { b in
                            let sel = session.selectedTrack == .broll(b.id)
                            Button {
                                session.selectedTrack = .broll(b.id)
                                session.seek(timeline: b.start + min(1, b.duration / 2), play: false)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: b.isVideo ? "film" : "photo").frame(width: 22).foregroundStyle(sel ? Theme.accent : .white)
                                    Text(b.title).lineLimit(1)
                                    Spacer()
                                    Text("\(EditEngine.clock(b.start)) · \(String(format: "%.0f s", b.duration))")
                                        .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Theme.panelStrong : Theme.panel))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 420, maxWidth: 560)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
    }

    private func addButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.callout.bold())
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ o: VideoLayer) -> some View {
        let sel = session.selectedTrack == .overlay(o.id)
        return Button {
            session.selectedTrack = .overlay(o.id)
            session.seek(timeline: o.start + min(1, o.duration / 2), play: false)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: o.kind == .text ? "textformat" : o.kind == .image ? "photo" : "face.smiling")
                    .frame(width: 22).foregroundStyle(sel ? Theme.accent : .white)
                Text(o.title).lineLimit(1)
                Spacer()
                Text("\(EditEngine.clock(o.start)) · \(String(format: "%.0f s", o.duration))")
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Theme.panelStrong : Theme.panel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Panel bajo el video para la capa elegida.
struct OverlayEditor: View {
    @ObservedObject var session: ProjectSession
    let id: Int
    /// Se busca por id en cada dibujo: si la capa ya se borró, no se dibuja nada (antes se caía con el índice viejo).
    private var index: Int { session.project.overlays.firstIndex { $0.id == id } ?? -1 }

    static let colors = ["#FFFFFF", "#FFD60A", "#FF453A", "#4CC9F0", "#32D74B", "#BF5AF2", "#000000"]
    static let emojis = ["🔥", "😂", "❤️", "👏", "🎉", "😮", "👀", "💯", "🤯", "🙌", "⭐️", "✅", "🎙️", "🤔"]

    private var o: Binding<VideoLayer> {
        Binding(get: { session.project.overlays.first { $0.id == id } ?? VideoLayer(id: id, kind: .text, start: 0) },
                set: { v in if let i = session.project.overlays.firstIndex(where: { $0.id == id }) { session.project.overlays[i] = v } })
    }

    var body: some View {
        if index >= 0 { editor }
    }

    @ViewBuilder
    private var editor: some View {
        let ov = o.wrappedValue
        HStack {
            Label(ov.kind == .text ? "Texto" : ov.kind == .image ? "Imagen" : "Sticker",
                  systemImage: ov.kind == .text ? "textformat" : ov.kind == .image ? "photo" : "face.smiling").font(.headline)
            Spacer()
            Button { session.duplicateOverlay(ov.id) } label: { Image(systemName: "plus.square.on.square") }
                .buttonStyle(.borderless).help("Duplicar donde está el video ahora")
            Button(role: .destructive) { session.removeOverlay(ov.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Quitar")
            Button { session.selectedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
        }
        switch ov.kind {
        case .text:
            TextField("Escribe el texto", text: o.text, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text("Estilo").frame(width: 72, alignment: .leading)
                Picker("", selection: o.style) {
                    ForEach(VideoLayer.Style.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            }
            .font(.callout)
            HStack(spacing: 8) {
                Text(ov.style == .label ? "Fondo" : "Color").frame(width: 72, alignment: .leading)
                ForEach(Self.colors, id: \.self) { c in
                    Button { o.wrappedValue.color = c } label: {
                        Circle().fill(Color(hex: c)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(ov.color == c ? Theme.accent : Color.white.opacity(0.3), lineWidth: ov.color == c ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
        case .sticker:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 7), spacing: 4) {
                ForEach(Self.emojis, id: \.self) { e in
                    Button { o.wrappedValue.text = e } label: {
                        Text(e).font(.system(size: 20)).frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(ov.text == e ? Theme.panelStrong : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Text("Otro").frame(width: 72, alignment: .leading)
                TextField("Pega cualquier emoji", text: o.text).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                Text("⌃⌘Espacio abre los emojis").font(.caption2).foregroundStyle(Theme.secondary)
            }
            .font(.callout)
        case .image:
            Text(ov.title).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        Divider()
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Posición").font(.callout)
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { r in
                        GridRow {
                            ForEach(0..<3, id: \.self) { c in
                                let a = VideoLayer.anchor(row: r, col: c)
                                let on = abs(ov.x - a.x) < 0.02 && abs(ov.y - a.y) < 0.02
                                Button { (o.wrappedValue.x, o.wrappedValue.y) = a } label: {
                                    RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accent : Color.white.opacity(0.18))
                                        .frame(width: 22, height: 14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Tamaño").frame(width: 60, alignment: .leading)
                    Slider(value: o.scale, in: 0.4...3, step: 0.05)
                    Text("\(Int(ov.scale * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Text("Empieza").frame(width: 60, alignment: .leading)
                    Button("−1 s") { o.wrappedValue.start = max(0, ov.start - 1) }
                    Text(EditEngine.clock(ov.start)).monospacedDigit().frame(width: 56)
                    Button("+1 s") { o.wrappedValue.start = min(session.project.duration, ov.start + 1) }
                    Button("Aquí") { o.wrappedValue.start = session.playheadTimeline }.help("Donde está el video ahora")
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    Text("Dura").frame(width: 60, alignment: .leading)
                    Slider(value: o.duration, in: 1...30, step: 0.5)
                    Text(String(format: "%.1f s", ov.duration)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            .font(.callout)
        }
        HStack {
            Toggle("Entra y sale con animación", isOn: o.animate).toggleStyle(.checkbox).font(.callout)
            Spacer()
            Button { session.seek(timeline: max(0, ov.start - 0.5), play: true) } label: { Label("Ver", systemImage: "play.fill") }
                .controlSize(.small)
        }
        Text("Arrastra el recuadro sobre el video para moverla; la esquina de abajo a la derecha cambia el tamaño. Va encima del video y debajo de los subtítulos.")
            .font(.caption2).foregroundStyle(Theme.secondary)
    }
}

/// Panel bajo el video para el b-roll elegido.
struct BRollEditor: View {
    @ObservedObject var session: ProjectSession
    let id: Int
    let reelId: UUID?           // nil = b-roll del episodio; si no, de ese reel

    private var reel: Reel? { reelId.flatMap { rid in session.project.reels.first { $0.id == rid } } }
    private var current: BRollClip? { (reel?.brolls ?? session.project.brolls).first { $0.id == id } }
    /// Se busca por id en cada dibujo: si ya se borró, no se dibuja nada (antes se caía con el índice viejo).
    private var b: Binding<BRollClip> {
        Binding(get: { current ?? BRollClip(id: id, file: "", isVideo: false, start: 0) },
                set: { v in
                    if let reelId, let r = session.project.reels.firstIndex(where: { $0.id == reelId }),
                       let i = session.project.reels[r].brolls.firstIndex(where: { $0.id == id }) {
                        session.project.reels[r].brolls[i] = v
                        if session.previewReel?.id == reelId { session.previewReel = session.project.reels[r] }
                    } else if let i = session.project.brolls.firstIndex(where: { $0.id == id }) {
                        session.project.brolls[i] = v
                    }
                })
    }

    var body: some View {
        if let clip = current { editor(clip) }
    }

    @ViewBuilder
    private func editor(_ clip: BRollClip) -> some View {
        let maxDur = reel.map { max(1, min(BRollClip.maxSeconds, $0.length - 1)) } ?? BRollClip.maxSeconds
        let minStart = reel?.start ?? 0
        let maxStart = reel.map { max($0.start, $0.end - 1) } ?? session.project.duration
        HStack {
            Label((reel != nil ? "B-roll del reel · " : "B-roll · ") + clip.title, systemImage: clip.isVideo ? "film" : "photo").font(.headline).lineLimit(1)
            Spacer()
            Button(role: .destructive) { session.removeBRoll(clip.id, reelId: reelId) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Quitar")
            Button { session.selectedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
        }
        HStack(spacing: 6) {
            Text("Dónde").frame(width: 72, alignment: .leading)
            Picker("", selection: b.placement) {
                Text("Toda la pantalla").tag("full")
                Text("Ventanita izquierda").tag("pipLeft")
                Text("Ventanita derecha").tag("pipRight")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
        }
        .font(.callout)
        HStack(spacing: 6) {
            Text("Empieza").frame(width: 72, alignment: .leading)
            Button("−1 s") { b.wrappedValue.start = max(minStart, clip.start - 1) }
            Text(EditEngine.clock(clip.start)).monospacedDigit().frame(width: 56)
            Button("+1 s") { b.wrappedValue.start = min(maxStart, clip.start + 1) }
            Button("Aquí") { b.wrappedValue.start = min(maxStart, max(minStart, session.playheadTimeline)) }.help("Donde está el video ahora")
        }
        .font(.callout).controlSize(.small)
        HStack(spacing: 8) {
            Text("Dura").frame(width: 72, alignment: .leading)
            Slider(value: Binding(get: { min(clip.duration, maxDur) }, set: { b.wrappedValue.duration = min($0, maxDur) }), in: 1...max(1.5, maxDur), step: 0.5)
            Text(String(format: "%.1f s", min(clip.duration, maxDur))).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
        .font(.callout)
        if clip.isVideo {
            HStack(spacing: 8) {
                Text("Desde").frame(width: 72, alignment: .leading)
                Slider(value: b.srcIn, in: 0...max(1, clip.srcIn + 60), step: 0.5)
                Text(String(format: "%.1f s", clip.srcIn)).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .font(.callout)
            HStack(spacing: 8) {
                Text("Su sonido").frame(width: 72, alignment: .leading)
                Slider(value: b.volume, in: 0...1)
                Text(clip.volume == 0 ? "mudo" : "\(Int(clip.volume * 100)) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            .font(.callout)
        }
        Picker("", selection: b.fill) {
            Text("Llenar").tag(true)
            Text("Entero, con bordes").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
        Text(String(format: "Máximo %.0f s: un b-roll es un apoyo corto. ", BRollClip.maxSeconds)
             + (reel != nil ? "Solo en este reel, y siempre más corto que el reel. " : "")
             + "El logo, los textos y los subtítulos siguen encima. La voz no se toca.")
            .font(.caption2).foregroundStyle(Theme.secondary)
    }
}

/// Recuadro de la capa elegida sobre la vista previa: se arrastra para moverla y desde la esquina para el tamaño.
/// El video se vuelve a dibujar al soltar (no en cada movimiento, para que no se trabe).
struct OverlayHandles: View {
    @ObservedObject var session: ProjectSession
    @State private var drag: CGSize = .zero
    @State private var grow: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            if case .overlay(let id) = session.selectedTrack,
               let scene = session.built?.scene,
               let box = scene.overlayBox(id),
               let i = session.project.overlays.firstIndex(where: { $0.id == id }) {
                let video = fitRect(scene.renderSize, in: geo.size)
                let w = box.width * video.width * grow, h = box.height * video.height * grow
                let cx = video.minX + box.midX * video.width + drag.width
                let cy = video.minY + box.midY * video.height + drag.height
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.white.opacity(0.001))
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { g in drag = g.translation }
                            .onEnded { g in
                                let nx = box.midX + g.translation.width / max(1, video.width)
                                let ny = box.midY + g.translation.height / max(1, video.height)
                                session.project.overlays[i].x = min(1, max(0, Double(nx)))
                                session.project.overlays[i].y = min(1, max(0, Double(ny)))
                                drag = .zero
                            })
                    Circle().fill(Theme.accent).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.4)))
                        .offset(x: 7, y: 7)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                let base = max(20, box.width * video.width)
                                grow = max(0.25, min(4, (base + g.translation.width * 2) / base))
                            }
                            .onEnded { _ in
                                let s = session.project.overlays[i].scale * Double(grow)
                                session.project.overlays[i].scale = min(3, max(0.4, s))
                                grow = 1
                            })
                        .help("Arrastra para cambiar el tamaño")
                }
                .frame(width: max(16, w), height: max(16, h))
                .position(x: cx, y: cy)
            }
        }
    }

    private func fitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let s = min(container.width / content.width, container.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}


/// Recuadro de los subtítulos sobre la vista previa: se arrastra para ponerlos donde se quiera.
/// Solo aparece cuando hay un blanco (Subtítulos del episodio, o Reels) y los subtítulos están activos.
struct CaptionHandles: View {
    @ObservedObject var session: ProjectSession
    @State private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let target = session.captionDragTarget, let scene = session.built?.scene, scene.style.enabled, !scene.captions.isEmpty {
                let st = session.captionStyle(for: target)
                let W = scene.renderSize.width, H = scene.renderSize.height
                let video = fitRect(scene.renderSize, in: geo.size)
                let vertical = scene.format.isVertical
                let factor: CGFloat = {
                    switch st.size {
                    case .small: return vertical ? 0.058 : 0.045
                    case .medium: return vertical ? 0.075 : 0.057
                    case .large: return vertical ? 0.095 : 0.072
                    }
                }()
                let fs = min(W, H) * factor
                let boxW = W * 0.86, boxH = fs * 2.6
                let cx: CGFloat = CGFloat(st.freeX ?? 0.5)
                let cy: CGFloat = {
                    if let fy = st.freeY { return CGFloat(fy) }
                    switch st.position {
                    case .top: return (H * (vertical ? 0.14 : 0.07) + boxH / 2) / H
                    case .center: return 0.5 + (vertical ? 0.05 : 0)
                    case .bottom: return (H - H * (vertical ? 0.20 : 0.07) - boxH / 2) / H
                    }
                }()
                let w = boxW / W * video.width, h = boxH / H * video.height
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .background(Color.white.opacity(0.001))
                    Text("Subtítulos").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Color.yellow.opacity(0.9)).clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(x: 2, y: -12)
                }
                .frame(width: max(24, w), height: max(16, h))
                .position(x: video.minX + cx * video.width + drag.width, y: video.minY + cy * video.height + drag.height)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in drag = g.translation }
                    .onEnded { g in
                        let nx = Double(cx + g.translation.width / max(1, video.width))
                        let ny = Double(cy + g.translation.height / max(1, video.height))
                        session.setCaptionPosition(target, x: nx, y: ny)
                        drag = .zero
                    })
            }
        }
    }

    private func fitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let s = min(container.width / content.width, container.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}
