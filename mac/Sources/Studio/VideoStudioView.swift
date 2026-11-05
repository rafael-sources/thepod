import SwiftUI
import AVFoundation

/// Studio · Video: el visor con la capa seleccionada, el inspector con keyframes y las pistas (textos, b-roll,
/// cámaras, cintillos, voces y música) encima de la plantilla del nivel simple. Mismo proyecto, mismo compositor.
struct VideoStudioView: View {
    @ObservedObject var session: ProjectSession
    @State private var selectedCut: UUID?
    @State private var zoom: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                viewer
                Divider()
                VideoInspector(session: session, selectedCut: $selectedCut)
                    .frame(width: 312)
            }
            .frame(height: 440)
            Divider()
            VideoTracks(session: session, selectedCut: $selectedCut, zoom: $zoom)
        }
    }

    // MARK: Visor

    private var viewer: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerView(player: session.player)
                OverlayHandles(session: session)
                CaptionHandles(session: session)
                if session.built == nil {
                    VStack(spacing: 8) { ProgressView(); Text("Preparando vista previa…").font(.caption).foregroundStyle(Theme.secondary) }
                }
            }
            .padding(14)
            Divider()
            HStack(spacing: 12) {
                Text("Formato").font(.caption).foregroundStyle(Theme.secondary)
                Picker("", selection: Binding(get: { session.previewFormat == .audio ? .landscape : session.previewFormat },
                                              set: { session.setPreview(format: $0) })) {
                    Text("16:9 YouTube").tag(ExportFormat.landscape)
                    Text("9:16 Reel").tag(ExportFormat.vertical)
                    Text("1:1").tag(ExportFormat.square)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Spacer()
                Toggle("Las cámaras siguen a quien habla", isOn: $session.project.studioVideo.followSpeaker)
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                    .help("Apagado: la plantilla del proyecto queda fija; solo cambian los tramos que fijes a mano")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: - Inspector

struct VideoInspector: View {
    @ObservedObject var session: ProjectSession
    @Binding var selectedCut: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let cid = selectedCut, let i = session.project.studioVideo.cuts.firstIndex(where: { $0.id == cid }) {
                    cutInspector(i)
                } else if case .overlay(let id) = session.selectedTrack, let i = session.project.overlays.firstIndex(where: { $0.id == id }) {
                    overlayInspector(i)
                } else if case .broll(let id) = session.selectedTrack, let i = session.project.brolls.firstIndex(where: { $0.id == id }) {
                    brollInspector(i)
                } else {
                    camerasInspector
                }
            }
            .padding(14)
        }
    }

    private func header(_ title: String, _ sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8); Text(title).font(.headline).lineLimit(1) }
            Text(sub).font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    // Capa: posición, tamaño, giro y opacidad con keyframes
    private func overlayInspector(_ i: Int) -> some View {
        let o = session.project.overlays[i]
        let t = session.playheadTimeline
        return VStack(alignment: .leading, spacing: 10) {
            header(o.title, "\(o.kind == .text ? "Texto" : o.kind == .sticker ? "Sticker" : "Imagen") · \(EditEngine.clock(o.start)) → \(EditEngine.clock(o.end))", color: VideoTracks.textColor)
            KeyParamRow(session: session, index: i, param: LayerAnimation.x, label: "Posición X", range: -0.5...1.5, format: { String(format: "%.2f", $0) },
                        staticValue: Binding(get: { session.project.overlays[i].x }, set: { session.project.overlays[i].x = $0 }))
            KeyParamRow(session: session, index: i, param: LayerAnimation.y, label: "Posición Y", range: -0.5...1.5, format: { String(format: "%.2f", $0) },
                        staticValue: Binding(get: { session.project.overlays[i].y }, set: { session.project.overlays[i].y = $0 }))
            KeyParamRow(session: session, index: i, param: LayerAnimation.scale, label: "Tamaño", range: 0.2...4, format: { String(format: "%.0f %%", $0 * 100) },
                        staticValue: Binding(get: { session.project.overlays[i].scale }, set: { session.project.overlays[i].scale = $0 }))
            KeyParamRow(session: session, index: i, param: LayerAnimation.rotation, label: "Giro", range: -180...180, format: { String(format: "%.0f°", $0) }, staticValue: nil, fixed: 0)
            KeyParamRow(session: session, index: i, param: LayerAnimation.opacity, label: "Opacidad", range: 0...1, format: { String(format: "%.0f %%", $0 * 100) }, staticValue: nil, fixed: 1)
            Divider()
            if let a = o.animation, !a.isEmpty {
                HStack {
                    Text("Curva desde este punto").font(.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    Picker("", selection: Binding<Keyframe.Ease>(
                        get: { keyframe(at: t, in: a)?.ease ?? .smooth },
                        set: { e in setEase(e, at: t, index: i) })) {
                        ForEach(Keyframe.Ease.allCases, id: \.self) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 110).disabled(keyframe(at: t, in: a) == nil)
                }
                Button("Quitar toda la animación", role: .destructive) { session.project.overlays[i].animation = nil }.controlSize(.small)
            }
            Toggle("Entra y sale con fundido", isOn: $session.project.overlays[i].animate).font(.caption)
            Spacer(minLength: 8)
            Text("En «Textos y stickers» esta capa dirá «Ajustado en Studio» mientras tenga keyframes. Las posiciones son fracciones del cuadro: valen igual en 16:9, 9:16 y 1:1.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyframe(at t: Double, in a: LayerAnimation) -> Keyframe? {
        for pts in a.tracks.values { if let k = pts.first(where: { abs($0.t - t) < 0.04 }) { return k } }
        return nil
    }
    private func setEase(_ e: Keyframe.Ease, at t: Double, index i: Int) {
        guard var a = session.project.overlays[i].animation else { return }
        for (p, pts) in a.tracks {
            var v = pts
            for j in v.indices where abs(v[j].t - t) < 0.04 { v[j].ease = e }
            a.tracks[p] = v
        }
        session.project.overlays[i].animation = a
    }

    // B-roll: cómo entra
    private func brollInspector(_ i: Int) -> some View {
        let b = session.project.brolls[i]
        return VStack(alignment: .leading, spacing: 10) {
            header(b.title, "B-roll · \(EditEngine.clock(b.start)) → \(EditEngine.clock(b.end))", color: VideoTracks.brollColor)
            HStack {
                Text("Entra con").font(.caption)
                Spacer()
                Picker("", selection: Binding<Transition.Kind?>(
                    get: { b.transitionIn?.kind },
                    set: { k in session.project.brolls[i].transitionIn = k.map { Transition(kind: $0, duration: b.transitionIn?.duration ?? 0.6) } })) {
                    Text("Fundido corto (simple)").tag(Transition.Kind?.none)
                    ForEach(Transition.Kind.allCases, id: \.self) { Text($0.name).tag(Transition.Kind?.some($0)) }
                }.labelsHidden().frame(width: 170)
            }
            if let tr = b.transitionIn, tr.kind != .cut {
                HStack {
                    Text("Duración").font(.caption)
                    Slider(value: Binding(get: { tr.duration }, set: { session.project.brolls[i].transitionIn?.duration = $0 }), in: 0.1...2)
                    Text(String(format: "%.1f s", tr.duration)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            Divider()
            Picker("Dónde", selection: $session.project.brolls[i].placement) {
                Text("Toda la pantalla").tag("full"); Text("Ventanita izquierda").tag("pipLeft"); Text("Ventanita derecha").tag("pipRight")
            }.font(.caption)
            Toggle("Llenar la pantalla (recorta)", isOn: $session.project.brolls[i].fill).font(.caption)
            if b.isVideo {
                HStack { Text("Sonido").font(.caption); Slider(value: $session.project.brolls[i].volume, in: 0...1); Text(b.volume < 0.01 ? "mudo" : String(format: "%.0f %%", b.volume * 100)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing) }
            }
            Spacer(minLength: 8)
            Text("La transición actúa sobre este clip al entrar; lo de abajo (cámaras o el b-roll anterior) sigue hasta que este lo tapa.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // Tramo de cámara a mano
    private func cutInspector(_ i: Int) -> some View {
        let c = session.project.studioVideo.cuts[i]
        return VStack(alignment: .leading, spacing: 10) {
            header("Cámara a mano", "\(EditEngine.clock(c.start)) → \(EditEngine.clock(c.end)) · gana sobre quien habla", color: Theme.accent)
            Picker("En grande", selection: Binding<Int?>(get: { c.lane }, set: { session.project.studioVideo.cuts[i].lane = $0 })) {
                Text("Todas (según la plantilla)").tag(Int?.none)
                ForEach(session.project.lanes) { l in Text(session.project.laneName(l.id)).tag(Int?.some(l.id)) }
            }.font(.caption)
            Picker("Plantilla", selection: Binding<LayoutTemplate?>(get: { c.template }, set: { session.project.studioVideo.cuts[i].template = $0 })) {
                Text("La del proyecto (\(session.project.layout.title))").tag(LayoutTemplate?.none)
                ForEach(LayoutTemplate.allCases.filter { $0 != .auto }) { Text($0.title).tag(LayoutTemplate?.some($0)) }
            }.font(.caption)
            HStack {
                Text("Desde").font(.caption)
                TextField("", value: Binding(get: { c.start }, set: { session.project.studioVideo.cuts[i].start = min($0, c.end - 0.5) }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("Hasta").font(.caption)
                TextField("", value: Binding(get: { c.end }, set: { session.project.studioVideo.cuts[i].end = max($0, c.start + 0.5) }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("s").font(.caption).foregroundStyle(Theme.secondary)
            }
            Button("Quitar este tramo (vuelve el automático)", role: .destructive) {
                session.project.studioVideo.cuts.remove(at: i); selectedCut = nil
            }.controlSize(.small)
            Spacer(minLength: 8)
            Text("Los tramos a mano valen también para los reels que caigan dentro.").font(.caption2).foregroundStyle(Theme.secondary)
        }
    }

    // Nada seleccionado: cómo decide las cámaras
    private var camerasInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Cámaras", "cómo se decide qué se ve", color: EpisodeTimeline.palette[0])
            Toggle("Seguir a quien habla", isOn: $session.project.studioVideo.followSpeaker).font(.caption)
            HStack {
                Text("Permanencia mínima").font(.caption)
                Slider(value: $session.project.studioVideo.minHold, in: 0.8...8, step: 0.1).disabled(!session.project.studioVideo.followSpeaker)
                Text(String(format: "%.1f s", session.project.studioVideo.minHold)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
            Text("Con menos de este tiempo en una cámara no se cambia, para no «picar» en conversaciones rápidas.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Clic en un clip para editarlo. En la pista Cámaras, clic derecho para fijar una cámara en ese segundo; arrastra sus bordes para alargar el tramo.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if session.project.videoTunedInStudio {
                Label("Este episodio tiene ajustes de Studio · Video", systemImage: "sparkles").font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Una fila de parámetro con su rombo de keyframe: relleno = hay keyframe en este segundo; con borde = el parámetro
/// está animado pero no aquí; vacío = quieto. Mover el control con el parámetro animado escribe un keyframe aquí.
struct KeyParamRow: View {
    @ObservedObject var session: ProjectSession
    let index: Int
    let param: String
    let label: String
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let staticValue: Binding<Double>?
    var fixed: Double = 0

    private var anim: LayerAnimation { session.project.overlays[index].animation ?? LayerAnimation() }
    private var t: Double { session.playheadTimeline }
    private var animated: Bool { anim.has(param) }
    private var hasKeyHere: Bool { (anim.tracks[param] ?? []).contains { abs($0.t - t) < 0.04 } }
    private var current: Double { anim.value(param, at: t) ?? staticValue?.wrappedValue ?? fixed }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                var a = anim
                if hasKeyHere, let k = (a.tracks[param] ?? []).first(where: { abs($0.t - t) < 0.04 }) { a.remove(param, id: k.id) }
                else { a.write(param, t: t, v: current) }
                session.project.overlays[index].animation = a.isEmpty ? nil : a
            } label: {
                Image(systemName: hasKeyHere ? "diamond.fill" : "diamond").font(.caption).foregroundStyle(animated ? Theme.accent : Theme.secondary)
            }
            .buttonStyle(.plain).frame(width: 18)
            .help(hasKeyHere ? "Quitar el keyframe de este segundo" : "Poner un keyframe aquí con el valor actual")
            Text(label).font(.caption).frame(width: 72, alignment: .leading)
            Slider(value: Binding(get: { current }, set: { v in
                if animated {
                    var a = anim; a.write(param, t: t, v: v); session.project.overlays[index].animation = a
                } else if let s = staticValue { s.wrappedValue = v }
                else { var a = anim; a.write(param, t: t, v: v); session.project.overlays[index].animation = a }
            }), in: range)
            Text(format(current)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Pistas

struct VideoTracks: View {
    @ObservedObject var session: ProjectSession
    @Binding var selectedCut: UUID?
    @Binding var zoom: Double
    @State private var dragStart: Double?

    static let textColor = Color(red: 0.85, green: 0.64, blue: 1)
    static let brollColor = Theme.accent
    static let cintilloColor = Color(red: 1, green: 0.72, blue: 0.42)
    static let musicColor = Color(red: 0.08, green: 0.72, blue: 0.65)
    private let labelW: CGFloat = 170

    private var duration: Double { max(1, session.project.duration) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 0) {
                    ruler
                    track("Textos y stickers", color: Self.textColor, height: 56) { w in overlaysRow(w) }
                    track("B-roll e imágenes", color: Self.brollColor, height: 56) { w in brollsRow(w) }
                    track("Cámaras", color: EpisodeTimeline.palette[0], height: 56, sub: session.project.studioVideo.followSpeaker ? "sigue a quien habla" : "plantilla fija") { w in camerasRow(w) }
                    track("Cintillos y marcas", color: Self.cintilloColor, height: 40) { w in cintillosRow(w) }
                    track("Voces", color: EpisodeTimeline.palette[0], height: 36, sub: "\(session.project.lanes.count) · pestaña Audio") { w in vocesRow(w) }
                    track("Música y efectos", color: Self.musicColor, height: 44) { w in musicRow(w) }
                    if case .overlay(let id) = session.selectedTrack, let i = session.project.overlays.firstIndex(where: { $0.id == id }),
                       let a = session.project.overlays[i].animation, !a.isEmpty {
                        ForEach(LayerAnimation.params.filter { a.has($0) }, id: \.self) { p in
                            track("  ◆ \(VideoTracks.paramName(p))", color: Theme.accent, height: 44, sub: "\(a.tracks[p]?.count ?? 0) puntos") { w in
                                KeyframeStrip(session: session, overlayIndex: i, param: p, width: w)
                            }
                        }
                    }
                }
                .frame(width: labelW + timelineWidth)
            }
        }
    }

    static func paramName(_ p: String) -> String {
        switch p {
        case LayerAnimation.x: return "Posición X"; case LayerAnimation.y: return "Posición Y"; case LayerAnimation.scale: return "Tamaño"
        case LayerAnimation.rotation: return "Giro"; case LayerAnimation.opacity: return "Opacidad"; default: return p
        }
    }

    private var timelineWidth: CGFloat { max(900, CGFloat(duration) * 6 * zoom) }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("+ Texto") { _ = session.addOverlay(kind: .text, text: "Título") }
            Button("+ Sticker") { _ = session.addOverlay(kind: .sticker, text: "✦") }
            Button("+ Imagen…") { session.chooseOverlayImage() }
            Button("+ B-roll…") { session.chooseBRoll() }
            Spacer()
            Text("Clic: ir ahí · arrastra un clip para moverlo · clic derecho en Cámaras: fijar").font(.caption).foregroundStyle(Theme.secondary)
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.secondary)
            Slider(value: $zoom, in: 0.3...8).frame(width: 110)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelW, height: 20)
            GeometryReader { g in
                let w = g.size.width
                let step = duration > 1800 ? 300.0 : duration > 600 ? 60.0 : 30.0
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { t in
                        Text(EditEngine.clock(t)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary)
                            .offset(x: CGFloat(t / duration) * w + 3, y: 3)
                    }
                }
            }
            .frame(height: 20)
        }
        .background(Theme.panel)
    }

    private func track<Content: View>(_ name: String, color: Color, height: CGFloat, sub: String? = nil, @ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8); Text(name).font(.caption.bold()).lineLimit(1) }
                if let sub { Text(sub).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            .frame(width: labelW, alignment: .leading).padding(.horizontal, 10)
            .frame(height: height).background(Theme.panel)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black.opacity(0.25))
                    content(g.size.width)
                    playhead(g.size.width, height: height)
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in session.seek(timeline: Double(loc.x / g.size.width) * duration, play: false) }
            }
            .frame(height: height)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func playhead(_ w: CGFloat, height: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Rectangle().fill(Theme.accent).frame(width: 1, height: height).offset(x: x(session.playheadTimeline, w))
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / duration) * w }

    /// Un clip arrastrable (mueve el inicio) con asa a la derecha (cambia la duración).
    private func clip(_ title: String, start: Double, dur: Double, color: Color, selected: Bool, w: CGFloat, height: CGFloat = 36, dashed: Bool = false,
                      onSelect: @escaping () -> Void, onMove: @escaping (Double) -> Void, onResize: ((Double) -> Void)? = nil) -> some View {
        let width = max(6, x(dur, w))
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(selected ? 0.35 : 0.2))
            RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.accent : color.opacity(0.6), style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: dashed ? [4, 3] : []))
            Text(title).font(.caption2).lineLimit(1).padding(.horizontal, 6)
            if let onResize {
                HStack { Spacer(); Rectangle().fill(Color.clear).frame(width: 8).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in onResize(max(0.3, dur + Double(v.translation.width / w) * duration)) })
                    .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } } }
            }
        }
        .frame(width: width, height: height)
        .offset(x: x(start, w), y: 10)
        .onTapGesture { onSelect() }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            if dragStart == nil { dragStart = start; onSelect() }
            onMove(max(0, min(duration - dur, (dragStart ?? start) + Double(v.translation.width / w) * duration)))
        }.onEnded { _ in dragStart = nil })
    }

    private func overlaysRow(_ w: CGFloat) -> some View {
        ForEach(session.project.overlays) { o in
            let sel: Bool = { if case .overlay(let id) = session.selectedTrack { return id == o.id }; return false }()
            clip(o.title + (o.tunedInStudio ? " ◆" : ""), start: o.start, dur: o.duration, color: Self.textColor, selected: sel, w: w,
                 onSelect: { session.selectedTrack = .overlay(o.id); selectedCut = nil },
                 onMove: { t in if let i = session.project.overlays.firstIndex(where: { $0.id == o.id }) { session.project.overlays[i].start = t } },
                 onResize: { d in if let i = session.project.overlays.firstIndex(where: { $0.id == o.id }) { session.project.overlays[i].duration = d } })
            .contextMenu { Button("Quitar", role: .destructive) { session.removeOverlay(o.id) } }
        }
    }

    private func brollsRow(_ w: CGFloat) -> some View {
        ForEach(session.project.brolls) { b in
            let sel: Bool = { if case .broll(let id) = session.selectedTrack { return id == b.id }; return false }()
            clip(b.title + (b.transitionIn.map { " · \($0.kind.name)" } ?? ""), start: b.start, dur: b.duration, color: Self.brollColor, selected: sel, w: w,
                 onSelect: { session.selectedTrack = .broll(b.id); selectedCut = nil },
                 onMove: { t in if let i = session.project.brolls.firstIndex(where: { $0.id == b.id }) { session.project.brolls[i].start = t } },
                 onResize: { d in if let i = session.project.brolls.firstIndex(where: { $0.id == b.id }) { session.project.brolls[i].duration = min(BRollClip.maxSeconds, d) } })
            .contextMenu { Button("Quitar", role: .destructive) { session.removeBRoll(b.id) } }
        }
    }

    /// Cámaras: los cambios automáticos (atenuados) y los tramos a mano (borde punteado, se arrastran).
    private func camerasRow(_ w: CGFloat) -> some View {
        let auto = autoBlocks()
        return ZStack(alignment: .topLeading) {
            ForEach(Array(auto.enumerated()), id: \.offset) { _, b in
                let i = session.project.lanes.firstIndex { $0.id == b.lane } ?? 0
                RoundedRectangle(cornerRadius: 4).fill(EpisodeTimeline.palette[i % EpisodeTimeline.palette.count].opacity(0.18))
                    .overlay(Text(session.project.laneName(b.lane)).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    .frame(width: max(2, x(b.end - b.start, w)), height: 36).offset(x: x(b.start, w), y: 10)
            }
            ForEach(session.project.studioVideo.cuts) { c in
                let name = c.lane.map { session.project.laneName($0) } ?? (c.template?.title ?? "Todas")
                clip(name + (c.template != nil && c.lane != nil ? " · \(c.template!.title)" : ""), start: c.start, dur: c.end - c.start, color: Theme.accent,
                     selected: selectedCut == c.id, w: w, dashed: true,
                     onSelect: { selectedCut = c.id; session.selectedTrack = nil },
                     onMove: { t in if let i = session.project.studioVideo.cuts.firstIndex(where: { $0.id == c.id }) { let d = c.end - c.start; session.project.studioVideo.cuts[i].start = t; session.project.studioVideo.cuts[i].end = t + d } },
                     onResize: { d in if let i = session.project.studioVideo.cuts.firstIndex(where: { $0.id == c.id }) { session.project.studioVideo.cuts[i].end = c.start + d } })
                .contextMenu { Button("Quitar (vuelve el automático)", role: .destructive) { session.project.studioVideo.cuts.removeAll { $0.id == c.id }; if selectedCut == c.id { selectedCut = nil } } }
            }
        }
        .frame(width: w, height: 56)
        .contextMenu {
            Section("Fijar cámara en \(EditEngine.clock(session.playheadTimeline))") {
                ForEach(session.project.lanes) { l in Button(session.project.laneName(l.id)) { addCut(lane: l.id, template: nil) } }
                Divider()
                ForEach(LayoutTemplate.allCases.filter { $0 != .auto }) { t in Button("Todas · \(t.title)") { addCut(lane: nil, template: t) } }
            }
        }
    }

    private func addCut(lane: Int?, template: LayoutTemplate?) {
        let t = session.playheadTimeline
        let next = session.project.studioVideo.cuts.map(\.start).filter { $0 > t }.min() ?? duration
        let end = min(next, t + max(3, session.project.studioVideo.minHold * 2), duration)
        let c = CameraCut(start: t, end: end, lane: lane, template: template)
        session.project.studioVideo.cuts.append(c)
        session.project.studioVideo.cuts.sort { $0.start < $1.start }
        selectedCut = c.id; session.selectedTrack = nil
    }

    /// Los cambios automáticos de cámara, en tiempo del episodio (desde la vista previa armada).
    private func autoBlocks() -> [(start: Double, end: Double, lane: Int)] {
        guard let b = session.built, let sc = b.scene else { return [] }
        let sw = sc.switches
        var out: [(Double, Double, Int)] = []
        for (i, s) in sw.enumerated() {
            let a = EditEngine.toTimeline(s.time, keep: b.keep)
            let z = i + 1 < sw.count ? EditEngine.toTimeline(sw[i + 1].time, keep: b.keep) : duration
            if z > a { out.append((a, z, s.lane)) }
        }
        return out
    }

    private func cintillosRow(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.project.cintillos) { c in
                RoundedRectangle(cornerRadius: 4).fill(Self.cintilloColor.opacity(0.2)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.cintilloColor.opacity(0.6)))
                    .overlay(Text(c.title).font(.caption2).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    .frame(width: max(4, x(c.duration, w)), height: 24).offset(x: x(c.start, w), y: 8)
                    .onTapGesture { session.selectedTrack = .cintillo(c.id); selectedCut = nil }
            }
            ForEach(Array(session.project.sponsorAppearances().enumerated()), id: \.offset) { _, a in
                RoundedRectangle(cornerRadius: 4).fill(Self.cintilloColor.opacity(0.12)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.cintilloColor.opacity(0.4), style: StrokeStyle(dash: [3, 2])))
                    .overlay(Text("Sponsor · \(a.sponsor.name)").font(.caption2).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    .frame(width: max(4, x(a.end - a.start, w)), height: 24).offset(x: x(a.start, w), y: 8)
            }
        }
    }

    private func vocesRow(_ w: CGFloat) -> some View {
        HStack {
            Text("Las voces se mezclan en la pestaña Audio (⌘E): consola, cadena de cada persona, automatización.")
                .font(.caption2).foregroundStyle(Theme.secondary).padding(.horizontal, 8)
            Spacer()
        }
        .frame(width: w, height: 36)
    }

    private func musicRow(_ w: CGFloat) -> some View {
        ForEach(session.project.audioLane) { c in
            let name = session.project.mediaItem(c.mediaId)?.originalName ?? "Música"
            let sel: Bool = { if case .sound(let id) = session.selectedTrack { return id == c.id }; return false }()
            clip(name + (c.fadeIn > 0 || c.fadeOut > 0 ? " · fades" : ""), start: c.tlStart, dur: c.srcOut - c.srcIn, color: Self.musicColor, selected: sel, w: w, height: 28,
                 onSelect: { session.selectedTrack = .sound(c.id); selectedCut = nil },
                 onMove: { t in if let i = session.project.audioLane.firstIndex(where: { $0.id == c.id }) { session.project.audioLane[i].tlStart = t } })
        }
    }
}

/// Carril de keyframes de un parámetro de una capa: arrastra un rombo (tiempo y valor), doble clic lo quita.
struct KeyframeStrip: View {
    @ObservedObject var session: ProjectSession
    let overlayIndex: Int
    let param: String
    let width: CGFloat
    @State private var dragging: UUID?
    private let h: CGFloat = 44

    private var duration: Double { max(1, session.project.duration) }
    private var points: [Keyframe] { (session.project.overlays[overlayIndex].animation?.tracks[param] ?? []).sorted { $0.t < $1.t } }
    private var range: ClosedRange<Double> {
        switch param {
        case LayerAnimation.scale: return 0.2...4
        case LayerAnimation.rotation: return -180...180
        case LayerAnimation.opacity: return 0...1
        default: return -0.5...1.5
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { p in
                guard let f = points.first else { return }
                p.move(to: CGPoint(x: 0, y: y(f.v)))
                for pt in points { p.addLine(to: CGPoint(x: x(pt.t), y: y(pt.v))) }
                p.addLine(to: CGPoint(x: width, y: y(points.last!.v)))
            }
            .stroke(Theme.accent.opacity(0.8), lineWidth: 1.2)
            ForEach(points) { pt in
                Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(dragging == pt.id ? Color.white : Theme.accent)
                    .position(x: x(pt.t), y: y(pt.v))
                    .help("\(EditEngine.clock(pt.t)) · \(VideoTracks.paramName(param)) \(String(format: "%.2f", pt.v)) · \(pt.ease.name)")
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        dragging = pt.id
                        let t = max(0, min(duration, Double(v.location.x / width) * duration))
                        let val = value(forY: v.location.y)
                        update { pts in if let i = pts.firstIndex(where: { $0.id == pt.id }) { pts[i].t = t; pts[i].v = val } }
                    }.onEnded { _ in dragging = nil })
                    .onTapGesture(count: 2) { update { pts in pts.removeAll { $0.id == pt.id } } }
            }
        }
        .frame(width: width, height: h)
    }

    private func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }
    private func y(_ v: Double) -> CGFloat {
        let f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return h - 6 - CGFloat(max(0, min(1, f))) * (h - 12)
    }
    private func value(forY py: CGFloat) -> Double {
        let f = Double((h - 6 - py) / (h - 12))
        return range.lowerBound + max(0, min(1, f)) * (range.upperBound - range.lowerBound)
    }
    private func update(_ f: (inout [Keyframe]) -> Void) {
        var a = session.project.overlays[overlayIndex].animation ?? LayerAnimation()
        var pts = a.tracks[param] ?? []
        f(&pts)
        a.tracks[param] = pts.isEmpty ? nil : pts.sorted { $0.t < $1.t }
        session.project.overlays[overlayIndex].animation = a.isEmpty ? nil : a
    }
}
